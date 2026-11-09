import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/modelos.dart' show euros;
import 'stock_comun.dart';

/// Crea un pedido a proveedor con sus líneas y copia el texto para enviarlo. Devuelve el nº.
Future<int> crearPedidoProveedor(String? proveedorId, String proveedorNombre, List<({Map<String, dynamic> articulo, double cantidad})> lineas) async {
  exigirConexion();
  final p = await supabase.from('pedidos_proveedor').insert({'proveedor_id': proveedorId}).select('id, numero').single();
  await supabase.from('pedido_proveedor_lineas').insert([
    for (final l in lineas)
      {'pedido_id': p['id'], 'articulo_id': l.articulo['id'], 'pedida': l.cantidad, 'coste': l.articulo['coste']},
  ]);
  await Clipboard.setData(ClipboardData(text: textoPedido(proveedorNombre, p['numero'] as int,
      [for (final l in lineas) (nombre: l.articulo['nombre'] as String, cantidad: l.cantidad, unidad: l.articulo['unidad'] as String)])));
  return p['numero'] as int;
}

String textoPedido(String proveedor, int numero, List<({String nombre, double cantidad, String unidad})> lineas) => [
      'Hola, pedido nº $numero para $proveedor:',
      for (final l in lineas) '- ${l.nombre}: ${conUnidad(l.cantidad, l.unidad)}',
      'Gracias',
    ].join('\n');

/// Pedidos a proveedor: pendientes de llegar y recibidos (con lo que faltó).
class PedidosProveedorPage extends StatefulWidget {
  const PedidosProveedorPage({super.key});

  @override
  State<PedidosProveedorPage> createState() => _PedidosProveedorPageState();
}

class _PedidosProveedorPageState extends State<PedidosProveedorPage> {
  List<Map<String, dynamic>> _pedidos = [];
  List<Map<String, dynamic>> _proveedores = [];
  List<Map<String, dynamic>> _articulos = [];
  String _vista = 'pendiente';
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
        final r = await Future.wait<dynamic>([
          supabase
              .from('pedidos_proveedor')
              .select('*, proveedores(nombre, iva_habitual), '
                  'pedido_proveedor_lineas(id, articulo_id, pedida, recibida, coste, articulos_stock(nombre, unidad, coste))')
              .neq('estado', 'cancelado')
              .order('creado_en', ascending: false)
              .limit(150),
          supabase.from('proveedores').select('id, nombre').order('nombre'),
          supabase.from('articulos_stock').select().eq('activo', true).order('nombre'),
        ]);
        _pedidos = List<Map<String, dynamic>>.from(r[0] as List);
        _proveedores = List<Map<String, dynamic>>.from(r[1] as List);
        _articulos = List<Map<String, dynamic>>.from(r[2] as List);
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

  void _avisar(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  String _prov(Map<String, dynamic> p) => ((p['proveedores'] as Map?)?['nombre'] as String?) ?? 'Sin proveedor';
  List<Map<String, dynamic>> _lineas(Map<String, dynamic> p) =>
      List<Map<String, dynamic>>.from(p['pedido_proveedor_lineas'] as List? ?? const []);
  String _art(Map<String, dynamic> l, String campo) => ((l['articulos_stock'] as Map?)?[campo] as String?) ?? '';

  Future<void> _nuevo() async {
    try {
      exigirConexion();
      final r = await mostrarPanel<(String?, String, List<({Map<String, dynamic> articulo, double cantidad})>)>(
          context, (_) => _PanelNuevo(proveedores: _proveedores, articulos: _articulos));
      if (r == null) return;
      final n = await crearPedidoProveedor(r.$1, r.$2, r.$3);
      _avisar('Pedido nº $n guardado y copiado: pégalo en WhatsApp o en un correo');
      await _cargar();
    } catch (e) {
      _avisar(textoError(e));
    }
  }

  Future<void> _copiar(Map<String, dynamic> p) async {
    await Clipboard.setData(ClipboardData(text: textoPedido(_prov(p), p['numero'] as int, [
      for (final l in _lineas(p)) (nombre: _art(l, 'nombre'), cantidad: num0(l['pedida']), unidad: _art(l, 'unidad')),
    ])));
    _avisar('Pedido copiado');
  }

  Future<void> _cancelar(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Cancelar el pedido nº ${p['numero']}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancelar pedido')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      exigirConexion();
      await supabase.from('pedidos_proveedor').update({'estado': 'cancelado'}).eq('id', p['id']);
      await _cargar();
    } catch (e) {
      _avisar(textoError(e));
    }
  }

