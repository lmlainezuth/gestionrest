import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/csv.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/modelos.dart' show euros;
import 'comun.dart';

enum _Vista { mes, ano, fechas }

const _diasSemana = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const _letrasSemana = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
DateTime _dia(DateTime d) => DateTime(d.year, d.month, d.day);

/// Ventas de un periodo: por día (la caja diaria manda; si ese día no hay, lo cobrado en el TPV)
/// y cómo se cobró (efectivo, tarjeta, Bizum) en los días que tienen ese desglose.
class _Ventas {
  final Map<String, double> dia = {};
  double efectivo = 0, tarjeta = 0, bizum = 0;
  int diasDesglose = 0;
}

Future<_Ventas> _ventasEntre(DateTime d, DateTime h) async {
  final r = await Future.wait([
    leerTodo((a, b) => supabase
        .from('cajas_diarias')
        .select('fecha, total, efectivo, tarjeta')
        .gte('fecha', iso(d))
        .lte('fecha', iso(h))
        .range(a, b)),
    leerTodo((a, b) => supabase
        .from('pedidos')
        .select('total, pagado_en, pagos(metodo, importe)')
        .eq('estado', 'pagado')
        .gte('pagado_en', d.toUtc().toIso8601String())
        .lt('pagado_en', h.add(const Duration(days: 1)).toUtc().toIso8601String())
        .range(a, b)),
  ]);
  final v = _Ventas();
  final cajas = <String, double>{};
  final conDesglose = <String>{};
  for (final c in r[0]) {
    final f = c['fecha'] as String;
    cajas[f] = (cajas[f] ?? 0) + (c['total'] as num).toDouble();
    if (c['efectivo'] != null || c['tarjeta'] != null) {
      v.efectivo += (c['efectivo'] as num?)?.toDouble() ?? 0;
      v.tarjeta += (c['tarjeta'] as num?)?.toDouble() ?? 0;
      conDesglose.add(f);
    }
  }
  final tpv = <String, double>{};
  final tpvPagos = <String, List<dynamic>>{};
  for (final p in r[1]) {
    final f = iso(DateTime.parse(p['pagado_en'] as String).toLocal());
    tpv[f] = (tpv[f] ?? 0) + (p['total'] as num).toDouble();
    (tpvPagos[f] ??= []).addAll((p['pagos'] as List?) ?? const []);
  }
  tpvPagos.forEach((f, pagos) {
    if (cajas.containsKey(f) || pagos.isEmpty) return;
    for (final pg in pagos) {
      final imp = (pg['importe'] as num).toDouble();
      switch (pg['metodo']) {
        case 'efectivo':
          v.efectivo += imp;
        case 'tarjeta':
          v.tarjeta += imp;
        default:
          v.bizum += imp;
      }
    }
    conDesglose.add(f);
  });
  v.dia.addAll({...tpv, ...cajas});
  v.diasDesglose = conDesglose.length;
  return v;
}

Future<List<Map<String, dynamic>>> _gastosEntre(DateTime d, DateTime h) => leerTodo((a, b) =>
    supabase.from('gastos').select('*, proveedores(nombre)').gte('fecha', iso(d)).lte('fecha', iso(h)).range(a, b));

/// Resumen del negocio: ventas, gastos, resultado e IVA, comparado con el periodo anterior.
class ResumenPage extends StatefulWidget {
  const ResumenPage({super.key});

  @override
  State<ResumenPage> createState() => _ResumenPageState();
}

class _ResumenPageState extends State<ResumenPage> {
  _Vista _vista = _Vista.mes; // abre en el mes actual; Año y fechas a un toque
  DateTime _ref = DateTime.now();
  DateTimeRange? _fechas;
  Map<String, double> _ventas = {}, _ventasAnt = {}, _ultimos = {};
  List<Map<String, dynamic>> _gastos = [], _gastosAnt = [], _pendientes = [];
  _Ventas _desglose = _Ventas();
  // Base habitual: los 3 meses completos anteriores al mes actual
  Map<String, double> _histVentas = {};
  List<Map<String, dynamic>> _histGastos = [];
  double _ivaVenta = 10;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  DateTime get _hoy => _dia(DateTime.now());

  (DateTime, DateTime) get _rango => switch (_vista) {
        _Vista.mes => (DateTime(_ref.year, _ref.month, 1), DateTime(_ref.year, _ref.month + 1, 0)),
        _Vista.ano => (DateTime(_ref.year, 1, 1), DateTime(_ref.year, 12, 31)),
        _Vista.fechas => (_dia(_fechas!.start), _dia(_fechas!.end)),
      };

  /// Periodo con el que se compara. Si el actual está en curso, se compara hasta el mismo día.
  (DateTime, DateTime) get _rangoAnt {
    final (d, h) = _rango;
    switch (_vista) {
      case _Vista.mes:
        final ini = DateTime(d.year, d.month - 1, 1), fin = DateTime(d.year, d.month, 0);
        if (!_hoy.isBefore(d) && !_hoy.isAfter(h)) {
          final corte = DateTime(ini.year, ini.month, _hoy.day);
          return (ini, corte.isAfter(fin) ? fin : corte);
        }
        return (ini, fin);
      case _Vista.ano:
        final ini = DateTime(d.year - 1, 1, 1);
        if (_hoy.year == d.year) return (ini, DateTime(d.year - 1, _hoy.month, _hoy.day));
        return (ini, DateTime(d.year - 1, 12, 31));
      case _Vista.fechas:
        final n = h.difference(d).inDays + 1;
        return (DateTime(d.year, d.month, d.day - n), DateTime(d.year, d.month, d.day - 1));
    }
  }

  String get _nombreAnt {
    final (d, h) = _rangoAnt;
    return switch (_vista) {
      _Vista.mes => '${_cap(meses[d.month - 1])}${h.day < DateTime(d.year, d.month + 1, 0).day ? ' hasta el ${h.day}' : ''}',
      _Vista.ano => '${d.year}${h.month < 12 || h.day < 31 ? ' hasta el ${h.day}/${h.month}' : ''}',
      _Vista.fechas => 'los ${h.difference(d).inDays + 1} días anteriores',
    };
  }

