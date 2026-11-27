import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/csv.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../gestion/comun.dart' show leerTodo;
import '../ticketbai/modelos.dart' show euros;

enum _Periodo { hoy, ayer, semana, mes, ano, elegir }

const _nombresPeriodo = {
  _Periodo.hoy: 'Hoy',
  _Periodo.ayer: 'Ayer',
  _Periodo.semana: 'Últimos 7 días',
  _Periodo.mes: 'Este mes',
  _Periodo.ano: 'Este año',
  _Periodo.elegir: 'Elegir fechas…',
};
const _metodos = {'efectivo': 'Efectivo', 'tarjeta': 'Tarjeta', 'bizum': 'Bizum', 'credito': 'Crédito'};

/// Informes de ventas: cifras clave, formas de pago, horas, productos y camareros.
class InformesPage extends StatefulWidget {
  const InformesPage({super.key});

  @override
  State<InformesPage> createState() => _InformesPageState();
}

class _InformesPageState extends State<InformesPage> {
  _Periodo _periodo = _Periodo.hoy;
  DateTimeRange? _elegido;
  bool _cargando = true;
  String? _error;
  List<Map<String, dynamic>> _pedidos = [];
  Map<String, String> _nombres = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  (DateTime, DateTime) _rango() {
    final ahora = DateTime.now();
    final hoy = DateTime(ahora.year, ahora.month, ahora.day);
    return switch (_periodo) {
      _Periodo.hoy => (hoy, hoy.add(const Duration(days: 1))),
      _Periodo.ayer => (hoy.subtract(const Duration(days: 1)), hoy),
      _Periodo.semana => (hoy.subtract(const Duration(days: 6)), hoy.add(const Duration(days: 1))),
      _Periodo.mes => (DateTime(ahora.year, ahora.month), hoy.add(const Duration(days: 1))),
      _Periodo.ano => (DateTime(ahora.year), hoy.add(const Duration(days: 1))),
      _Periodo.elegir => (_elegido!.start, _elegido!.end.add(const Duration(days: 1))),
    };
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final (desde, hasta) = _rango();
    try {
      final pedidos = await leerTodo((a, b) => supabase
          .from('pedidos')
          .select('id, numero, tipo, nombre_llevar, mesas(nombre), total, num_personas, pagado_en, camarero_id, '
              'pagos(metodo, importe), pedido_detalle(descripcion, cantidad, precio_unitario, estado_cocina)')
          .eq('estado', 'pagado')
          .gte('pagado_en', desde.toUtc().toIso8601String())
          .lt('pagado_en', hasta.toUtc().toIso8601String())
          .order('pagado_en')
          .range(a, b));
      final perfiles = await supabase.rpc('equipo_empresa') as List; // también para Gestión (perfiles solo lo lee el admin)
      _pedidos = List<Map<String, dynamic>>.from(pedidos);
      _nombres = {for (final p in perfiles) p['id'] as String: p['nombre'] as String};
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _Periodo.values)
              ChoiceChip(
                label: Text(_nombresPeriodo[p]!),
                selected: p == _periodo,
                showCheckmark: false,
                onSelected: (_) async {
                  if (p == _Periodo.elegir) {
                    final hoy = DateTime.now();
                    final r = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2024),
                      lastDate: hoy,
                      initialDateRange: _elegido ?? DateTimeRange(start: hoy.subtract(const Duration(days: 7)), end: hoy),
                      locale: const Locale('es'),
                    );
                    if (r == null) return;
                    _elegido = r;
                  }
                  _periodo = p;
                  _cargar();
                },
              ),
          ],
        ),
        if (_periodo == _Periodo.elegir && _elegido != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Del ${_d(_elegido!.start)} al ${_d(_elegido!.end)}', style: const TextStyle(color: C.gris)),
          ),
        const SizedBox(height: 12),
        if (!_cargando && _error == null && _pedidos.isNotEmpty)
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(onPressed: _exportarCsv, icon: const Icon(Icons.table_view_outlined), label: const Text('Exportar a Excel (CSV)')),
            OutlinedButton.icon(onPressed: _imprimir, icon: const Icon(Icons.print_outlined), label: const Text('Imprimir resumen')),
          ]),
        const SizedBox(height: 16),
        if (_cargando)
          const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Text(textoError(_error))
        else if (_pedidos.isEmpty)
          Padding(
            padding: const EdgeInsets.all(48),
            child: Center(
              child: Text('Sin ventas cobradas en este periodo',
                  style: titulo(20, color: C.gris, peso: FontWeight.w500)),
            ),
          )
        else
          ..._contenido(),
      ],
    );
  }

  List<Widget> _contenido() {
    final total = _pedidos.fold(0.0, (s, p) => s + (p['total'] as num).toDouble());
    final tickets = _pedidos.length;
    final comensales = _pedidos.fold(0, (s, p) => s + ((p['num_personas'] as int?) ?? 0));
    final base = total / 1.10;

    // Formas de pago
    final porMetodo = <String, double>{};
    for (final p in _pedidos) {
      for (final pago in (p['pagos'] as List)) {
        final m = pago['metodo'] as String;
        porMetodo[m] = (porMetodo[m] ?? 0) + (pago['importe'] as num).toDouble();
      }
    }

    // Por hora (o por día si el periodo es largo)
    final (d0, d1) = _rango();
    final dias = d1.difference(d0).inDays;
    final porMes = dias > 62;
    final porDia = !porMes && dias > 1;
    final franjas = <String, double>{};
    for (final p in _pedidos) {
      final f = DateTime.parse(p['pagado_en'] as String).toLocal();
      final clave = porMes ? '${f.month.toString().padLeft(2, '0')}/${f.year}' : porDia ? '${f.day.toString().padLeft(2, '0')}/${f.month.toString().padLeft(2, '0')}' : '${f.hour.toString().padLeft(2, '0')}h';
      franjas[clave] = (franjas[clave] ?? 0) + (p['total'] as num).toDouble();
    }
    final claves = franjas.keys.toList()..sort((a, b) => _ordenFranja(a).compareTo(_ordenFranja(b)));

    // Productos
    final productos = <String, ({double uds, double importe})>{};
    for (final p in _pedidos) {
      for (final d in (p['pedido_detalle'] as List)) {
        if (d['estado_cocina'] == 'anulado') continue;
        final n = d['descripcion'] as String;
        final uds = (d['cantidad'] as num).toDouble();
        final imp = uds * (d['precio_unitario'] as num).toDouble();
        final prev = productos[n];
        productos[n] = (uds: (prev?.uds ?? 0) + uds, importe: (prev?.importe ?? 0) + imp);
      }
    }
    final top = productos.entries.toList()..sort((a, b) => b.value.importe.compareTo(a.value.importe));

    // Camareros
    final porCamarero = <String, ({int tickets, double importe})>{};
    for (final p in _pedidos) {
      final n = _nombres[p['camarero_id']] ?? 'Sin asignar';
      final prev = porCamarero[n];
      porCamarero[n] = (tickets: (prev?.tickets ?? 0) + 1, importe: (prev?.importe ?? 0) + (p['total'] as num).toDouble());
    }
    final camareros = porCamarero.entries.toList()..sort((a, b) => b.value.importe.compareTo(a.value.importe));

    return [
      Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          _Cifra('Ventas', euros(total), 'IVA incluido', destacada: true),
          _Cifra('Tickets', '$tickets', null),
          _Cifra('Ticket medio', euros(total / tickets), null),
          _Cifra('Comensales', '$comensales', comensales > 0 ? '${euros(total / comensales)} por persona' : null),
          _Cifra('Base imponible', euros(base), 'IVA 10 %: ${euros(total - base)}'),
        ],
      ),
      const SizedBox(height: 28),
      LayoutBuilder(
        builder: (context, c) {
          final dos = c.maxWidth > 900;
          final izquierda = [
            _Bloque(
              nombre: porDia ? 'Ventas por día' : 'Ventas por hora',
              hijos: [for (final k in claves) _Barra(k, franjas[k]!, franjas.values.reduce(_max), euros(franjas[k]!))],
            ),
            _Bloque(
              nombre: 'Formas de pago',
              hijos: [
                for (final e in porMetodo.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                  _Barra(_metodos[e.key] ?? e.key, e.value, total,
                      '${euros(e.value)} · ${(e.value / total * 100).toStringAsFixed(0)} %'),
              ],
            ),
          ];
          final derecha = [
            _Bloque(
              nombre: 'Productos más vendidos',
              hijos: [
                for (final e in top.take(10))
                  _Barra(e.key, e.value.importe, top.first.value.importe,
                      '${e.value.uds.toStringAsFixed(0)} uds · ${euros(e.value.importe)}'),
              ],
            ),
            _Bloque(
              nombre: 'Ventas por camarero',
              hijos: [
                for (final e in camareros)
                  _Barra(e.key, e.value.importe, camareros.first.value.importe,
                      '${e.value.tickets} tickets · ${euros(e.value.importe)}'),
              ],
            ),
          ];
          if (!dos) return Column(children: [...izquierda, ...derecha]);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(children: izquierda)),
              const SizedBox(width: 20),
              Expanded(child: Column(children: derecha)),
            ],
          );
        },
      ),
    ];
  }

  static double _max(double a, double b) => a > b ? a : b;

  static String _d(DateTime f) => '${f.day.toString().padLeft(2, '0')}/${f.month.toString().padLeft(2, '0')}/${f.year}';
  static String _n(num v) => v.toStringAsFixed(2).replaceAll('.', ',');

  String get _textoPeriodo {
    final (desde, hasta) = _rango();
    return 'Del ${_d(desde)} al ${_d(hasta.subtract(const Duration(days: 1)))}';
  }

  String _dondePedido(Map<String, dynamic> p) {
    final mesa = (p['mesas'] as Map?)?['nombre'];
    if (mesa != null) return 'Mesa $mesa';
    if (p['tipo'] == 'barra') return 'Barra';
    return 'Llevar ${p['nombre_llevar'] ?? ''}';
  }

  /// CSV con ; y BOM para que Excel en español lo abra bien.
  Future<void> _exportarCsv() async {
    final b = StringBuffer('\uFEFF');
    b.writeln('Fecha;Hora;Pedido;Dónde;Camarero;Comensales;Efectivo;Tarjeta;Bizum;Total');
    for (final p in _pedidos) {
      final f = DateTime.parse(p['pagado_en'] as String).toLocal();
      double m(String metodo) => (p['pagos'] as List)
          .where((x) => x['metodo'] == metodo)
          .fold(0.0, (s, x) => s + (x['importe'] as num).toDouble());
      b.writeln([
        _d(f),
        '${f.hour.toString().padLeft(2, '0')}:${f.minute.toString().padLeft(2, '0')}',
        p['numero'],
        celdaCsv(_dondePedido(p)),
        celdaCsv(_nombres[p['camarero_id']] ?? ''),
        p['num_personas'] ?? '',
        _n(m('efectivo')),
        _n(m('tarjeta')),
        _n(m('bizum')),
        _n(p['total'] as num),
      ].join(';'));
    }
    b.writeln();
    b.writeln('Producto;Unidades;Importe');
    final prod = <String, (double, double)>{};
    for (final p in _pedidos) {
      for (final d in (p['pedido_detalle'] as List)) {
        if (d['estado_cocina'] == 'anulado') continue;
        final u = (d['cantidad'] as num).toDouble();
        final prev = prod[d['descripcion']] ?? (0.0, 0.0);
        prod[d['descripcion'] as String] = (prev.$1 + u, prev.$2 + u * (d['precio_unitario'] as num));
      }
    }
    for (final e in prod.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2))) {
      b.writeln('${celdaCsv(e.key)};${e.value.$1.toStringAsFixed(0)};${_n(e.value.$2)}');
    }
    final bytes = utf8.encode(b.toString());
    final (desde, _) = _rango();
    final ruta = await FilePicker.saveFile(
      dialogTitle: 'Guardar informe',
      fileName: 'ventas_${desde.year}-${desde.month.toString().padLeft(2, '0')}-${desde.day.toString().padLeft(2, '0')}.csv',
      bytes: bytes,
    );
    if (ruta == null) return;
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Informe guardado')));
  }

  Future<void> _imprimir() async {
    final total = _pedidos.fold(0.0, (s, p) => s + (p['total'] as num).toDouble());
    final base = total / 1.10;
    final porMetodo = <String, double>{};
    final prod = <String, (double, double)>{};
    final cam = <String, (int, double)>{};
    for (final p in _pedidos) {
      for (final x in (p['pagos'] as List)) {
        porMetodo[x['metodo'] as String] = (porMetodo[x['metodo']] ?? 0) + (x['importe'] as num).toDouble();
      }
      for (final d in (p['pedido_detalle'] as List)) {
        if (d['estado_cocina'] == 'anulado') continue;
        final u = (d['cantidad'] as num).toDouble();
        final prev = prod[d['descripcion']] ?? (0.0, 0.0);
        prod[d['descripcion'] as String] = (prev.$1 + u, prev.$2 + u * (d['precio_unitario'] as num));
      }
      final n = _nombres[p['camarero_id']] ?? 'Sin asignar';
      final prev = cam[n] ?? (0, 0.0);
      cam[n] = (prev.$1 + 1, prev.$2 + (p['total'] as num).toDouble());
    }
    final top = prod.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    pw.Widget tabla(List<String> cab, List<List<String>> filas) => pw.TableHelper.fromTextArray(
          headers: cab,
          data: filas,
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          cellAlignments: {for (var i = 1; i < cab.length; i++) i: pw.Alignment.centerRight},
        );
    pw.ThemeData tema;
    try {
      tema = pw.ThemeData.withFont(base: await PdfGoogleFonts.robotoRegular(), bold: await PdfGoogleFonts.robotoBold());
    } catch (_) {
      tema = pw.ThemeData.base();
    }
    final doc = pw.Document()
      ..addPage(pw.MultiPage(
        theme: tema,
        pageFormat: PdfPageFormat.a4,
        build: (_) => [
          pw.Text('Informe de ventas', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.Text(_textoPeriodo),
          pw.SizedBox(height: 16),
          tabla(['Concepto', 'Importe'], [
            ['Ventas (IVA incl.)', euros(total)],
            ['Base imponible', euros(base)],
            ['IVA 10 %', euros(total - base)],
            ['Tickets', '${_pedidos.length}'],
            ['Ticket medio', euros(total / _pedidos.length)],
          ]),
          pw.SizedBox(height: 16),
          pw.Text('Formas de pago', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          tabla(['Método', 'Importe'], [for (final e in porMetodo.entries) [_metodos[e.key] ?? e.key, euros(e.value)]]),
          pw.SizedBox(height: 16),
          pw.Text('Productos más vendidos', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          tabla(['Producto', 'Uds.', 'Importe'],
              [for (final e in top.take(20)) [e.key, e.value.$1.toStringAsFixed(0), euros(e.value.$2)]]),
          pw.SizedBox(height: 16),
          pw.Text('Ventas por camarero', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          tabla(['Camarero', 'Tickets', 'Importe'], [for (final e in cam.entries) [e.key, '${e.value.$1}', euros(e.value.$2)]]),
        ],
      ));
    await Printing.layoutPdf(name: 'Informe de ventas', onLayout: (_) async => doc.save());
  }

  /// "09h" y "dd/mm" ordenables
  static String _ordenFranja(String k) {
    if (k.endsWith('h')) return k;
    final p = k.split('/');
    return '${p[1]}${p[0]}';
  }
}

class _Bloque extends StatelessWidget {
  const _Bloque({required this.nombre, required this.hijos});
  final String nombre;
  final List<Widget> hijos;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: C.blanco,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: C.borde),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(nombre, style: titulo(18)),
            const SizedBox(height: 14),
            if (hijos.isEmpty) const Text('Sin datos', style: TextStyle(color: C.gris)),
            ...hijos,
          ],
        ),
      );
}

/// Barra horizontal: etiqueta, barra proporcional y valor.
class _Barra extends StatelessWidget {
  const _Barra(this.etiqueta, this.valor, this.maximo, this.texto);
  final String etiqueta;
  final double valor;
  final double maximo;
  final String texto;

  @override
  Widget build(BuildContext context) {
    final f = maximo <= 0 ? 0.0 : (valor / maximo).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(etiqueta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: (c.maxWidth * f).clamp(4.0, c.maxWidth),
                  height: 22,
                  decoration: BoxDecoration(color: C.verde, borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 170,
            child: Text(texto,
                textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _Cifra extends StatelessWidget {
  const _Cifra(this.etiqueta, this.valor, this.detalle, {this.destacada = false});
  final String etiqueta;
  final String valor;
  final String? detalle;
  final bool destacada;

  @override
  Widget build(BuildContext context) {
    final fg = destacada ? C.sobreAccion : C.tinta;
    return Container(
      width: 230,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: destacada ? C.verde : C.blanco,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: destacada ? C.verde : C.borde),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(etiqueta, style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 13)),
          const SizedBox(height: 6),
          Text(valor, style: titulo(28, color: fg)),
          if (detalle != null) Text(detalle!, style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12)),
        ],
      ),
    );
  }
}
