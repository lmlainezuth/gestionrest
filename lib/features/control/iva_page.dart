import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../gestion/comun.dart' show Cifra, ivaGasto, leerTodo, iso;
import '../ticketbai/modelos.dart' show euros;

/// IVA del trimestre: repercutido (facturas emitidas) − soportado (facturas de gastos).
/// En Gipuzkoa se declara con el modelo 300. Es una ayuda para la gestoría, no la declaración.
class IvaPage extends StatefulWidget {
  const IvaPage({super.key});

  @override
  State<IvaPage> createState() => _IvaPageState();
}

typedef _Tramo = ({double base, double cuota, int n});

class _IvaPageState extends State<IvaPage> {
  late int _anio = DateTime.now().year;
  late int _tri = (DateTime.now().month - 1) ~/ 3 + 1;
  Map<double, _Tramo> _rep = {}, _sop = {};
  int _facturas = 0, _gastos = 0, _excluidas = 0, _pendientesEnvio = 0;
  bool _cargando = true;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  DateTime get _desde => DateTime(_anio, (_tri - 1) * 3 + 1);
  DateTime get _hasta => DateTime(_anio, _tri * 3 + 1); // exclusivo

  void _mover(int d) {
    setState(() {
      _tri += d;
      if (_tri == 0) {
        _tri = 4;
        _anio--;
      } else if (_tri == 5) {
        _tri = 1;
        _anio++;
      }
      _cargando = true;
    });
    _cargar();
  }

  static Map<double, _Tramo> _sumar(Map<double, _Tramo> m, double tipo, double base, double cuota) {
    final t = m[tipo] ?? (base: 0.0, cuota: 0.0, n: 0);
    m[tipo] = (base: t.base + base, cuota: t.cuota + cuota, n: t.n + 1);
    return m;
  }

  Future<void> _cargar() async {
    try {
      await online(() async {
        final r = await Future.wait<dynamic>([
          leerTodo((a, b) => supabase
              .from('facturas')
              .select('id, tipo, desglose_iva, base_imponible, cuota_iva, tipo_iva, estado_envio, rectifica_id, sustituye_simplificada')
              .gte('fecha', _desde.toUtc().toIso8601String())
              .lt('fecha', _hasta.toUtc().toIso8601String())
              .range(a, b)),
          supabase.from('tbai_anulaciones').select('factura_id, estado_envio'),
          leerTodo((a, b) => supabase
              .from('gastos')
              .select('importe, iva_tipo, iva_importe')
              .gte('fecha', iso(_desde))
              .lt('fecha', iso(_hasta))
              .range(a, b)),
        ]);
        final facturas = r[0] as List<Map<String, dynamic>>;
        final anuladas = {
          for (final a in r[1] as List)
            if (a['estado_envio'] == 'enviada' || a['estado_envio'] == 'simulada') a['factura_id'],
        };
        // Un ticket sustituido por factura con NIF no se cuenta dos veces
        final sustituidas = {for (final f in facturas) if (f['sustituye_simplificada'] == true) f['rectifica_id']};
        _rep = {};
        _facturas = _excluidas = _pendientesEnvio = 0;
        for (final f in facturas) {
          if (anuladas.contains(f['id']) || sustituidas.contains(f['id']) || f['estado_envio'] == 'simulada') {
            _excluidas++;
            continue;
          }
          if (f['estado_envio'] != 'enviada') _pendientesEnvio++;
          _facturas++;
          final desglose = f['desglose_iva'] as List?;
          if (desglose != null && desglose.isNotEmpty) {
            for (final t in desglose) {
              _sumar(_rep, (t['tipo'] as num).toDouble(), (t['base'] as num).toDouble(), (t['cuota'] as num).toDouble());
            }
          } else {
            _sumar(_rep, (f['tipo_iva'] as num).toDouble(), (f['base_imponible'] as num).toDouble(),
                (f['cuota_iva'] as num).toDouble());
          }
        }
        _sop = {};
        final gastos = r[2] as List<Map<String, dynamic>>;
        _gastos = gastos.length;
        for (final g in gastos) {
          final cuota = ivaGasto(g);
          final tipo = g['iva_tipo'] == 'mixto' ? -1.0 : double.parse(g['iva_tipo'] as String);
          _sumar(_sop, tipo, (g['importe'] as num).toDouble() - cuota, cuota);
        }
      });
      if (mounted) {
        setState(() {
          _cargando = false;
          _errorCarga = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorCarga = textoError(e);
          _cargando = false;
        });
      }
    }
  }

  double _total(Map<double, _Tramo> m, {bool cuota = true}) => m.values.fold(0.0, (s, t) => s + (cuota ? t.cuota : t.base));
  String _tipo(double t) => t < 0 ? 'Mixto' : '${t.toStringAsFixed(0)} %';