  String get _textoPeriodo => switch (_vista) {
        _Vista.mes => '${_cap(meses[_ref.month - 1])} ${_ref.year}',
        _Vista.ano => 'Año ${_ref.year}',
        _Vista.fechas => '${fechaCorta(iso(_fechas!.start))}/${_fechas!.start.year} – ${fechaCorta(iso(_fechas!.end))}/${_fechas!.end.year}',
      };

  String? _errorCarga;

  /// Carga sin quedarse colgada: sin internet enseña el aviso y se reintenta sola.
  Future<void> _cargar() async {
    try {
      await online(_cargarDatos);
      if (_errorCarga != null && mounted) setState(() => _errorCarga = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorCarga = textoError(e);
          _cargando = false;
        });
      }
    }
  }

  Future<void> _cargarDatos() async {
    setState(() => _cargando = true);
    final (d, h) = _rango;
    final (da, ha) = _rangoAnt;
    final r = await Future.wait<Object>([
      _ventasEntre(d, h),
      _ventasEntre(da, ha),
      _ventasEntre(DateTime(_hoy.year, _hoy.month, _hoy.day - 13), _hoy),
      _gastosEntre(d, h),
      _gastosEntre(da, ha),
      supabase.from('gastos').select('*, proveedores(nombre)').eq('estado', 'pendiente').order('fecha'),
      supabase.from('empresa').select('impuesto_porcentaje').limit(1),
      _ventasEntre(DateTime(_hoy.year, _hoy.month - 3, 1), DateTime(_hoy.year, _hoy.month, 0)),
      _gastosEntre(DateTime(_hoy.year, _hoy.month - 3, 1), DateTime(_hoy.year, _hoy.month, 0)),
    ]);
    _desglose = r[0] as _Ventas;
    _ventas = _desglose.dia;
    _ventasAnt = (r[1] as _Ventas).dia;
    _ultimos = (r[2] as _Ventas).dia;
    _histVentas = (r[7] as _Ventas).dia;
    _histGastos = List<Map<String, dynamic>>.from(r[8] as List);
    _gastos = List<Map<String, dynamic>>.from(r[3] as List);
    _gastosAnt = List<Map<String, dynamic>>.from(r[4] as List);
    _pendientes = List<Map<String, dynamic>>.from(r[5] as List);
    final emp = r[6] as List;
    if (emp.isNotEmpty) _ivaVenta = (emp.first['impuesto_porcentaje'] as num).toDouble();
    if (mounted) setState(() => _cargando = false);
  }

  void _mover(int paso) {
    _ref = _vista == _Vista.ano ? DateTime(_ref.year + paso) : DateTime(_ref.year, _ref.month + paso);
    _cargar();
  }

  Future<void> _elegirVista(_Vista v) async {
    if (v == _Vista.fechas) {
      final ahora = DateTime.now();
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: ahora,
        initialDateRange: _fechas ?? DateTimeRange(start: DateTime(ahora.year, ahora.month, 1), end: ahora),
      );
      if (r == null) return;
      _fechas = r;
    } else {
      _ref = DateTime.now();
    }
    _vista = v;
    _cargar();
  }

  /// Ir al detalle de un mes desde el año (al tocar una columna).
  void _abrirMes(int ano, int mes) {
    _vista = _Vista.mes;
    _ref = DateTime(ano, mes);
    _cargar();
  }

  Widget _cabecera() {
    final esActual = _vista == _Vista.ano ? _ref.year == _hoy.year : (_ref.year == _hoy.year && _ref.month == _hoy.month);
    return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SegmentedButton<_Vista>(
        segments: const [
          ButtonSegment(value: _Vista.mes, label: Text('Mes'), icon: Icon(Icons.calendar_view_month)),
          ButtonSegment(value: _Vista.ano, label: Text('Año'), icon: Icon(Icons.calendar_today)),
          ButtonSegment(value: _Vista.fechas, label: Text('Elegir fechas'), icon: Icon(Icons.date_range)),
        ],
        selected: {_vista},
        showSelectedIcon: false,
        onSelectionChanged: (s) => _elegirVista(s.first),
      ),
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (_vista != _Vista.fechas)
          IconButton(tooltip: 'Anterior', onPressed: () => _mover(-1), icon: const Icon(Icons.chevron_left)),
        Text(_textoPeriodo, style: titulo(20)),
        if (_vista != _Vista.fechas)
          IconButton(tooltip: 'Siguiente', onPressed: esActual ? null : () => _mover(1), icon: const Icon(Icons.chevron_right)),
        if (_vista == _Vista.fechas) TextButton(onPressed: () => _elegirVista(_Vista.fechas), child: const Text('Cambiar')),
      ]),
      if (!_cargando) ...[
        OutlinedButton.icon(onPressed: _exportarPdf, icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('PDF')),
        OutlinedButton.icon(onPressed: _exportarCsv, icon: const Icon(Icons.table_view_outlined), label: const Text('Excel')),
      ],
    ]);
  }

  ({
    double ventas, double gastos, double resultado, double media, int dias, double iva, double? pctMateria,
    Map<String, ({double ventas, double gastos})> evolucion, bool porMes,
    Map<String, double> porCat, Map<String, double> porProv,
    List<({String nombre, double cobrado, double pagado})> trimestres,
  })? _paraExportar;

  static String _n(num v) => v.toStringAsFixed(2).replaceAll('.', ',');
  String _etiquetaPeriodo(String k, bool porMes) =>
      porMes ? '${_cap(meses[int.parse(k.substring(5)) - 1])} ${k.substring(0, 4)}' : '${fechaCorta(k)}/${k.substring(0, 4)}';

  /// Excel (CSV con ; y BOM, para Excel en español).
  Future<void> _exportarCsv() async {
    final x = _paraExportar;
    if (x == null) return;
    final b = StringBuffer('\uFEFF')
      ..writeln('Resumen;$_textoPeriodo')
      ..writeln('Ventas;${_n(x.ventas)}')
      ..writeln('Gastos;${_n(x.gastos)}')
      ..writeln('Resultado;${_n(x.resultado)}')
      ..writeln('Media por día abierto;${_n(x.media)}')
      ..writeln('Días abiertos;${x.dias}')
      ..writeln('IVA a apartar;${_n(x.iva)}')
      ..writeln()
      ..writeln('${x.porMes ? 'Mes' : 'Día'};Ventas;Gastos;Resultado');
    x.evolucion.forEach((k, v) => b.writeln('${_etiquetaPeriodo(k, x.porMes)};${_n(v.ventas)};${_n(v.gastos)};${_n(v.ventas - v.gastos)}'));
    b
      ..writeln()
      ..writeln('Categoría;Gasto');
    for (final e in categorias.entries) {
      b.writeln('${e.value};${_n(x.porCat[e.key] ?? 0)}');
    }
    b
      ..writeln()
      ..writeln('Proveedor;Gasto');
    for (final e in x.porProv.entries.toList()..sort((a, c) => c.value.compareTo(a.value))) {
      b.writeln('${celdaCsv(e.key)};${_n(e.value)}');
    }
    if (x.trimestres.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Trimestre;IVA cobrado;IVA pagado;A apartar');
      for (final t in x.trimestres) {
        b.writeln('${t.nombre};${_n(t.cobrado)};${_n(t.pagado)};${_n(t.cobrado - t.pagado)}');
      }
    }
    await FilePicker.saveFile(
      dialogTitle: 'Guardar resumen',
      fileName: 'resumen_${_textoPeriodo.replaceAll(' ', '_').replaceAll('/', '-')}.csv',
      bytes: utf8.encode(b.toString()),
    );
  }

  /// PDF para imprimir o enviar a la gestoría.
  Future<void> _exportarPdf() async {
    final x = _paraExportar;
    if (x == null) return;
    pw.Widget fila(String a, String b, {bool fuerte = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Row(children: [
            pw.Expanded(child: pw.Text(a, style: pw.TextStyle(fontWeight: fuerte ? pw.FontWeight.bold : null))),
            pw.Text(b, style: pw.TextStyle(fontWeight: fuerte ? pw.FontWeight.bold : null)),
          ]),
        );
    final doc = pw.Document()
      ..addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (_) => [
          pw.Text('Resumen · $_textoPeriodo', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 12),
          fila('Ventas', euros(x.ventas), fuerte: true),
          fila('Gastos', euros(x.gastos)),
          fila('Resultado', euros(x.resultado), fuerte: true),
          fila('Media por día abierto', euros(x.media)),
          fila('Días abiertos', '${x.dias}'),
          fila('IVA a apartar (aprox.)', euros(x.iva)),
          if (x.pctMateria != null) fila('Materia prima sobre ventas', '${x.pctMateria!.round()} %'),
          pw.SizedBox(height: 16),
          pw.Text(x.porMes ? 'Por mes' : 'Por día', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.TableHelper.fromTextArray(
            headers: [x.porMes ? 'Mes' : 'Día', 'Ventas', 'Gastos', 'Resultado'],
            data: [
              for (final e in x.evolucion.entries)
                if (e.value.ventas > 0 || e.value.gastos > 0)
                  [_etiquetaPeriodo(e.key, x.porMes), euros(e.value.ventas), euros(e.value.gastos), euros(e.value.ventas - e.value.gastos)],
            ],
            cellAlignments: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
          ),
          pw.SizedBox(height: 16),
          pw.Text('Gastos por categoría', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          for (final e in categorias.entries) fila(e.value, euros(x.porCat[e.key] ?? 0)),
          pw.SizedBox(height: 16),
          pw.Text('Gasto por proveedor', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          for (final e in x.porProv.entries.toList()..sort((a, c) => c.value.compareTo(a.value))) fila(e.key, euros(e.value)),
          if (x.trimestres.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text('IVA por trimestre (aprox.)', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.TableHelper.fromTextArray(
              headers: ['Trimestre', 'Cobrado', 'Pagado', 'A apartar'],
              data: [for (final t in x.trimestres) [t.nombre, euros(t.cobrado), euros(t.pagado), euros(t.cobrado - t.pagado)]],
              cellAlignments: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
            ),
          ],
        ],
      ));
    await Printing.layoutPdf(name: 'Resumen $_textoPeriodo', onLayout: (_) async => doc.save());
  }

  static double _suma(Iterable<double> v) => v.fold(0.0, (a, b) => a + b);
  static double _sumaGastos(List<Map<String, dynamic>> g) => g.fold(0.0, (s, x) => s + (x['importe'] as num).toDouble());

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    if (_cargando) {
      return Column(children: [
        Padding(padding: const EdgeInsets.all(28), child: _cabecera()),
        const Expanded(child: Center(child: CircularProgressIndicator())),
      ]);
    }
    // --- Cifras del periodo y del anterior ---
    final ventas = _suma(_ventas.values), ventasAnt = _suma(_ventasAnt.values);
    final gastos = _sumaGastos(_gastos), gastosAnt = _sumaGastos(_gastosAnt);
    final resultado = ventas - gastos, resultadoAnt = ventasAnt - gastosAnt;
    final abiertos = _ventas.entries.where((e) => e.value > 0).toList()..sort((a, b) => a.key.compareTo(b.key));
    final abiertosAnt = _ventasAnt.values.where((v) => v > 0).length;
    final media = abiertos.isEmpty ? 0.0 : ventas / abiertos.length;
    final mediaAnt = abiertosAnt == 0 ? 0.0 : ventasAnt / abiertosAnt;
    final hayAnt = ventasAnt > 0 || gastosAnt > 0;
    final ivaCobrado = ventas * _ivaVenta / (100 + _ivaVenta);
    final ivaPagado = _gastos.fold(0.0, (s, g) => s + ivaGasto(g));
    final debe = _gastos.where((g) => g['estado'] == 'pendiente').fold(0.0, (s, g) => s + (g['importe'] as num).toDouble());

    // --- Mejor y peor día ---
    MapEntry<String, double>? mejorDia, peorDia;
    for (final e in abiertos) {
      if (mejorDia == null || e.value > mejorDia.value) mejorDia = e;
      if (peorDia == null || e.value < peorDia.value) peorDia = e;
    }
    String nombreDia(String f) {
      final d = DateTime.parse(f);
      return '${_cap(_diasSemana[d.weekday - 1])} ${fechaCorta(f)}';
    }

    // --- Evolución: por meses si el periodo es largo, por días si no ---
    final (d, h) = _rango;
    final porMes = h.difference(d).inDays > 62;
    final evolucion = <String, ({double ventas, double gastos})>{};
    if (porMes) {
      for (var m = DateTime(d.year, d.month); !m.isAfter(h); m = DateTime(m.year, m.month + 1)) {
        evolucion['${m.year}-${m.month.toString().padLeft(2, '0')}'] = (ventas: 0, gastos: 0);
      }
    } else {
      for (var x = d; !x.isAfter(h); x = DateTime(x.year, x.month, x.day + 1)) {
        evolucion[iso(x)] = (ventas: 0, gastos: 0);
      }
    }
    String clave(String f) => porMes ? f.substring(0, 7) : f;
    _ventas.forEach((f, v) {
      final k = clave(f), e = evolucion[k];
      if (e != null) evolucion[k] = (ventas: e.ventas + v, gastos: e.gastos);
    });
    for (final g in _gastos) {
      final k = clave(g['fecha'] as String), e = evolucion[k];
      if (e != null) evolucion[k] = (ventas: e.ventas, gastos: e.gastos + (g['importe'] as num).toDouble());
    }
    // Mejor y peor mes (el mes en curso no cuenta como el más flojo: aún no ha terminado)
    final mesActual = '${_hoy.year}-${_hoy.month.toString().padLeft(2, '0')}';
    MapEntry<String, double>? mejorMes, peorMes;
    if (porMes) {
      for (final e in evolucion.entries) {
        if (e.value.ventas <= 0) continue;
        if (mejorMes == null || e.value.ventas > mejorMes.value) mejorMes = MapEntry(e.key, e.value.ventas);
        if (e.key != mesActual && (peorMes == null || e.value.ventas < peorMes.value)) peorMes = MapEntry(e.key, e.value.ventas);
      }
    }
    String nombreMes(String k) => '${_cap(meses[int.parse(k.substring(5)) - 1])} ${k.substring(0, 4)}';
    final destacadoBueno = porMes ? mejorMes?.key : mejorDia?.key;
    final destacadoMalo = porMes ? peorMes?.key : (abiertos.length > 1 ? peorDia?.key : null);

    // --- Por día de la semana (media de los días abiertos) ---
    final semSuma = List.filled(7, 0.0), semN = List.filled(7, 0);
    for (final e in abiertos) {
      final w = DateTime.parse(e.key).weekday - 1;
      semSuma[w] += e.value;
      semN[w]++;
    }
    final semMedia = [for (var i = 0; i < 7; i++) semN[i] == 0 ? 0.0 : semSuma[i] / semN[i]];
    final mejorSem = semMedia.indexOf(semMedia.reduce((a, b) => a > b ? a : b));

    // --- Gastos por categoría y proveedor, deudas ---
    final porCat = <String, double>{};
    final porProv = <String, double>{};
    for (final g in _gastos) {
      porCat[g['categoria'] as String] = (porCat[g['categoria']] ?? 0) + (g['importe'] as num).toDouble();
      final n = ((g['proveedores'] as Map?)?['nombre'] as String?) ?? 'Sin proveedor';
      porProv[n] = (porProv[n] ?? 0) + (g['importe'] as num).toDouble();
    }
    final deudas = <String, double>{};
    for (final g in _pendientes) {
      final n = ((g['proveedores'] as Map?)?['nombre'] as String?) ?? 'Sin proveedor';
      deudas[n] = (deudas[n] ?? 0) + (g['importe'] as num).toDouble();
    }

    // --- Materia prima, punto de equilibrio y previsión ---
    double sumaCat(List<Map<String, dynamic>> g, String cat) =>
        g.where((x) => x['categoria'] == cat).fold(0.0, (s, x) => s + (x['importe'] as num).toDouble());
    final materia = sumaCat(_gastos, 'materia');
    final pctMateria = ventas > 0 ? materia / ventas * 100 : null;
    final histVentas = _suma(_histVentas.values);
    final mesesHist = {for (final g in _histGastos) (g['fecha'] as String).substring(0, 7)}.length.clamp(1, 3);
    final fijosMes = sumaCat(_histGastos, 'fijos') / mesesHist > 0
        ? sumaCat(_histGastos, 'fijos') / mesesHist
        : sumaCat(_gastos, 'fijos') / (porMes ? evolucion.length : 1);
    final pctHabitual = histVentas > 0
        ? (sumaCat(_histGastos, 'materia') + sumaCat(_histGastos, 'otros')) / histVentas
        : (ventas > 0 ? (materia + sumaCat(_gastos, 'otros')) / ventas : 0.3);
    final equilibrioMes = pctHabitual < 0.95 ? fijosMes / (1 - pctHabitual) : null;
    final equilibrioDia = equilibrioMes == null ? null : equilibrioMes / 30.4;
    final mediaNatural = () {
      final hasta = h.isAfter(_hoy) ? _hoy : h;
      final dias = hasta.difference(d).inDays + 1;
      return dias > 0 ? ventas / dias : 0.0;
    }();

    // Previsión (solo si el periodo está en curso)
    final enCurso = !_hoy.isBefore(d) && !_hoy.isAfter(h) && _vista != _Vista.fechas;
    double? ventasPrev, resultadoPrev;
    if (enCurso && ventas > 0) {
      final diasRest = h.difference(_hoy).inDays;
      final extra = mediaNatural * diasRest;
      ventasPrev = ventas + extra;
      final fijosFaltan = _vista == _Vista.mes ? (fijosMes - sumaCat(_gastos, 'fijos')).clamp(0.0, double.infinity) : fijosMes * diasRest / 30.4;
      resultadoPrev = ventasPrev - (gastos + extra * pctHabitual + fijosFaltan);
    }

    // --- IVA por trimestre (vista Año) ---
    final trimestres = <({String nombre, double cobrado, double pagado})>[];
    if (_vista == _Vista.ano) {
      for (var t = 0; t < 4; t++) {
        bool enT(String f) {
          final m = int.parse(f.substring(5, 7));
          return m > t * 3 && m <= t * 3 + 3;
        }
        final vT = _ventas.entries.where((e) => enT(e.key)).fold(0.0, (s, e) => s + e.value);
        final pT = _gastos.where((g) => enT(g['fecha'] as String)).fold(0.0, (s, g) => s + ivaGasto(g));
        trimestres.add((nombre: '${t + 1}T', cobrado: vT * _ivaVenta / (100 + _ivaVenta), pagado: pT));
      }
    }

    // --- Alertas ---
    final alertas = <({IconData icono, Color color, String texto})>[];
    if (abiertos.isNotEmpty) {
      final huecos = <String>[];
      final ultimo = h.isBefore(_hoy) ? h : _hoy.subtract(const Duration(days: 1));
      for (var x = DateTime.parse(abiertos.first.key); !x.isAfter(ultimo); x = DateTime(x.year, x.month, x.day + 1)) {
        if ((_ventas[iso(x)] ?? 0) <= 0) huecos.add(iso(x));
      }
      if (huecos.isNotEmpty) {
        final lista = huecos.take(8).map(fechaCorta).join(', ');
        alertas.add((
          icono: Icons.event_busy_outlined,
          color: C.naranja,
          texto: '${huecos.length} ${huecos.length == 1 ? 'día' : 'días'} sin caja apuntada: $lista${huecos.length > 8 ? '…' : ''}. '
              'Si ese día cerró, no pasa nada; si abrió, falta apuntar la caja.',
        ));
      }
    }
    final viejas = _pendientes.where((g) => DateTime.parse(g['fecha'] as String).isBefore(_hoy.subtract(const Duration(days: 30)))).toList();
    if (viejas.isNotEmpty) {
      alertas.add((
        icono: Icons.schedule_outlined,
        color: _rojo,
        texto: '${viejas.length} ${viejas.length == 1 ? 'factura' : 'facturas'} por pagar de hace más de 30 días '
            '(${euros(viejas.fold(0.0, (s, g) => s + (g['importe'] as num).toDouble()))}).',
      ));
    }
    if (_vista == _Vista.mes) {
      final histProv = <String, double>{};
      for (final g in _histGastos) {
        final n = (g['proveedores'] as Map?)?['nombre'] as String?;
        if (n != null) histProv[n] = (histProv[n] ?? 0) + (g['importe'] as num).toDouble();
      }
      porProv.forEach((n, v) {
        final media = (histProv[n] ?? 0) / mesesHist;
        if (n != 'Sin proveedor' && media > 0 && v > media * 1.3 && v - media > 100) {
          alertas.add((
            icono: Icons.trending_up,
            color: C.naranja,
            texto: '$n: ${euros(v)} este mes, un ${((v / media - 1) * 100).round()} % más que su media (${euros(media)}/mes).',
          ));
        }
      });
    }
    final repetidos = <String, int>{};
    for (final g in _gastos) {
      final prov = (g['proveedores'] as Map?)?['nombre'] as String?;
      final k = prov == null
          ? '${(g['fecha'] as String).substring(0, 7)}|${(g['concepto'] as String).trim().toLowerCase()}|${g['importe']}'
          : '${g['fecha']}|$prov|${g['importe']}';
      repetidos[k] = (repetidos[k] ?? 0) + 1;
    }
    repetidos.forEach((k, n) {
      if (n < 2) return;
      final p = k.split('|');
      final quien = p[0].length == 7 ? p[1].toUpperCase() : p[1];
      final cuando = p[0].length == 7 ? _cap(meses[int.parse(p[0].substring(5)) - 1]) : fechaCorta(p[0]);
      alertas.add((
        icono: Icons.content_copy_outlined,
        color: _rojo,
        texto: '¿Duplicado? $quien de ${euros(double.parse(p[2]))} aparece $n veces ($cuando).',
      ));
    });

    _paraExportar = (
      ventas: ventas, gastos: gastos, resultado: resultado, media: media, dias: abiertos.length,
      iva: ivaCobrado - ivaPagado, pctMateria: pctMateria, evolucion: evolucion, porMes: porMes,
      porCat: porCat, porProv: porProv, trimestres: trimestres,
    );

    final vs = 'vs $_nombreAnt';
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        _Semana(_ultimos, _hoy),
        const SizedBox(height: 24),
        _cabecera(),
        const SizedBox(height: 20),
        Wrap(spacing: 14, runSpacing: 14, children: [
          _Kpi('Ventas', euros(ventas), destacada: true,
              cambio: hayAnt ? _Cambio(ventas, ventasAnt) : null, detalle: hayAnt ? '$vs: ${euros(ventasAnt)}' : 'Sin datos de $_nombreAnt'),
          _Kpi('Gastos', euros(gastos),
              cambio: hayAnt ? _Cambio(gastos, gastosAnt, alReves: true) : null,
              detalle: hayAnt ? '$vs: ${euros(gastosAnt)}' : '${_gastos.length} facturas'),
          _Kpi('Resultado', euros(resultado),
              color: resultado >= 0 ? C.verde : _rojo,
              cambio: hayAnt ? _Cambio(resultado, resultadoAnt) : null,
              detalle: hayAnt ? '$vs: ${euros(resultadoAnt)}' : 'Ventas − gastos'),
          _Kpi('Media por día abierto', euros(media),
              cambio: hayAnt ? _Cambio(media, mediaAnt) : null, detalle: hayAnt ? '$vs: ${euros(mediaAnt)}' : null),
          _Kpi('Días abiertos', '${abiertos.length}', detalle: hayAnt ? '$_nombreAnt: $abiertosAnt' : null),
          _Kpi('IVA a apartar', euros(ivaCobrado - ivaPagado),
              detalle: 'Cobrado ${euros(ivaCobrado)} − pagado ${euros(ivaPagado)}'),
          if (pctMateria != null)
            _Kpi('Materia prima', '${pctMateria.round()} %',
                color: pctMateria <= 35 ? C.verde : pctMateria <= 45 ? C.naranja : _rojo,
                detalle: '${euros(materia)} de compras · lo sano: 25–35 %'),
        ]),
        const SizedBox(height: 6),
        const Text('Ventas: caja diaria de cada día y, si ese día no hay caja, lo cobrado en el TPV. El IVA es aproximado.',
            style: TextStyle(fontSize: 12, color: C.gris)),
        const SizedBox(height: 24),
        LayoutBuilder(builder: (context, c) {
          final eq = _Bloque('Lo mínimo que hay que vender', [
            if (equilibrioDia == null)
              const Text('Faltan datos de gastos para calcularlo.', style: TextStyle(color: C.gris))
            else ...[
              Text('${euros(equilibrioDia)} al día', style: titulo(26)),
              Text('(${euros(equilibrioMes!)} al mes) para cubrir los fijos (${euros(fijosMes)}/mes) y las compras '
                  '(${(pctHabitual * 100).round()} % de lo vendido).', style: const TextStyle(color: C.gris, fontSize: 13)),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: equilibrioDia <= 0 ? 0 : (mediaNatural / equilibrioDia).clamp(0.0, 1.0),
                  minHeight: 14,
                  backgroundColor: C.crema,
                  color: mediaNatural >= equilibrioDia ? C.verde : C.naranja,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                mediaNatural >= equilibrioDia
                    ? 'Vas en ${euros(mediaNatural)} al día: cubres gastos y sobran ${euros(mediaNatural - equilibrioDia)} al día ✅'
                    : 'Vas en ${euros(mediaNatural)} al día: faltan ${euros(equilibrioDia - mediaNatural)} al día para cubrir gastos ⚠️',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ]);
          final prev = _Bloque(_vista == _Vista.mes ? 'Previsión de cierre de mes' : 'Previsión de cierre de año', [
            if (ventasPrev == null)
              const Text('Solo para el mes o el año en curso.', style: TextStyle(color: C.gris))
            else ...[
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Ventas previstas', style: TextStyle(color: C.gris, fontSize: 13)),
                    Text(euros(ventasPrev), style: titulo(24)),
                  ]),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Resultado previsto', style: TextStyle(color: C.gris, fontSize: 13)),
                    Text(euros(resultadoPrev!), style: titulo(24, color: resultadoPrev >= 0 ? C.verde : _rojo)),
                  ]),
                ),
              ]),
              const SizedBox(height: 8),
              Text('A este ritmo (${euros(mediaNatural)} al día) y con los gastos habituales.',
                  style: const TextStyle(color: C.gris, fontSize: 13)),
            ],
          ]);
          if (c.maxWidth < 900) return Column(children: [eq, prev]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: eq),
            const SizedBox(width: 20),
            Expanded(child: prev),
          ]);
        }),
        _Bloque(alertas.isEmpty ? 'Avisos' : 'Avisos (${alertas.length})', [
          if (alertas.isEmpty) const Text('Todo en orden ✅', style: TextStyle(color: C.gris)),
          for (final a in alertas)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(a.icono, color: a.color, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(a.texto)),
              ]),
            ),
        ]),
        _Bloque(porMes ? 'Ventas y gastos por mes' : 'Ventas y gastos por día', [
          _Evolucion(evolucion, porMes: porMes, bueno: destacadoBueno, malo: destacadoMalo,
              onMes: porMes ? (k) => _abrirMes(int.parse(k.substring(0, 4)), int.parse(k.substring(5))) : null),
          const SizedBox(height: 14),
          Wrap(spacing: 12, runSpacing: 12, children: [
            if (porMes && mejorMes != null) _Destacado('Mejor mes', '${nombreMes(mejorMes.key)} · ${euros(mejorMes.value)}', C.verde),
            if (porMes && peorMes != null) _Destacado('Mes más flojo', '${nombreMes(peorMes.key)} · ${euros(peorMes.value)}', _rojo),
            if (mejorDia != null) _Destacado('Mejor día', '${nombreDia(mejorDia.key)} · ${euros(mejorDia.value)}', C.verde),
            if (peorDia != null && abiertos.length > 1)
              _Destacado('Día más flojo', '${nombreDia(peorDia.key)} · ${euros(peorDia.value)}', _rojo),
          ]),
          if (porMes) const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('Toca un mes para verlo día a día.', style: TextStyle(fontSize: 12, color: C.gris)),
          ),
        ]),
        if (trimestres.isNotEmpty)
          _Bloque('IVA por trimestre (para el modelo 303)', [
            Row(children: const [
              Expanded(child: Text('')),
              Expanded(child: Text('Cobrado', textAlign: TextAlign.right, style: TextStyle(color: C.gris, fontSize: 13))),
              Expanded(child: Text('Pagado', textAlign: TextAlign.right, style: TextStyle(color: C.gris, fontSize: 13))),
              Expanded(child: Text('A apartar', textAlign: TextAlign.right, style: TextStyle(color: C.gris, fontSize: 13))),
            ]),
            for (final t in trimestres)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(child: Text(t.nombre, style: titulo(16))),
                  Expanded(child: Text(euros(t.cobrado), textAlign: TextAlign.right)),
                  Expanded(child: Text(euros(t.pagado), textAlign: TextAlign.right)),
                  Expanded(
                    child: Text(euros(t.cobrado - t.pagado),
                        textAlign: TextAlign.right, style: titulo(16, color: t.cobrado - t.pagado > 0 ? C.naranja : C.verde)),
                  ),
                ]),
              ),
            const SizedBox(height: 4),
            const Text('Aproximado: el dato oficial lo calcula la gestoría con las facturas.', style: TextStyle(fontSize: 12, color: C.gris)),
          ]),
        if (_desglose.diasDesglose > 0)
          _Bloque('Efectivo y tarjeta', [
            for (final e in {'Efectivo': _desglose.efectivo, 'Tarjeta': _desglose.tarjeta, 'Bizum': _desglose.bizum}.entries)
              if (e.value > 0)
                _Barra(
                  '${e.key} · ${(e.value / (_desglose.efectivo + _desglose.tarjeta + _desglose.bizum) * 100).round()} %',
                  e.value,
                  _desglose.efectivo + _desglose.tarjeta + _desglose.bizum,
                  e.key == 'Efectivo' ? C.verde : e.key == 'Tarjeta' ? const Color(0xFF2F6DB5) : C.naranja,
                ),
            Text('Con desglose en ${_desglose.diasDesglose} de ${abiertos.length} días con ventas. '
                'Apunta efectivo y tarjeta en la caja diaria para que salga completo.',
                style: const TextStyle(fontSize: 12, color: C.gris)),
          ]),
        if (abiertos.isNotEmpty)
          _Bloque('¿Qué día de la semana vendes más? (media por día)', [
            for (var i = 0; i < 7; i++)
              _Barra(_cap(_diasSemana[i]), semMedia[i], semMedia[mejorSem], i == mejorSem ? C.verde : C.verde.withValues(alpha: 0.45)),
          ]),
        LayoutBuilder(builder: (context, c) {
          final bloques = [
            _Bloque('Gastos por categoría', [
              for (final e in categorias.entries)
                _Barra(e.value, porCat[e.key] ?? 0, gastos, coloresCategoria[e.key]!),
              if (debe > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    const Expanded(child: Text('De esto, se debe')),
                    Text(euros(debe), style: titulo(16, color: C.naranja)),
                  ]),
                ),
            ]),
            _Bloque('Gasto por proveedor', [
              for (final e in porProv.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                _Barra(e.key, e.value, porProv.values.fold(0.0, (a, b) => a > b ? a : b), C.verde),
            ]),
            _Bloque('Por pagar (todos los meses)', [
              if (deudas.isEmpty) const Text('Nada pendiente.', style: TextStyle(color: C.gris)),
              for (final e in deudas.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text(e.key)),
                    Text(euros(e.value), style: titulo(16, color: C.naranja)),
                  ]),
                ),
            ]),
          ];
          if (c.maxWidth < 900) return Column(children: bloques);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(children: [bloques[0], bloques[2]])),
            const SizedBox(width: 20),
            Expanded(child: bloques[1]),
          ]);
        }),
      ],
    );
  }
}