  Future<void> _recibir(Map<String, dynamic> p) async {
    try {
      exigirConexion();
      final datos = await mostrarPanel<Map<String, dynamic>>(context, (_) => _PanelRecibir(pedido: p, lineas: _lineas(p)));
      if (datos == null) return;
      await supabase.rpc('recibir_pedido_proveedor', params: {
        'p_pedido': p['id'],
        'p_lineas': datos['lineas'],
        'p_importe': datos['importe'],
        'p_pagado': datos['pagado'],
        'p_albaran': datos['albaran'],
      });
      _avisar('Recibido: stock actualizado${(datos['importe'] as double) > 0 ? ' y gasto apuntado' : ''}');
      await _cargar();
    } catch (e) {
      _avisar(textoError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final lista = _pedidos.where((p) => p['estado'] == _vista).toList();
    final pendientes = _pedidos.where((p) => p['estado'] == 'pendiente').length;
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Row(children: [
          Expanded(
            child: Segmentos(
              opciones: {'pendiente': 'Por llegar ($pendientes)', 'recibido': 'Recibidos'},
              actual: _vista,
              onCambio: (v) => setState(() => _vista = v),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(onPressed: _nuevo, icon: const Icon(Icons.add), label: const Text('Nuevo pedido')),
        ]),
        const SizedBox(height: 8),
        const Text('Truco: en Stock › "Para pedir" cada proveedor tiene su botón "Crear pedido" con lo que falta.',
            style: TextStyle(color: C.gris, fontSize: 12)),
        const SizedBox(height: 14),
        if (lista.isEmpty)
          Padding(
            padding: const EdgeInsets.all(30),
            child: Center(child: Text(_vista == 'pendiente' ? 'Nada por llegar' : 'Aún no hay pedidos recibidos',
                style: const TextStyle(color: C.gris))),
          ),
        for (final p in lista) _tarjeta(p),
      ],
    );
  }

  Widget _tarjeta(Map<String, dynamic> p) {
    final f = DateTime.parse((p['recibido_en'] ?? p['creado_en']) as String).toLocal();
    final lineas = _lineas(p);
    final faltas = [
      for (final l in lineas)
        if (p['estado'] == 'recibido' && num0(l['recibida']) < num0(l['pedida']))
          '${_art(l, 'nombre')} (${cantidad(num0(l['pedida']) - num0(l['recibida']))})',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.blanco,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: faltas.isEmpty ? C.borde : C.naranja),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Nº ${p['numero']} · ${_prov(p)}', style: titulo(17))),
          Text('${p['estado'] == 'recibido' ? 'Llegó' : 'Pedido'} ${f.day}/${f.month}', style: const TextStyle(color: C.gris)),
        ]),
        const SizedBox(height: 6),
        Text(
          lineas.map((l) => '${_art(l, 'nombre')} ${cantidad(num0(p['estado'] == 'recibido' ? l['recibida'] : l['pedida']))}'
              ' ${_art(l, 'unidad')}').join(' · '),
          style: const TextStyle(color: C.gris),
        ),
        if (faltas.isNotEmpty) ...[
          const SizedBox(height: 6),
          EtiquetaEstado('Faltó: ${faltas.join(', ')}', aviso: true),
        ],
        if ((p['albaran'] as String?) != null) Text('Albarán ${p['albaran']}', style: const TextStyle(fontSize: 12, color: C.gris)),
        if (p['estado'] == 'pendiente') ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: () => _recibir(p), icon: const Icon(Icons.move_to_inbox_outlined), label: const Text('Ha llegado')),
            OutlinedButton.icon(onPressed: () => _copiar(p), icon: const Icon(Icons.copy), label: const Text('Copiar')),
            TextButton(onPressed: () => _cancelar(p), child: const Text('Cancelar')),
          ]),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------
// Nuevo pedido a mano
// ---------------------------------------------------------------------
class _PanelNuevo extends StatefulWidget {
  const _PanelNuevo({required this.proveedores, required this.articulos});
  final List<Map<String, dynamic>> proveedores, articulos;

  @override
  State<_PanelNuevo> createState() => _PanelNuevoState();
}

class _PanelNuevoState extends State<_PanelNuevo> {
  String? _prov;
  final _cant = <String, TextEditingController>{};
  String? _err;

  List<Map<String, dynamic>> get _visibles =>
      [for (final a in widget.articulos) if (_prov == null || a['proveedor_id'] == _prov) a];

  TextEditingController _c(Map<String, dynamic> a) => _cant.putIfAbsent(
      a['id'] as String, () => TextEditingController(text: sugerido(a) > 0 ? cantidad(sugerido(a)) : ''));

  void _guardar() {
    final lineas = <({Map<String, dynamic> articulo, double cantidad})>[];
    for (final a in _visibles) {
      final t = _c(a).text.trim();
      if (t.isEmpty) continue;
      final n = leerNumero(t);
      if (n == null || n < 0) return setState(() => _err = 'Revisa la cantidad de ${a['nombre']}');
      if (n > 0) lineas.add((articulo: a, cantidad: n));
    }
    if (lineas.isEmpty) return setState(() => _err = 'Pon la cantidad de algún artículo');
    final nombre = _prov == null ? 'proveedor' : widget.proveedores.firstWhere((p) => p['id'] == _prov)['nombre'] as String;
    Navigator.pop(context, (_prov, nombre, lineas));
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: 'Nuevo pedido',
        boton: 'Guardar y copiar',
        onBoton: _guardar,
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const EtiquetaCampo('Proveedor'),
          DropdownButtonFormField<String?>(
            initialValue: _prov,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: null, child: Text('Todos los artículos')),
              for (final p in widget.proveedores) DropdownMenuItem(value: p['id'] as String, child: Text(p['nombre'] as String)),
            ],
            onChanged: (v) => setState(() => _prov = v),
          ),
          const SizedBox(height: 12),
          const Text('Viene puesto lo que falta para llegar al doble del mínimo. Vacío = no se pide.',
              style: TextStyle(color: C.gris, fontSize: 13)),
          const SizedBox(height: 8),
          for (final a in _visibles)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a['nombre'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('hay ${conUnidad(num0(a['stock']), a['unidad'] as String)}', style: const TextStyle(color: C.gris, fontSize: 12)),
                  ]),
                ),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _c(a),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(isDense: true, suffixText: a['unidad'] as String),
                  ),
                ),
              ]),
            ),
          if (_err != null) Text(_err!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
        ]),
      );
}

