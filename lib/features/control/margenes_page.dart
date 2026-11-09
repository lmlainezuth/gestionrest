import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../gestion/comun.dart' show Cifra, leerTodo;
import '../ticketbai/modelos.dart' show euros;

/// Margen por producto: coste (receta del stock o precio de compra) frente al precio sin IVA,
/// y cuánto ha dejado cada uno en los últimos 30 días.
class MargenesPage extends StatefulWidget {
  const MargenesPage({super.key});

  @override
  State<MargenesPage> createState() => _MargenesPageState();
}

class _Fila {
  _Fila(this.p);
  final Map<String, dynamic> p;
  double? coste;
  String origen = '';
  double vendidos = 0;
  String get nombre => p['nombre'] as String;
  String get grupo => ((p['grupos_productos'] as Map?)?['nombre'] as String?) ?? '';
  double get pvp => (p['precio_venta'] as num).toDouble();
  double get iva => ((p['tipo_iva'] as num?) ?? 10).toDouble();
  double get sinIva => pvp / (1 + iva / 100);
  double? get margen => coste == null ? null : sinIva - coste!;
  double? get pct => coste == null || sinIva == 0 ? null : margen! / sinIva * 100;
  double get beneficio => (margen ?? 0) * vendidos;

  /// Precio con IVA para llegar al margen objetivo, redondeado a 0,10 hacia arriba.
  double sugerido(double objetivo) => ((coste! / (1 - objetivo / 100)) * (1 + iva / 100) * 10).ceilToDouble() / 10;
}

class _MargenesPageState extends State<MargenesPage> {
  List<_Fila> _filas = [];
  String _objetivo = '65';
  String _vista = 'todos';
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
        final desde = DateTime.now().subtract(const Duration(days: 30)).toUtc().toIso8601String();
        final r = await Future.wait<dynamic>([
          supabase.from('productos').select('id, nombre, precio_venta, tipo_iva, precio_compra, grupos_productos(nombre)').eq('activo', true),
          supabase.from('escandallos').select('producto_id, cantidad, articulos_stock(coste)'),
          leerTodo((a, b) => supabase
              .from('pedido_detalle')
              .select('producto_id, cantidad')
              .neq('estado_cocina', 'anulado')
              .gte('creado_en', desde)
              .range(a, b)),
        ]);
        final filas = {for (final p in r[0] as List) p['id'] as String: _Fila(Map<String, dynamic>.from(p as Map))};
        for (final e in r[1] as List) {
          final f = filas[e['producto_id']];
          if (f == null) continue;
          final c = ((e['articulos_stock'] as Map?)?['coste'] as num?)?.toDouble() ?? 0;
          f.coste = (f.coste ?? 0) + c * (e['cantidad'] as num).toDouble();
          f.origen = 'receta';
        }
        for (final f in filas.values) {
          final pc = (f.p['precio_compra'] as num?)?.toDouble() ?? 0;
          if ((f.coste == null || f.coste == 0) && pc > 0) {
            f.coste = pc;
            f.origen = 'precio de compra';
          }
          if (f.coste == 0) f.coste = null; // receta sin costes puestos
        }
        for (final d in r[2] as List<Map<String, dynamic>>) {
          filas[d['producto_id']]?.vendidos += (d['cantidad'] as num).toDouble();
        }
        _filas = filas.values.toList();
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
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final obj = double.parse(_objetivo);
    final conCoste = _filas.where((f) => f.coste != null).toList();
    final bajos = conCoste.where((f) => f.pct! < obj).toList();
    final sinCoste = _filas.where((f) => f.coste == null).toList();
    final beneficio = conCoste.fold(0.0, (s, f) => s + f.beneficio);
    final lista = switch (_vista) {
      'bajos' => bajos..sort((a, b) => b.vendidos.compareTo(a.vendidos)),
      'sin' => sinCoste..sort((a, b) => b.vendidos.compareTo(a.vendidos)),
      _ => [...conCoste]..sort((a, b) => b.beneficio.compareTo(a.beneficio)),
    };
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Wrap(spacing: 12, runSpacing: 12, children: [
          Cifra('Beneficio bruto 30 días', euros(beneficio), detalle: 'ventas sin IVA − coste', destacada: true),
          Cifra('Por debajo del $_objetivo %', '${bajos.length}', detalle: 'conviene subir precio', color: bajos.isEmpty ? null : C.naranja),
          Cifra('Sin coste', '${sinCoste.length}', detalle: 'pon receta o precio de compra'),
        ]),
        const SizedBox(height: 16),
        const Text('Margen mínimo que quieres', style: TextStyle(color: C.gris)),
        const SizedBox(height: 6),
        SizedBox(
          width: 360,
          child: Segmentos(
            opciones: const {'60': '60 %', '65': '65 %', '70': '70 %', '75': '75 %'},
            actual: _objetivo,
            onCambio: (v) => setState(() => _objetivo = v),
          ),
        ),
        const SizedBox(height: 12),
        Segmentos(
          opciones: {'todos': 'Más rentables', 'bajos': 'Margen bajo (${bajos.length})', 'sin': 'Sin coste (${sinCoste.length})'},
          actual: _vista,
          onCambio: (v) => setState(() => _vista = v),
        ),
        const SizedBox(height: 8),
        const Text('Coste: receta del stock (Compras › Stock) o, si no tiene, el precio de compra del producto. '
            'Margen = precio sin IVA − coste.', style: TextStyle(color: C.gris, fontSize: 12)),
        const SizedBox(height: 12),
        if (lista.isEmpty)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Nada aquí', style: TextStyle(color: C.gris)))),
        for (final f in lista) _fila(f, obj),
      ],
    );
  }

  Widget _fila(_Fila f, double obj) {
    final bajo = f.pct != null && f.pct! < obj;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TarjetaFila(
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.nombre, style: titulo(16), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                [
                  if (f.grupo.isNotEmpty) f.grupo,
                  'PVP ${euros(f.pvp)}',
                  if (f.coste != null) 'coste ${euros(f.coste!)} (${f.origen})' else 'sin coste',
                  '${f.vendidos.toStringAsFixed(0)} vendidos en 30 días',
                ].join(' · '),
                style: const TextStyle(color: C.gris, fontSize: 13),
              ),
              if (bajo)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: EtiquetaEstado('Para el $_objetivo %: ${euros(f.sugerido(obj))}', aviso: true),
                ),
            ]),
          ),
          const SizedBox(width: 8),
          if (f.pct != null)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${f.pct!.toStringAsFixed(0)} %', style: titulo(20, color: bajo ? C.naranja : C.verde)),
              Text('${euros(f.margen!)} / ud', style: const TextStyle(color: C.gris, fontSize: 12)),
              if (f.vendidos > 0) Text('${euros(f.beneficio)} en 30 d', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          const SizedBox(width: 6),
        ]),
      ),
    );
  }
}