const _rojo = Color(0xFFB3261E);

/// Porcentaje de cambio frente al periodo anterior (verde si es bueno).
class _Cambio {
  const _Cambio(this.actual, this.anterior, {this.alReves = false});
  final double actual, anterior;
  final bool alReves; // en gastos, subir es malo
  int? get porcentaje => anterior.abs() < 0.005 ? null : ((actual - anterior) / anterior.abs() * 100).round();
  bool get bueno => alReves ? actual <= anterior : actual >= anterior;
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.etiqueta, this.valor, {this.detalle, this.cambio, this.destacada = false, this.color});
  final String etiqueta, valor;
  final String? detalle;
  final _Cambio? cambio;
  final bool destacada;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = destacada ? Colors.white : C.tinta;
    final p = cambio?.porcentaje;
    return Container(
      width: 230,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: destacada ? C.verde : C.blanco,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: destacada ? C.verde : C.borde),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(etiqueta, style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 13))),
          if (p != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: destacada ? Colors.white : (cambio!.bueno ? C.verde : _rojo).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${p > 0 ? '+' : ''}$p %',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cambio!.bueno ? C.verde : _rojo)),
            ),
        ]),
        const SizedBox(height: 6),
        Text(valor, style: titulo(26, color: color ?? fg)),
        if (detalle != null) Text(detalle!, style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12)),
      ]),
    );
  }
}

