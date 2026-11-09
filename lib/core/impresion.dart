import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/ticketbai/modelos.dart' show Desglose, LineaFactura, euros;
import 'escpos.dart';

/// Impresión de tickets: directa por red (ESC/POS) o en PDF por la impresora del sistema.
/// Cada equipo guarda qué impresora usa para: ticket, Cocina y Barra.
class Impresion {
  static const ticket = 'ticket';

  static Future<String?> impresora(String uso) async =>
      (await SharedPreferences.getInstance()).getString('impresora_$uso');

  static Future<void> guardar(String uso, String? url) async {
    final p = await SharedPreferences.getInstance();
    url == null ? await p.remove('impresora_$uso') : await p.setString('impresora_$uso', url);
  }

  static Future<ImpresoraRed?> red(String uso) async => ImpresoraRed.desde(await impresora(uso));

  /// Abre el cajón conectado a la impresora de tickets (si es de red).
  static Future<void> abrirCajon() async {
    final r = await red(ticket);
    if (r == null) return;
    await r.enviar(EscPos(r.columnas)..abrirCajon());
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

  /// Factura simplificada / factura con NIF, con código y QR TicketBAI.
  static Future<void> imprimirTicket(Map<String, dynamic> f, {bool soloSiConfigurada = false, bool cajon = false}) async {
    final lineasF = (f['lineas'] as List).map((m) => LineaFactura.fromMap(Map<String, dynamic>.from(m as Map))).toList();
    final r = await red(ticket);
    if (r != null) {
      final t = EscPos(r.columnas)
        ..linea('${f['razon_social_emisor']}', centro: true, grande: true)
        ..linea('NIF ${f['nif_emisor']}', centro: true)
        ..raya()
        ..linea(f['tipo'] == 'completa' ? 'FACTURA' : 'FACTURA SIMPLIFICADA', fuerte: true)
        ..linea('Nº ${f['serie']}-${f['numero']}')
        ..linea(_fecha(DateTime.parse(f['fecha'] as String).toLocal()));
      if (f['tipo'] == 'completa') {
        t
          ..raya()
          ..linea('Cliente: ${f['cliente_nombre']}')
          ..linea('NIF: ${f['cliente_nif']}');
        if ((f['cliente_direccion'] as String?)?.isNotEmpty ?? false) t.linea('${f['cliente_direccion']}');
      }
      t.raya();
      for (final l in lineasF) {
        t.fila('${l.cantidad.toStringAsFixed(0)} ${l.descripcion}', _importe(l.total));
      }
      t.raya();
      for (final tr in Desglose.deFactura(f)) {
        t
          ..fila('Base ${tr.tipo.toStringAsFixed(0)} %', euros(tr.base))
          ..fila('IVA ${tr.tipo.toStringAsFixed(0)} %', euros(tr.cuota));
      }
      t
        ..fila('TOTAL (IVA incl.)', euros(f['importe_total'] as num), fuerte: true, alto: true)
        ..raya()
        // Anexo V: código en una línea y debajo el QR, de 30 a 40 mm (módulo 6 a 203 ppp ≈ 31-34 mm)
        ..linea('${f['tbai_id']}', centro: true)
        ..qr(f['qr_url'] as String, modulo: 6);
      if (f['estado_envio'] == 'pendiente') t.linea('QR operativo cuando se complete el envio', centro: true);
      if (f['estado_envio'] == 'simulada') t.linea('MODO SIMULADO - NO VALIDA FISCALMENTE', centro: true, fuerte: true);
      t
        ..raya()
        ..linea('Gracias por su visita · Eskerrik asko', centro: true);
      if (cajon) t.abrirCajon();
      t.cortar();
      return r.enviar(t);
    }
    final (fuente, negrita) = await _fuentes();
    final s = pw.TextStyle(font: fuente, fontSize: 8);
    final b = pw.TextStyle(font: negrita, fontSize: 8);
    final lineas = lineasF;
    final doc = pw.Document()
      ..addPage(pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(4 * PdfPageFormat.mm),
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Text('${f['razon_social_emisor']}', textAlign: pw.TextAlign.center, style: b.copyWith(fontSize: 10)),
          pw.Text('NIF ${f['nif_emisor']}', textAlign: pw.TextAlign.center, style: s),
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
      final t = EscPos(r.columnas)
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
      final t = EscPos(r.columnas)
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
}
