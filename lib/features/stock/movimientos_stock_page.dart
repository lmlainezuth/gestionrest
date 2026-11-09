import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../gestion/comun.dart' show SelectorMes, rangoMes;
import 'stock_comun.dart';

/// Historial de subidas y bajadas de stock, por mes.
class MovimientosStockPage extends StatefulWidget {
  const MovimientosStockPage({super.key});

  @override
  State<MovimientosStockPage> createState() => _MovimientosStockPageState();
}

class _MovimientosStockPageState extends State<MovimientosStockPage> {
  DateTime _mes = DateTime.now();
  String _tipo = 'todo';
  String _buscar = '';
  List<Map<String, dynamic>> _movs = [];
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
        final finMes = DateTime.parse(hasta).add(const Duration(days: 1));
        final r = await supabase
            .from('movimientos_stock')
            .select('id, tipo, cantidad, coste, nota, creado_en, articulos_stock(nombre, unidad)')
            .gte('creado_en', DateTime.parse(desde).toUtc().toIso8601String())
            .lt('creado_en', finMes.toUtc().toIso8601String())
            .order('creado_en', ascending: false)
            .limit(2000);
        _movs = List<Map<String, dynamic>>.from(r);
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

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    final t = _buscar.toLowerCase();
    final lista = _movs.where((m) {
      final a = m['articulos_stock'] as Map<String, dynamic>?;
      return (_tipo == 'todo' || m['tipo'] == _tipo || (_tipo == 'venta' && m['tipo'] == 'anulacion')) &&
          ((a?['nombre'] as String?) ?? '').toLowerCase().contains(t);
    }).toList();
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
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
          SizedBox(
            width: 260,
            child: TextField(
              onChanged: (v) => setState(() => _buscar = v),
              decoration: const InputDecoration(hintText: 'Buscar artículo', prefixIcon: Icon(Icons.search), isDense: true),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Segmentos(
          opciones: const {'todo': 'Todo', 'venta': 'Ventas', 'entrada': 'Entradas', 'merma': 'Mermas', 'recuento': 'Recuentos'},
          actual: _tipo,
          onCambio: (v) => setState(() => _tipo = v),
        ),
        const SizedBox(height: 16),
        if (_cargando)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (lista.isEmpty)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Sin movimientos', style: TextStyle(color: C.gris))))
        else
          for (final m in lista) _fila(m),
      ],
    );
  }

  Widget _fila(Map<String, dynamic> m) {
    final a = m['articulos_stock'] as Map<String, dynamic>?;
    final tipo = tiposMovimiento[m['tipo']]!;
    final c = num0(m['cantidad']);
    final f = DateTime.parse(m['creado_en'] as String).toLocal();
    final fecha = '${f.day.toString().padLeft(2, '0')}/${f.month.toString().padLeft(2, '0')} '
        '${f.hour.toString().padLeft(2, '0')}:${f.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TarjetaFila(
        child: Row(children: [
          IconoFila(tipo.icono, tipo.color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((a?['nombre'] as String?) ?? 'Artículo quitado', style: titulo(16), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                [fecha, tipo.texto, if ((m['nota'] as String?)?.isNotEmpty ?? false) m['nota']].join(' · '),
                style: const TextStyle(color: C.gris, fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          Text('${c > 0 ? '+' : ''}${conUnidad(c, (a?['unidad'] as String?) ?? '')}',
              style: titulo(17, color: c < 0 ? const Color(0xFFB3261E) : C.verde)),
          const SizedBox(width: 8),
        ]),
      ),
    );
  }
}
