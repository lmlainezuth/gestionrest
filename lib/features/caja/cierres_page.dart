import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../gestion/comun.dart' show SelectorMes, rangoMes;
import '../ticketbai/modelos.dart' show euros;
import 'caja_page.dart' show imprimirCierreCaja;

const _rojo = Color(0xFFB3261E);

/// Cierres de turno con su cuadre (solo encargado): quién cerró, cuánto faltó o sobró.
class CierresPage extends StatefulWidget {
  const CierresPage({super.key});

  @override
  State<CierresPage> createState() => _CierresPageState();
}

class _CierresPageState extends State<CierresPage> {
  DateTime _mes = DateTime.now();
  List<Map<String, dynamic>> _turnos = [];
  Map<String, String> _nombres = {};
  bool _cargando = true;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await online(() async {
        final (desde, hasta) = rangoMes(_mes);
        final fin = DateTime.parse(hasta).add(const Duration(days: 1));
        final r = await Future.wait<dynamic>([
          supabase
              .from('turnos_caja')
              .select()
              .eq('estado', 'cerrado')
              .gte('cerrado_en', DateTime.parse(desde).toUtc().toIso8601String())
              .lt('cerrado_en', fin.toUtc().toIso8601String())
              .order('cerrado_en', ascending: false),
          supabase.rpc('equipo_empresa'),
        ]);
        _turnos = List<Map<String, dynamic>>.from(r[0] as List);
        _nombres = {for (final p in r[1] as List) p['id'] as String: p['nombre'] as String};
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

  double _n(Object? v) => (v as num?)?.toDouble() ?? 0;
  String _quien(Map<String, dynamic> t) => _nombres[t['cerrado_por'] ?? t['usuario_id']] ?? '¿?';

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    // Suma de diferencias por persona (lo que más importa ver de un vistazo)
    final porPersona = <String, (int, double)>{};
    for (final t in _turnos) {
      final p = porPersona[_quien(t)] ?? (0, 0.0);
      porPersona[_quien(t)] = (p.$1 + 1, p.$2 + _n(t['diferencia']));
    }
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        SelectorMes(
          mes: _mes,
          onCambio: (m) {
            setState(() {
              _mes = m;
              _cargando = true;
            });
            _cargar();
          },
        ),
        const SizedBox(height: 12),
        if (_cargando)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (_turnos.isEmpty)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Sin cierres este mes', style: TextStyle(color: C.gris))))
        else ...[
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final e in porPersona.entries)
              Chip(
                avatar: Icon(Icons.person, color: e.value.$2.abs() < 0.005 ? C.verde : (e.value.$2 < 0 ? _rojo : C.naranja)),
                label: Text('${e.key}: ${e.value.$1} cierres · '
                    '${e.value.$2.abs() < 0.005 ? 'cuadra' : '${e.value.$2 > 0 ? '+' : '−'}${euros(e.value.$2.abs())}'}'),
              ),
          ]),
          const SizedBox(height: 14),
          for (final t in _turnos) _fila(t),
        ],
      ],
    );
  }

  Widget _fila(Map<String, dynamic> t) {
    final dif = _n(t['diferencia']);
    final cuadra = dif.abs() < 0.005;
    final f = DateTime.parse(t['cerrado_en'] as String).toLocal();
    final cuando = '${f.day.toString().padLeft(2, '0')}/${f.month.toString().padLeft(2, '0')} '
        '${f.hour.toString().padLeft(2, '0')}:${f.minute.toString().padLeft(2, '0')}';
    final tarDif = t['tarjeta_diferencia'] == null ? null : _n(t['tarjeta_diferencia']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TarjetaFila(
        onTap: () => _detalle(t),
        child: Row(children: [
          IconoFila(cuadra ? Icons.check_circle_outline : Icons.error_outline, cuadra ? C.verde : (dif < 0 ? _rojo : C.naranja)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$cuando · ${_quien(t)}', style: titulo(16)),
              Text(
                [
                  'esperado ${euros(_n(t['efectivo_calculado']))} · contado ${euros(_n(t['efectivo_real']))}',
                  if (tarDif != null) 'datáfono ${tarDif.abs() < 0.005 ? 'cuadra' : '${tarDif > 0 ? '+' : '−'}${euros(tarDif.abs())}'}',
                  if ((t['nota'] as String?)?.isNotEmpty ?? false) '“${t['nota']}”',
                ].join(' · '),
                style: const TextStyle(color: C.gris, fontSize: 13),
              ),
            ]),
          ),
          Text(cuadra ? 'Cuadra' : '${dif > 0 ? '+' : '−'}${euros(dif.abs())}',
              style: titulo(18, color: cuadra ? C.verde : (dif < 0 ? _rojo : C.naranja))),
          const SizedBox(width: 6),
        ]),
      ),
    );
  }

  /// Cierre completo en papel (ventas, esperado, contado y diferencia), como el que ve el encargado.
  Future<void> _imprimir(Map<String, dynamic> t) async {
    try {
      final r = await Future.wait<dynamic>([
        supabase.from('pagos').select('metodo, importe, pedido_id').eq('turno_id', t['id'] as Object),
        supabase.from('movimientos_caja').select('tipo, importe').eq('turno_id', t['id'] as Object),
        supabase.from('cajas').select('nombre').eq('id', t['caja_id'] as Object).maybeSingle(),
      ]);
      final ventas = <String, double>{};
      for (final p in r[0] as List) {
        ventas[p['metodo'] as String] = (ventas[p['metodo']] ?? 0) + (p['importe'] as num).toDouble();
      }
      double mov(String tipo) =>
          (r[1] as List).where((m) => m['tipo'] == tipo).fold(0.0, (s, m) => s + (m['importe'] as num).toDouble());
      await imprimirCierreCaja(
        r: {
          'esperado': _n(t['efectivo_calculado']),
          'contado': _n(t['efectivo_real']),
          'tarjeta_esperado': t['tarjeta_calculado'],
          'tarjeta_contado': t['tarjeta_real'],
        },
        datos: {
          'conteo': t['conteo'],
          'efectivo': _n(t['efectivo_real']),
          'tarjeta': t['tarjeta_real'],
          'fondo': t['fondo_siguiente'],
          'nota': t['nota'],
        },
        turno: t,
        cajaNombre: ((r[2] as Map?)?['nombre'] as String?) ?? 'Caja',
        ventas: ventas,
        tickets: (r[0] as List).map((p) => p['pedido_id']).toSet().length,
        ingresos: mov('ingreso'),
        gastos: mov('gasto'),
        cierra: _quien(t),
        cerradoEn: DateTime.parse(t['cerrado_en'] as String).toLocal(),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo imprimir: ${textoError(e)}')));
    }
  }

  void _detalle(Map<String, dynamic> t) {
    final conteo = (t['conteo'] as Map?)?.cast<String, dynamic>() ?? {};
    final piezas = conteo.entries.toList()..sort((a, b) => double.parse(b.key).compareTo(double.parse(a.key)));
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cierre de ${_quien(t)}'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Fondo inicial: ${euros(_n(t['efectivo_inicial']))}'),
            Text('Efectivo esperado: ${euros(_n(t['efectivo_calculado']))}'),
            Text('Efectivo contado: ${euros(_n(t['efectivo_real']))}'),
            if (t['tarjeta_real'] != null)
              Text('Datáfono: esperado ${euros(_n(t['tarjeta_calculado']))} · contado ${euros(_n(t['tarjeta_real']))}'),
            const SizedBox(height: 6),
            Text(_n(t['diferencia']).abs() < 0.005 ? 'Cuadra' : '${_n(t['diferencia']) > 0 ? 'Sobran' : 'Faltan'} ${euros(_n(t['diferencia']).abs())}',
                style: titulo(18, color: _n(t['diferencia']).abs() < 0.005 ? C.verde : (_n(t['diferencia']) < 0 ? _rojo : C.naranja))),
            const SizedBox(height: 10),
            if (piezas.isEmpty)
              const Text('Contó solo el total.', style: TextStyle(color: C.gris))
            else
              for (final e in piezas)
                Text('${double.parse(e.key) >= 1 ? '${double.parse(e.key).toStringAsFixed(0)} €' : '${(double.parse(e.key) * 100).round()} cts'}'
                    ' × ${e.value} = ${euros(double.parse(e.key) * (e.value as num))}'),
          ]),
        ),
        actions: [
          TextButton.icon(onPressed: () => _imprimir(t), icon: const Icon(Icons.print), label: const Text('Imprimir')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }
}