class _Destacado extends StatelessWidget {
  const _Destacado(this.etiqueta, this.texto, this.color);
  final String etiqueta, texto;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: C.crema, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(etiqueta, style: const TextStyle(fontSize: 12, color: C.gris)),
            Text(texto, style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ]),
      );
}

/// Hoy y los últimos 7 días comparados con los 7 anteriores (siempre a mano).
class _Semana extends StatelessWidget {
  const _Semana(this.ventas, this.hoy);
  final Map<String, double> ventas;
  final DateTime hoy;

  @override
  Widget build(BuildContext context) {
    final dias = [for (var i = 6; i >= 0; i--) DateTime(hoy.year, hoy.month, hoy.day - i)];
    double v(DateTime d) => ventas[iso(d)] ?? 0;
    final sem = dias.fold(0.0, (s, d) => s + v(d));
    final ant = dias.fold(0.0, (s, d) => s + v(DateTime(d.year, d.month, d.day - 7)));
    final maximo = dias.fold(1.0, (m, d) => v(d) > m ? v(d) : m);
    final cambio = _Cambio(sem, ant);
    final p = cambio.porcentaje;
    final hoyV = v(hoy);
    return LayoutBuilder(builder: (context, c) {
      final hoyCard = Container(
        width: c.maxWidth < 700 ? double.infinity : 260,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: C.verde, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Hoy · ${_cap(_diasSemana[hoy.weekday - 1])} ${hoy.day} de ${meses[hoy.month - 1]}',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 6),
          Text(hoyV > 0 ? euros(hoyV) : 'Sin caja todavía', style: titulo(hoyV > 0 ? 28 : 20, color: Colors.white)),
          const SizedBox(height: 4),
          const Text('Caja diaria o lo cobrado en el TPV', style: TextStyle(color: Colors.white70, fontSize: 12)),
        ]),
      );
      final semCard = Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Últimos 7 días', style: titulo(16)),
              if (p != null) ...[
                const SizedBox(width: 8),
                Text('${p > 0 ? '+' : ''}$p %',
                    style: TextStyle(fontWeight: FontWeight.w700, color: cambio.bueno ? C.verde : _rojo)),
              ],
            ]),
            const SizedBox(height: 4),
            Text(euros(sem), style: titulo(26)),
            Text('Semana anterior: ${euros(ant)}', style: const TextStyle(fontSize: 12, color: C.gris)),
          ]),
          const SizedBox(width: 24),
          Expanded(
            child: SizedBox(
              height: 80,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final d in dias)
                  Expanded(
                    child: Tooltip(
                      message: '${_cap(_diasSemana[d.weekday - 1])} ${d.day}/${d.month}: ${euros(v(d))}',
                      child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                        Expanded(
                          child: FractionallySizedBox(
                            heightFactor: (v(d) / maximo).clamp(0.04, 1.0),
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: d == hoy ? C.naranja : C.verde.withValues(alpha: v(d) > 0 ? 0.85 : 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(_letrasSemana[d.weekday - 1], style: const TextStyle(fontSize: 11, color: C.gris)),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ]),
      );
      if (c.maxWidth < 700) return Column(children: [hoyCard, const SizedBox(height: 14), semCard]);
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        hoyCard,
        const SizedBox(width: 14),
        Expanded(child: semCard),
      ]);
    });
  }
}

