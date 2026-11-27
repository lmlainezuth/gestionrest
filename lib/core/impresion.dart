import 'dart:convert';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/ticketbai/modelos.dart' show Desglose, LineaFactura, euros, textoEntre;
import '../main.dart';
import 'conexion.dart';
import 'empresa_dispositivo.dart';
import 'escpos.dart';

/// Impresión de tickets: directa (ESC/POS por red, USB, serie o Windows) o en PDF por la impresora del sistema.
/// Cada equipo guarda qué impresora usa para: ticket, Cocina y Barra, y dónde está el cajón.
class Impresion {
  static const ticket = 'ticket';

  static Future<String?> impresora(String uso) async =>
      (await SharedPreferences.getInstance()).getString('impresora_$uso');

  static Future<void> guardar(String uso, String? url) async {
    final p = await SharedPreferences.getInstance();
    url == null ? await p.remove('impresora_$uso') : await p.setString('impresora_$uso', url);
  }

  /// ¿Imprimir el ticket de venta al cobrar? (cada equipo lo recuerda; por defecto sí)
  static Future<bool> imprimirVentas() async =>
      (await SharedPreferences.getInstance()).getBool('imprimir_ventas') ?? true;
  static Future<void> guardarImprimirVentas(bool v) async =>
      (await SharedPreferences.getInstance()).setBool('imprimir_ventas', v);

  static Future<ImpresoraDirecta?> red(String uso) async => ImpresoraDirecta.desde(await impresora(uso));

  /// Dónde está el cajón: null = en la impresora de tickets, 'ninguno', o una conexión propia (JSON).
  static Future<String?> cajon() async => (await SharedPreferences.getInstance()).getString('cajon');
  static Future<void> guardarCajon(String? v) async {
    final p = await SharedPreferences.getInstance();
    v == null ? await p.remove('cajon') : await p.setString('cajon', v);
  }

  /// ¿El cajón va enchufado a la impresora de tickets? (entonces se abre en el mismo envío que el ticket)
  static Future<bool> _cajonEnTicket() async => await cajon() == null;

  /// Abre el cajón: por su conexión propia o por la impresora de tickets.
  static Future<void> abrirCajon() async {
    final c = await cajon();
    if (c == 'ninguno') return;
    final r = c == null ? await red(ticket) : ImpresoraDirecta.desde(c);
    if (r == null) return;
    await r.abrirCajon();
  }

  static Future<(pw.Font, pw.Font)> _fuentes() async {
    try {
      return (await PdfGoogleFonts.robotoMonoRegular(), await PdfGoogleFonts.robotoMonoBold());
    } catch (_) {
      return (pw.Font.courier(), pw.Font.courierBold());
    }
  }

  /// Envía a la impresora configurada; si no hay, abre el diálogo de Windows
  /// (salvo [soloSiConfigurada], para las comandas automáticas).
  static Future<void> _imprimir(String uso, String nombre, pw.Document doc, {bool soloSiConfigurada = false}) async {
    final url = await impresora(uso);
    final bytes = await doc.save();
    if (url != null) {
      await Printing.directPrintPdf(printer: Printer(url: url), name: nombre, onLayout: (_) async => bytes);
    } else if (!soloSiConfigurada) {
      await Printing.layoutPdf(name: nombre, onLayout: (_) async => bytes);
    }
  }

  static pw.Widget _fila(String a, String b, pw.TextStyle s) => pw.Row(children: [
        pw.Expanded(child: pw.Text(a, style: s)),
        pw.Text(b, style: s),
      ]);