  Future<void> _pdf() async {
    pw.ThemeData tema;
    try {
      tema = pw.ThemeData.withFont(base: await PdfGoogleFonts.robotoRegular(), bold: await PdfGoogleFonts.robotoBold());
    } catch (_) {
      tema = pw.ThemeData.base();
    }
    final rep = _total(_rep), sop = _total(_sop);
    pw.Widget tabla(Map<double, _Tramo> m) => pw.TableHelper.fromTextArray(
          headers: ['Tipo', 'Base', 'Cuota', 'Nº'],
          data: [
            for (final e in (m.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
              [_tipo(e.key), euros(e.value.base), euros(e.value.cuota), '${e.value.n}'],
            ['Total', euros(_total(m, cuota: false)), euros(_total(m)), ''],
          ],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
        );
    final doc = pw.Document()
      ..addPage(pw.MultiPage(
        theme: tema,
        pageFormat: PdfPageFormat.a4,
        build: (_) => [
          pw.Text('IVA ${_tri}T $_anio', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.Text('${Perfil.cache?.empresaNombre ?? ''} · para la autoliquidación (Gipuzkoa: modelo 300)'),
          pw.SizedBox(height: 14),
          pw.Text('IVA repercutido (ventas, $_facturas facturas)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          tabla(_rep),
          pw.SizedBox(height: 14),
          pw.Text('IVA soportado (gastos, $_gastos facturas)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          tabla(_sop),
          pw.SizedBox(height: 14),
          pw.Text('Resultado: ${euros(rep - sop)} ${rep - sop >= 0 ? 'a ingresar' : 'a compensar / devolver'}',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          pw.Text('Calculado por GestiónRest. Revisar con la gestoría antes de presentar: no incluye IVA no deducible, '
              'bienes de inversión ni prorrata.', style: const pw.TextStyle(fontSize: 9)),
        ],
      ));
    await Printing.layoutPdf(name: 'IVA ${_tri}T $_anio', onLayout: (_) async => doc.save());
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    final rep = _total(_rep), sop = _total(_sop), res = rep - sop;
    final ancho = MediaQuery.sizeOf(context).width;
    Widget bloque(String titulo_, Map<double, _Tramo> m) => Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo_, style: titulo(17)),
            const SizedBox(height: 8),
            if (m.isEmpty) const Text('Nada en este trimestre', style: TextStyle(color: C.gris)),
            for (final e in (m.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(width: 70, child: Text(_tipo(e.key), style: const TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(child: Text('base ${euros(e.value.base)}', style: const TextStyle(color: C.gris))),
                  Text(euros(e.value.cuota), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ),
          ]),
        );
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(onPressed: () => _mover(-1), icon: const Icon(Icons.chevron_left)),
          Text('${_tri}º trimestre $_anio', style: titulo(20)),
          IconButton(onPressed: _desde.add(const Duration(days: 95)).isAfter(DateTime.now()) ? null : () => _mover(1),
              icon: const Icon(Icons.chevron_right)),
          FilledButton.icon(onPressed: _cargando ? null : _pdf, icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('PDF para la gestoría')),
        ]),
        const SizedBox(height: 12),
        if (_cargando)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else ...[
          Wrap(spacing: 12, runSpacing: 12, children: [
            Cifra(res >= 0 ? 'A ingresar' : 'A compensar', euros(res.abs()), detalle: 'repercutido − soportado', destacada: true),
            Cifra('IVA cobrado (ventas)', euros(rep), detalle: '$_facturas facturas'),
            Cifra('IVA pagado (gastos)', euros(sop), detalle: '$_gastos gastos'),
          ]),
          const SizedBox(height: 16),
          bloque('Repercutido por tipo', _rep),
          bloque('Soportado por tipo', _sop),
          if (_pendientesEnvio > 0)
            Text('Atención: $_pendientesEnvio facturas aún no constan como enviadas a TicketBAI.',
                style: const TextStyle(color: C.naranja, fontWeight: FontWeight.w600)),
          if (_excluidas > 0)
            Text('$_excluidas facturas no cuentan (anuladas, de simulación o sustituidas por factura con NIF).',
                style: const TextStyle(color: C.gris, fontSize: 13)),
          const SizedBox(height: 6),
          const Text('En Gipuzkoa el IVA se declara con el modelo 300. Esto es una ayuda: la gestoría debe revisarlo '
              '(gastos no deducibles, bienes de inversión, régimen simplificado si lo tuvierais…). '
              'Los gastos cuentan por su fecha de factura.', style: TextStyle(color: C.gris, fontSize: 12)),
        ],
      ],
    );
  }
}