// ---------------------------------------------------------------------
// Recibir: lo que llegó de verdad, precios y factura
// ---------------------------------------------------------------------
class _PanelRecibir extends StatefulWidget {
  const _PanelRecibir({required this.pedido, required this.lineas});
  final Map<String, dynamic> pedido;
  final List<Map<String, dynamic>> lineas;

  @override
  State<_PanelRecibir> createState() => _PanelRecibirState();
}

class _PanelRecibirState extends State<_PanelRecibir> {
  late final _rec = {for (final l in widget.lineas) l['id'] as String: TextEditingController(text: cantidad(num0(l['pedida'])))};
  late final _cost = {
    for (final l in widget.lineas)
      l['id'] as String: TextEditingController(
          text: () {
            final c = num0(l['coste'] ?? (l['articulos_stock'] as Map?)?['coste']);
            return c > 0 ? cantidad(c) : '';
          }()),
  };
  final _albaran = TextEditingController();
  final _importe = TextEditingController();
  bool _importeTocado = false, _pagado = false;
  String? _err;

  double get _iva {
    final t = (widget.pedido['proveedores'] as Map?)?['iva_habitual'] as String?;
    return double.tryParse(t ?? '') ?? 10;
  }

  double get _baseCalculada {
    var s = 0.0;
    for (final l in widget.lineas) {
      s += (leerNumero(_rec[l['id']]!.text) ?? 0) * (leerNumero(_cost[l['id']]!.text) ?? 0);
    }
    return s;
  }

  void _recalcular() {
    if (!_importeTocado) {
      final t = _baseCalculada * (1 + _iva / 100);
      _importe.text = t > 0 ? t.toStringAsFixed(2).replaceAll('.', ',') : '';
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recalcular());
  }

  void _guardar() {
    final lineas = <Map<String, dynamic>>[];
    for (final l in widget.lineas) {
      final r = leerNumero(_rec[l['id']]!.text);
      final cTxt = _cost[l['id']]!.text.trim();
      final c = cTxt.isEmpty ? null : leerNumero(cTxt);
      if (r == null || r < 0) return setState(() => _err = 'Revisa lo recibido de ${l['articulos_stock']?['nombre']}');
      if (cTxt.isNotEmpty && (c == null || c < 0)) return setState(() => _err = 'Revisa los precios');
      lineas.add({'id': l['id'], 'recibida': r, 'coste': c});
    }
    final importe = _importe.text.trim().isEmpty ? 0.0 : leerNumero(_importe.text);
    if (importe == null || importe < 0) return setState(() => _err = 'Revisa el importe de la factura');
    Navigator.pop(context, {'lineas': lineas, 'importe': importe, 'pagado': _pagado, 'albaran': _albaran.text.trim()});
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: 'Ha llegado el nº ${widget.pedido['numero']}',
        boton: 'Confirmar llegada',
        onBoton: _guardar,
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Corrige lo que no coincida con el albarán. Al confirmar sube el stock y se apunta el gasto.',
              style: TextStyle(color: C.gris, fontSize: 13)),
          const SizedBox(height: 10),
          for (final l in widget.lineas)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(border: Border.all(color: C.borde), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${(l['articulos_stock'] as Map?)?['nombre']} · pedido ${cantidad(num0(l['pedida']))}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _rec[l['id']],
                      onChanged: (_) => _recalcular(),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Ha llegado', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _cost[l['id']],
                      onChanged: (_) => _recalcular(),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Precio/ud sin IVA', suffixText: '€', isDense: true),
                    ),
                  ),
                ]),
              ]),
            ),
          const EtiquetaCampo('Nº de albarán o factura'),
          TextField(controller: _albaran, decoration: const InputDecoration(hintText: 'Opcional')),
          EtiquetaCampo('Importe de la factura (IVA ${_iva.toStringAsFixed(0)} % incluido)'),
          TextField(
            controller: _importe,
            onChanged: (_) => _importeTocado = true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              suffixText: '€',
              helperText: 'Calculado: ${euros(_baseCalculada * (1 + _iva / 100))}. Déjalo vacío si la factura llega más tarde.',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _pagado,
            onChanged: (v) => setState(() => _pagado = v),
            title: const Text('Ya está pagado'),
            subtitle: const Text('Si no, queda en Proveedores como "debe"'),
          ),
          if (_err != null) Text(_err!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
        ]),
      );
}