  static pw.Widget _raya() => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        child: pw.Divider(borderStyle: pw.BorderStyle.dashed, thickness: 0.5),
      );

  static String _importe(num v) => v.toStringAsFixed(2).replaceAll('.', ',');

  static String _fecha(DateTime f) {
    String d(int n) => n.toString().padLeft(2, '0');
    return '${d(f.day)}/${d(f.month)}/${f.year} ${d(f.hour)}:${d(f.minute)}';
  }

  /// Nombre comercial, dirección y teléfono del bar (Ajustes → Empresa). Con conexión se leen
  /// al momento; se guardan en el equipo para imprimir también sin internet.
  static Future<Map<String, dynamic>> _empresa() async {
    final clave = 'ticket_empresa_${await EmpresaDispositivo.leer() ?? ''}';
    final p = await SharedPreferences.getInstance();
    if (Conexion.enLinea.value) {
      try {
        final e = await supabase.from('empresa').select('nombre, direccion, telefono').limit(1).single().timeout(const Duration(seconds: 2));
        await p.setString(clave, jsonEncode(e));
        return e;
      } catch (_) {}
    }
    final g = p.getString(clave);
    return g == null ? const {} : Map<String, dynamic>.from(jsonDecode(g) as Map);
  }

  /// Cabecera del ticket: (texto, ¿grande?). Nombre comercial, titular, NIF, dirección y teléfono.
  static Future<List<(String, bool)>> cabecera(Map<String, dynamic> f) async {
    final e = await _empresa();
    final razon = '${f['razon_social_emisor']}'.trim();
    final nombre = '${e['nombre'] ?? ''}'.trim();
    final telefono = '${e['telefono'] ?? ''}'.trim();
    final conNombre = nombre.isNotEmpty && nombre.toUpperCase() != razon.toUpperCase();
    return [
      (conNombre ? nombre.toUpperCase() : razon, true),
      if (conNombre) (razon, false),
      ('N.I.F.: ${f['nif_emisor']}', false),
      for (final l in '${e['direccion'] ?? ''}'.split('\n'))
        if (l.trim().isNotEmpty) (l.trim(), false),
      if (telefono.isNotEmpty) ('Tel. $telefono', false),
    ];
  }

  /// Forma de pago del ticket: la que acaba de cobrarse o, al reimprimir, la guardada del pedido.
  static Future<List<Map<String, dynamic>>> _pagos(Map<String, dynamic> f) async {
    if (f['pagos'] is List) return [for (final p in f['pagos'] as List) Map<String, dynamic>.from(p as Map)];
    if (f['pedido_id'] == null || !Conexion.enLinea.value) return const [];
    try {
      final filas = await supabase
          .from('pagos')
          .select('metodo, importe, pago_con')
          .eq('pedido_id', f['pedido_id'] as Object)
          .timeout(const Duration(seconds: 2));
      return [
        for (final p in filas)
          if ((p['importe'] as num) > 0) // sin las devoluciones (pagos en negativo)
            {'metodo': p['metodo'], 'importe': p['importe'], 'entregado': p['pago_con']},
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Parte un texto por palabras para que no se corte a mitad de una.
  static List<String> _partir(String s, int ancho) {
    final lineas = <String>[];
    var l = '';
    for (final p in s.split(' ')) {
      if (l.isEmpty) {
        l = p;
      } else if (l.length + 1 + p.length <= ancho) {
        l = '$l $p';
      } else {
        lineas.add(l);
        l = p;
      }
    }
    if (l.isNotEmpty) lineas.add(l);
    return lineas;
  }

  /// Factura simplificada / factura con NIF, con código y QR TicketBAI.
  static Future<void> imprimirTicket(Map<String, dynamic> f, {bool soloSiConfigurada = false, bool cajon = false}) async {
    final lineasF = (f['lineas'] as List).map((m) => LineaFactura.fromMap(Map<String, dynamic>.from(m as Map))).toList();
    final r = await red(ticket);
    final datos = await cabecera(f);
    if (r != null) {
      final t = r.ticket();
      for (final (texto, grande) in datos) {
        for (final l in grande ? _partir(texto, t.columnas ~/ 2) : [texto]) {
          t.linea(l, centro: true, grande: grande);
        }
      }
      final completa = f['tipo'] == 'completa';
      t
        ..linea(completa ? 'FACTURA' : 'FACTURA SIMPLIFICADA', centro: true, fuerte: true)
        ..fila(_fecha(DateTime.parse(f['fecha'] as String).toLocal()), 'NUMERO: ${f['serie']}-${f['numero']}');
      if ('${f['origen'] ?? ''}'.isNotEmpty) t.linea('${f['origen']}'.toUpperCase(), centro: true);
      if (completa) {
        t
          ..saltos(1)
          ..linea('CLIENTE', fuerte: true)
          ..linea('${f['cliente_nombre']}')
          ..linea('NIF: ${f['cliente_nif']}');
        if ((f['cliente_direccion'] as String?)?.isNotEmpty ?? false) t.linea('${f['cliente_direccion']}');
      }
      t.saltos(1);
      // Columnas: unidades, artículo, precio e importe (el nombre largo sigue en la línea de abajo)
      final cols = t.columnas;
      final ancha = cols >= 48;
      final wu = ancha ? 6 : 4, wp = ancha ? 9 : 7, wi = ancha ? 9 : 8;
      final wa = cols - wu - wp - wi;
      String col4(String u, String a, String pr, String im) =>
          u.padRight(wu) + (a.length > wa ? a.substring(0, wa) : a.padRight(wa)) + pr.padLeft(wp) + im.padLeft(wi);
      t.linea(col4(ancha ? 'UNID.' : 'UD.', 'ARTICULO', 'PRECIO', 'IMPORTE'));
      for (final l in lineasF) {
        final partes = _partir(l.descripcion, wa - 1);
        final cant = l.cantidad == l.cantidad.roundToDouble() ? l.cantidad.toStringAsFixed(0) : _importe(l.cantidad);
        final precio = completa ? l.precioUnitario / (1 + l.tipoIva / 100) : l.precioUnitario;
        t.linea(col4(cant.padLeft(wu - 2), partes.isEmpty ? '' : partes.first, _importe(precio), _importe(l.total)));
        for (final resto in partes.skip(1)) {
          t.linea(' ' * wu + resto);
        }
      }
      if (completa) t.linea('Precio unitario sin IVA');
      t.saltos(1);
      // Desglose de IVA: una fila por tipo
      final w4 = cols ~/ 4;
      t.linea(['BASE', 'TIPO', 'CUOTA', 'TOTAL'].map((x) => x.padLeft(w4)).join());
      for (final tr in Desglose.deFactura(f)) {
        t.linea([_importe(tr.base), '${tr.tipo.toStringAsFixed(0)}%', _importe(tr.cuota), _importe(tr.total)]
            .map((x) => x.padLeft(w4))
            .join());
      }
      t
        ..saltos(1)
        ..fila('TOTAL:', euros(f['importe_total'] as num), fuerte: true, alto: true);
      for (final p in await _pagos(f)) {
        t.fila('${p['metodo']}'.toUpperCase(), _importe(p['importe'] as num));
        final entregado = p['entregado'] as num?;
        if (entregado != null && entregado > (p['importe'] as num)) {
          t
            ..fila('ENTREGADO', _importe(entregado))
            ..fila('CAMBIO', _importe(entregado - (p['importe'] as num)));
        }
      }
      final entre = textoEntre(f);
      if (entre != null) t.linea(entre.toUpperCase(), centro: true);
      t
        ..saltos(1)
        ..linea('*** GRACIAS POR SU VISITA ***', centro: true)
        ..linea('ESKERRIK ASKO', centro: true)
        // Anexo V: código en una línea y debajo el QR, de 30 a 40 mm (módulo 6 a 203 ppp ≈ 31-34 mm)
        ..linea('${f['tbai_id']}', centro: true)
        ..qr(f['qr_url'] as String, modulo: 6);
      if (f['estado_envio'] == 'simulada') t.linea('MODO SIMULADO - NO VALIDA FISCALMENTE', centro: true, fuerte: true);
      final juntos = cajon && await _cajonEnTicket();
      if (juntos) t.abrirCajon();
      t.cortar();
      await r.enviar(t);
      if (cajon && !juntos) await abrirCajon();
      return;
    }
    if (cajon) abrirCajon().catchError((_) {});
    final (fuente, negrita) = await _fuentes();
    final s = pw.TextStyle(font: fuente, fontSize: 8);
    final b = pw.TextStyle(font: negrita, fontSize: 8);
    final lineas = lineasF;
    final doc = pw.Document()
      ..addPage(pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(4 * PdfPageFormat.mm),
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          for (final (texto, grande) in datos)
            pw.Text(texto, textAlign: pw.TextAlign.center, style: grande ? b.copyWith(fontSize: 10) : s),
          _raya(),
          pw.Text(f['tipo'] == 'completa' ? 'FACTURA' : 'FACTURA SIMPLIFICADA', style: b),
          pw.Text('Nº ${f['serie']}-${f['numero']}', style: s),
          pw.Text(_fecha(DateTime.parse(f['fecha'] as String).toLocal()), style: s),
          if (f['tipo'] == 'completa') ...[
            _raya(),
            pw.Text('Cliente: ${f['cliente_nombre']}', style: s),
            pw.Text('NIF: ${f['cliente_nif']}', style: s),
            if ((f['cliente_direccion'] as String?)?.isNotEmpty ?? false) pw.Text('${f['cliente_direccion']}', style: s),
          ],
          _raya(),
          for (final l in lineas) _fila('${l.cantidad.toStringAsFixed(0)} ${l.descripcion}', _importe(l.total), s),
          _raya(),
          for (final tr in Desglose.deFactura(f)) ...[
            _fila('Base ${tr.tipo.toStringAsFixed(0)} %', euros(tr.base), s),
            _fila('IVA ${tr.tipo.toStringAsFixed(0)} %', euros(tr.cuota), s),
          ],
          _fila('TOTAL (IVA incl.)', euros(f['importe_total'] as num), b.copyWith(fontSize: 11)),
          if (textoEntre(f) case final entre?) pw.Text(entre, textAlign: pw.TextAlign.center, style: s),
          _raya(),
          pw.Text('${f['tbai_id']}', textAlign: pw.TextAlign.center, style: s.copyWith(fontSize: 7)),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(errorCorrectLevel: pw.BarcodeQRCorrectionLevel.medium),
              data: f['qr_url'] as String,
              width: 32 * PdfPageFormat.mm,
              height: 32 * PdfPageFormat.mm,
            ),
          ),
          if (f['estado_envio'] == 'simulada')
            pw.Text('MODO SIMULADO · NO VÁLIDA FISCALMENTE', textAlign: pw.TextAlign.center, style: b.copyWith(fontSize: 7)),
          _raya(),
          pw.Text('Gracias por su visita · Eskerrik asko', textAlign: pw.TextAlign.center, style: s),
        ]),
      ));
    await _imprimir(ticket, 'Ticket ${f['serie']}-${f['numero']}', doc, soloSiConfigurada: soloSiConfigurada);
  }

  /// Precuenta (no es factura): lo que lleva la mesa.
  static Future<void> imprimirPrecuenta(String titulo, List<Map<String, dynamic>> detalle, num total) async {
    final r = await red(ticket);
    if (r != null) {
      final t = r.ticket()
        ..linea('PRECUENTA', centro: true, grande: true)
        ..linea(titulo, centro: true)
        ..linea(_fecha(DateTime.now()), centro: true)
        ..raya();
      for (final d in detalle.where((d) => d['estado_cocina'] != 'anulado')) {
        t.fila('${(d['cantidad'] as num).toStringAsFixed(0)} ${d['descripcion']}',
            _importe((d['cantidad'] as num) * (d['precio_unitario'] as num)));
      }
      t
        ..raya()
        ..fila('TOTAL (IVA incl.)', euros(total), fuerte: true, alto: true)
        ..raya()
        ..linea('Documento no válido como factura', centro: true)
        ..cortar();
      return r.enviar(t);
    }
    final (fuente, negrita) = await _fuentes();
    final s = pw.TextStyle(font: fuente, fontSize: 8);
    final b = pw.TextStyle(font: negrita, fontSize: 8);
    final doc = pw.Document()
      ..addPage(pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(4 * PdfPageFormat.mm),
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Text('PRECUENTA', textAlign: pw.TextAlign.center, style: b.copyWith(fontSize: 11)),
          pw.Text(titulo, textAlign: pw.TextAlign.center, style: s),
          pw.Text(_fecha(DateTime.now()), textAlign: pw.TextAlign.center, style: s),
          _raya(),
          for (final d in detalle.where((d) => d['estado_cocina'] != 'anulado'))
            _fila('${(d['cantidad'] as num).toStringAsFixed(0)} ${d['descripcion']}',
                _importe((d['cantidad'] as num) * (d['precio_unitario'] as num)), s),
          _raya(),
          _fila('TOTAL (IVA incl.)', euros(total), b.copyWith(fontSize: 11)),
          _raya(),
          pw.Text('Documento no válido como factura', textAlign: pw.TextAlign.center, style: s.copyWith(fontSize: 7)),
        ]),
      ));
    await _imprimir(ticket, 'Precuenta $titulo', doc);
  }

  /// Comanda para la impresora de un área (Cocina, Barra). Solo si está configurada.
  static Future<void> imprimirComanda(String area, String titulo, List<Map<String, dynamic>> lineas) async {
    if (lineas.isEmpty || await impresora(area) == null) return;
    final r = await red(area);
    if (r != null) {
      final t = r.ticket()
        ..linea(area.toUpperCase(), centro: true, grande: true)
        ..linea(titulo, centro: true, fuerte: true)
        ..linea(_fecha(DateTime.now()), centro: true)
        ..raya();
      for (final l in lineas) {
        t.tamano(0x01);
        t.linea('${l['cantidad']}x ${l['descripcion']}  [${l['curso']}]', fuerte: true);
        t.tamano(0);
        if ((l['nota'] as String?)?.isNotEmpty ?? false) t.linea('   >> ${l['nota']}');
      }
      t.cortar();
      return r.enviar(t);
    }
    final (fuente, negrita) = await _fuentes();
    final s = pw.TextStyle(font: fuente, fontSize: 10);
    final b = pw.TextStyle(font: negrita, fontSize: 12);
    final doc = pw.Document()
      ..addPage(pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(4 * PdfPageFormat.mm),
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Text(area.toUpperCase(), textAlign: pw.TextAlign.center, style: b.copyWith(fontSize: 14)),
          pw.Text(titulo, textAlign: pw.TextAlign.center, style: b),
          pw.Text(_fecha(DateTime.now()), textAlign: pw.TextAlign.center, style: s),
          _raya(),
          for (final l in lineas) ...[
            pw.Text('${l['cantidad']}x ${l['descripcion']}  [${l['curso']}]', style: b),
            if ((l['nota'] as String?)?.isNotEmpty ?? false) pw.Text('   >> ${l['nota']}', style: s),
          ],
        ]),
      ));
    await _imprimir(area, 'Comanda $area $titulo', doc, soloSiConfigurada: true);
  }

  /// Informe simple (cierre de caja...). Cada línea: (texto, importe). Importe null = título de
  /// sección en negrita; texto '-' = raya; texto que empieza por '!' = fila en negrita.
  static Future<void> imprimirInforme(String titulo, List<String> cabecera, List<(String, String?)> lineas) async {
    final r = await red(ticket);
    if (r != null) {
      final t = r.ticket()..linea(titulo, centro: true, grande: true);
      for (final c in cabecera) {
        t.linea(c, centro: true);
      }
      t.raya();
      for (final (a, b) in lineas) {
        if (a == '-') {
          t.raya();
        } else if (b == null) {
          t.linea(a, fuerte: true);
        } else if (a.startsWith('!')) {
          t.fila(a.substring(1), b, fuerte: true, alto: true);
        } else {
          t.fila(a, b);
        }
      }
      t.cortar();
      return r.enviar(t);
    }
    final (fuente, negrita) = await _fuentes();
    final s = pw.TextStyle(font: fuente, fontSize: 8);
    final n = pw.TextStyle(font: negrita, fontSize: 8);
    final doc = pw.Document()
      ..addPage(pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(4 * PdfPageFormat.mm),
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Text(titulo, textAlign: pw.TextAlign.center, style: n.copyWith(fontSize: 11)),
          for (final c in cabecera) pw.Text(c, textAlign: pw.TextAlign.center, style: s),
          _raya(),
          for (final (a, b) in lineas)
            if (a == '-')
              _raya()
            else if (b == null)
              pw.Padding(padding: const pw.EdgeInsets.only(top: 2), child: pw.Text(a, style: n))
            else if (a.startsWith('!'))
              _fila(a.substring(1), b, n.copyWith(fontSize: 10))
            else
              _fila(a, b, s),
        ]),
      ));
    await _imprimir(ticket, titulo, doc);
  }
}
