import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../gestion/comun.dart' show Cifra;
import '../ticketbai/modelos.dart' show euros;
import 'stock_comun.dart';
import 'pedidos_proveedor_page.dart' show crearPedidoProveedor;
import 'stock_paneles.dart';

/// Existencias: lo que hay, lo que falta y lo que hay que pedir.
/// Las ventas descuentan solas (lo hace la base de datos al cobrar).
class StockPage extends StatefulWidget {
  const StockPage({super.key});

  @override
  State<StockPage> createState() => _StockPageState();
}

class _StockPageState extends State<StockPage> {
  List<Map<String, dynamic>> _articulos = [];
  List<Map<String, dynamic>> _escandallos = [];
  List<Map<String, dynamic>> _productos = [];
  List<Map<String, dynamic>> _proveedores = [];
  List<Map<String, dynamic>> _grupos = [];
  List<Map<String, dynamic>> _areas = [];
  String _buscar = '';
  String _vista = 'todo';
  bool _cargando = true;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

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
    final r = await Future.wait([
      supabase.from('articulos_stock').select().eq('activo', true).order('nombre'),
      supabase.from('escandallos').select('id, producto_id, articulo_id, cantidad'),
      supabase.from('productos').select('id, nombre').eq('activo', true).order('nombre'),
      supabase.from('proveedores').select('id, nombre').order('nombre'),
      supabase.from('grupos_productos').select('id, nombre').eq('activo', true).order('orden').order('nombre'),
      supabase.from('areas_preparacion').select('id, nombre').eq('activo', true),
    ]);
    _articulos = List<Map<String, dynamic>>.from(r[0]);
    _escandallos = List<Map<String, dynamic>>.from(r[1]);
    _productos = List<Map<String, dynamic>>.from(r[2]);
    _proveedores = List<Map<String, dynamic>>.from(r[3]);
    _grupos = List<Map<String, dynamic>>.from(r[4]);
    _areas = List<Map<String, dynamic>>.from(r[5]);
    if (mounted) setState(() => _cargando = false);
  }

  String _nombreProducto(String id) =>
      _productos.firstWhere((p) => p['id'] == id, orElse: () => {'nombre': '¿?'})['nombre'] as String;
  String? _nombreProveedor(String? id) =>
      id == null ? null : _proveedores.firstWhere((p) => p['id'] == id, orElse: () => {'nombre': null})['nombre'] as String?;

  Future<void> _abrir(Future<bool> Function() panel) async {
    try {
      exigirConexion();
      if (await panel()) await _cargar();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
  }

  void _editar([Map<String, dynamic>? a]) => _abrir(() => editarArticulo(context,
      articulo: a,
      recetas: [for (final e in _escandallos) if (a != null && e['articulo_id'] == a['id']) e],
      productos: _productos,
      proveedores: _proveedores,
      grupos: _grupos,
      areas: _areas));

  void _entrada() => _abrir(() => apuntarEntrada(context, _articulos));
  void _merma() => _abrir(() => apuntarMerma(context, _articulos));
  void _recuento() => _abrir(() => hacerRecuento(context, _articulos));

  Future<void> _copiarPedido(String proveedor, List<Map<String, dynamic>> lineas) async {
    final texto = [
      'Pedido para $proveedor:',
      for (final a in lineas) '- ${a['nombre']}: ${conUnidad(sugerido(a), a['unidad'] as String)}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: texto));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pedido copiado: pégalo en WhatsApp o en un correo')));
    }
  }

  /// Guarda el pedido (Compras › Pedidos) con lo sugerido y copia el texto para enviarlo.
  Future<void> _crearPedido(String proveedor, List<Map<String, dynamic>> lineas) async {
    try {
      final n = await crearPedidoProveedor(lineas.first['proveedor_id'] as String?, proveedor, [
        for (final a in lineas)
          if (sugerido(a) > 0) (articulo: a, cantidad: sugerido(a)),
      ]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Pedido nº $n guardado en Compras › Pedidos y copiado: pégalo en WhatsApp')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final t = _buscar.toLowerCase();
    final bajos = _articulos.where(bajoMinimo).toList();
    final valor = _articulos.fold(0.0, (s, a) => s + (num0(a['stock']) > 0 ? num0(a['stock']) * num0(a['coste']) : 0));
    final lista = (_vista == 'pedir' ? bajos : _articulos)
        .where((a) => (a['nombre'] as String).toLowerCase().contains(t))
        .toList();
    final ancho = MediaQuery.sizeOf(context).width;
    final estrecho = ancho < 700;

    final botones = Wrap(spacing: 10, runSpacing: 10, children: [
      FilledButton.icon(onPressed: _entrada, icon: const Icon(Icons.move_to_inbox_outlined), label: const Text('Entrada de mercancía')),
      OutlinedButton.icon(onPressed: _recuento, icon: const Icon(Icons.fact_check_outlined), label: const Text('Recuento')),
      OutlinedButton.icon(onPressed: _merma, icon: const Icon(Icons.delete_outline), label: const Text('Merma')),
      OutlinedButton.icon(onPressed: _editar, icon: const Icon(Icons.add), label: const Text('Nuevo artículo')),
    ]);

    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
        children: [
          Wrap(spacing: 14, runSpacing: 14, children: [
            Cifra('Valor del stock', euros(valor), detalle: 'a precio de compra, sin IVA', destacada: true),
            Cifra('Bajo mínimo', '${bajos.length}',
                detalle: bajos.isEmpty ? 'todo en orden' : 'hay que pedir', color: bajos.isEmpty ? null : C.naranja),
            Cifra('Artículos', '${_articulos.length}',
                detalle: '${_articulos.where((a) => _escandallos.every((e) => e['articulo_id'] != a['id'])).length} sin receta'),
          ]),
          const SizedBox(height: 18),
          botones,
          const SizedBox(height: 16),
          Builder(builder: (_) {
            final selector = Segmentos(
              opciones: {'todo': 'Todo', 'pedir': 'Para pedir (${bajos.length})'},
              actual: _vista,
              onCambio: (v) => setState(() => _vista = v),
            );
            final buscador = TextField(
              onChanged: (v) => setState(() => _buscar = v),
              decoration: const InputDecoration(hintText: 'Buscar artículo', prefixIcon: Icon(Icons.search), isDense: true),
            );
            return estrecho
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [selector, const SizedBox(height: 10), buscador])
                : Row(children: [SizedBox(width: 320, child: selector), const SizedBox(width: 12), Expanded(child: buscador)]);
          }),
          const SizedBox(height: 16),
          if (lista.isEmpty)
            Padding(
              padding: const EdgeInsets.all(30),
              child: Center(
                child: Text(
                  _vista == 'pedir'
                      ? 'No falta nada'
                      : _articulos.isEmpty
                          ? 'Aún no hay artículos. Crea el primero con "Nuevo artículo".'
                          : 'Sin resultados',
                  style: const TextStyle(color: C.gris),
                ),
              ),
            ),
          if (_vista == 'pedir') ..._porProveedor(lista) else
            for (final a in lista) _fila(a),
        ],
      ),
    );
  }

  /// Lista para pedir, agrupada por proveedor y con botón para copiar el pedido.
  List<Widget> _porProveedor(List<Map<String, dynamic>> lista) {
    final grupos = <String, List<Map<String, dynamic>>>{};
    for (final a in lista) {
      grupos.putIfAbsent(_nombreProveedor(a['proveedor_id'] as String?) ?? 'Sin proveedor', () => []).add(a);
    }
    return [
      for (final g in grupos.entries) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 0, 8),
          child: Row(children: [
            Expanded(child: Text(g.key, style: titulo(18))),
            TextButton.icon(
              onPressed: () => _copiarPedido(g.key, g.value),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copiar'),
            ),
            FilledButton.icon(
              onPressed: () => _crearPedido(g.key, g.value),
              icon: const Icon(Icons.local_shipping_outlined, size: 18),
              label: const Text('Crear pedido'),
            ),
          ]),
        ),
        for (final a in g.value) _fila(a, pedir: true),
      ],
    ];
  }

  Widget _fila(Map<String, dynamic> a, {bool pedir = false}) {
    final recetas = [for (final e in _escandallos) if (e['articulo_id'] == a['id']) _nombreProducto(e['producto_id'] as String)];
    final unidad = a['unidad'] as String;
    final stock = num0(a['stock']);
    final bajo = bajoMinimo(a);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TarjetaFila(
        onTap: () => _editar(a),
        child: Row(children: [
          IconoFila(Icons.inventory_2_outlined, bajo ? C.naranja : C.verde),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a['nombre'] as String, style: titulo(17), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                [
                  ?_nombreProveedor(a['proveedor_id'] as String?),
                  if (num0(a['minimo']) > 0) 'mínimo ${conUnidad(num0(a['minimo']), unidad)}',
                  recetas.isEmpty ? 'no se descuenta con ninguna venta' : 'se descuenta con ${recetas.join(', ')}',
                ].join(' · '),
                style: const TextStyle(color: C.gris, fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(conUnidad(stock, unidad), style: titulo(20, color: stock < 0 ? const Color(0xFFB3261E) : C.tinta)),
            const SizedBox(height: 4),
            if (pedir)
              EtiquetaEstado('Pedir ${conUnidad(sugerido(a), unidad)}', aviso: true)
            else if (stock < 0)
              const EtiquetaEstado('Revisar: negativo', aviso: true)
            else if (bajo)
              const EtiquetaEstado('Bajo mínimo', aviso: true),
          ]),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, color: C.gris),
        ]),
      ),
    );
  }
}