/// Columnas de ventas (verde) y gastos (naranja) por mes o por día.
/// El mejor periodo se marca con borde verde y el más flojo con borde rojo.
class _Evolucion extends StatelessWidget {
  const _Evolucion(this.datos, {required this.porMes, this.bueno, this.malo, this.onMes});
  final Map<String, ({double ventas, double gastos})> datos;
  final bool porMes;
  final String? bueno, malo;
  final void Function(String clave)? onMes;

  @override
  Widget build(BuildContext context) {
    // La escala la marcan las ventas: un gasto grande (alquiler, una máquina) no aplasta el gráfico.
    // Si un gasto se sale de la escala, su columna llega arriba con una flecha.
    final maxVentas = datos.values.fold(0.0, (m, e) => e.ventas > m ? e.ventas : m);
    final maxGastos = datos.values.fold(0.0, (m, e) => e.gastos > m ? e.gastos : m);
    final maximo = maxVentas > 0 ? maxVentas * 1.1 : maxGastos;
    String etiqueta(String k) {
      final p = k.split('-');
      return porMes ? meses[int.parse(p[1]) - 1].substring(0, 3) : int.parse(p[2]).toString();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _leyenda(C.verde, 'Ventas'),
        const SizedBox(width: 16),
        _leyenda(C.naranja, 'Gastos'),
      ]),
      const SizedBox(height: 12),
      SizedBox(
        height: 200,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final e in datos.entries)
            Expanded(
              child: InkWell(
                onTap: onMes == null ? null : () => onMes!(e.key),
                borderRadius: BorderRadius.circular(6),
                child: Tooltip(
                  message: '${porMes ? etiqueta(e.key) : fechaCorta(e.key)}\nVentas ${euros(e.value.ventas)}\n'
                      'Gastos ${euros(e.value.gastos)}\nResultado ${euros(e.value.ventas - e.value.gastos)}',
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: porMes ? 6 : 1),
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Expanded(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          _columna(e.value.ventas, maximo, C.verde,
                              marco: e.key == bueno ? C.verde : e.key == malo ? _rojo : null),
                          const SizedBox(width: 2),
                          _columna(e.value.gastos, maximo, C.naranja),
                        ]),
                      ),
                      const SizedBox(height: 6),
                      if (porMes || datos.length <= 31)
                        Text(etiqueta(e.key),
                            style: TextStyle(
                                fontSize: 11,
                                color: e.key == bueno ? C.verde : e.key == malo ? _rojo : C.gris,
                                fontWeight: e.key == bueno || e.key == malo ? FontWeight.w700 : FontWeight.w400),
                            maxLines: 1),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }

  Widget _columna(double v, double max, Color color, {Color? marco}) => Expanded(
        child: FractionallySizedBox(
          heightFactor: max <= 0 ? 0 : (v / max).clamp(0.0, 1.0),
          alignment: Alignment.bottomCenter,
          child: Container(
            alignment: Alignment.topCenter,
            decoration: BoxDecoration(
              color: marco == _rojo ? _rojo.withValues(alpha: 0.75) : color,
              borderRadius: BorderRadius.circular(3),
              border: marco == null ? null : Border.all(color: marco, width: 2),
            ),
            child: max > 0 && v > max
                ? const FittedBox(child: Icon(Icons.arrow_upward, color: Colors.white, size: 14))
                : null,
          ),
        ),
      );

  Widget _leyenda(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(t, style: const TextStyle(fontSize: 13)),
      ]);
}

class _Bloque extends StatelessWidget {
  const _Bloque(this.nombre, this.hijos);
  final String nombre;
  final List<Widget> hijos;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(nombre, style: titulo(18)),
          const SizedBox(height: 12),
          if (hijos.isEmpty) const Text('Sin datos', style: TextStyle(color: C.gris)),
          ...hijos,
        ]),
      );
}

class _Barra extends StatelessWidget {
  const _Barra(this.etiqueta, this.valor, this.maximo, this.color);
  final String etiqueta;
  final double valor;
  final double maximo;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final f = maximo <= 0 ? 0.0 : (valor / maximo).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(width: 140, child: Text(etiqueta, maxLines: 1, overflow: TextOverflow.ellipsis)),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: (c.maxWidth * f).clamp(4.0, c.maxWidth),
                height: 20,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(width: 100, child: Text(euros(valor), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
      ]),
    );
  }
}
