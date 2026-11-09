import 'package:flutter/material.dart';

import '../../core/panel_lateral.dart';
import '../../core/tema.dart';
import '../../main.dart';
import 'stock_comun.dart';

const _rojo = Color(0xFFB3261E);

Widget _error(String? e) => e == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(e, style: const TextStyle(color: _rojo, fontWeight: FontWeight.w600)),
      );

Widget _selectorArticulo(List<Map<String, dynamic>> articulos, String? actual, ValueChanged<String?> onCambio) =>
    DropdownButtonFormField<String>(
      initialValue: actual,
      isExpanded: true,
      menuMaxHeight: 420,
      hint: const Text('Artículo'),
      items: [
        for (final a in articulos)
          DropdownMenuItem(value: a['id'] as String, child: Text('${a['nombre']} (${a['unidad']})', overflow: TextOverflow.ellipsis)),
      ],
      onChanged: onCambio,
    );

// =====================================================================
// Alta / edición de artículo con su receta (con qué ventas se descuenta)
// =====================================================================

Future<bool> editarArticulo(
  BuildContext context, {
  Map<String, dynamic>? articulo,
  required List<Map<String, dynamic>> recetas,
  required List<Map<String, dynamic>> productos,
  required List<Map<String, dynamic>> proveedores,
  required List<Map<String, dynamic>> grupos,
  required List<Map<String, dynamic>> areas,
}) async {
  final r = await mostrarPanel<Map<String, dynamic>>(
    context,
    (_) => _PanelArticulo(articulo: articulo, recetas: recetas, productos: productos, proveedores: proveedores, grupos: grupos),
  );
  if (r == null) return false;
  if (r['_borrar'] == true) {
    // No se borra: se conserva su historial de movimientos
    await supabase.from('articulos_stock').update({'activo': false}).eq('id', articulo!['id']);
    return true;
  }
  final datos = Map<String, dynamic>.from(r['articulo'] as Map);
  final id = articulo == null
      ? (await supabase.from('articulos_stock').insert(datos).select('id').single())['id'] as String
      : articulo['id'] as String;
  if (articulo != null) await supabase.from('articulos_stock').update(datos).eq('id', id);
  await supabase.from('escandallos').delete().eq('articulo_id', id);
  final lineas = r['recetas'] as List<Map<String, dynamic>>;
  // "Venderlo también en la Barra": crea el producto en la Carta y lo une con 1 unidad
  final vender = r['vender'] as Map<String, dynamic>?;
  if (vender != null) {
    final barra = areas.where((x) => (x['nombre'] as String).toLowerCase() == 'barra').firstOrNull;
    final prod = await supabase
        .from('productos')
        .insert({...vender, 'nombre': datos['nombre'], 'precio_compra': datos['coste'], 'area_id': ?barra?['id']})
        .select('id')
        .single();
    lineas.add({'producto_id': prod['id'], 'cantidad': 1});
  }
  if (lineas.isNotEmpty) {
    await supabase.from('escandallos').insert([for (final l in lineas) {...l, 'articulo_id': id}]);
  }
  return true;
}

class _LineaReceta {
  _LineaReceta(this.producto, num? cant) : ctrl = TextEditingController(text: cant == null ? '1' : cantidad(cant));
  String? producto;
  final TextEditingController ctrl;
}

class _PanelArticulo extends StatefulWidget {
  const _PanelArticulo(
      {required this.articulo, required this.recetas, required this.productos, required this.proveedores, required this.grupos});
  final List<Map<String, dynamic>> grupos;
  final Map<String, dynamic>? articulo;
  final List<Map<String, dynamic>> recetas;
  final List<Map<String, dynamic>> productos;
  final List<Map<String, dynamic>> proveedores;

  @override
  State<_PanelArticulo> createState() => _PanelArticuloState();
}

class _PanelArticuloState extends State<_PanelArticulo> {
  late final a = widget.articulo;
  late final _nombre = TextEditingController(text: a?['nombre'] as String?);
  late final _minimo = TextEditingController(text: a == null ? '' : cantidad(num0(a!['minimo'])));
  late final _coste = TextEditingController(text: a == null || num0(a!['coste']) == 0 ? '' : cantidad(num0(a!['coste'])));
  final _inicial = TextEditingController();
  late String _unidad = (a?['unidad'] as String?) ?? 'ud';
  late String? _proveedor = a?['proveedor_id'] as String?;
  late final _lineas = [for (final e in widget.recetas) _LineaReceta(e['producto_id'] as String, e['cantidad'] as num)];
  String? _err;
  late bool _vender = widget.articulo == null;
  late String? _grupo = widget.grupos.isEmpty ? null : widget.grupos.first['id'] as String;
  final _precio = TextEditingController();
  double _iva = 10;

  void _guardar() {
    if (_nombre.text.trim().isEmpty) return setState(() => _err = 'Escribe el nombre del artículo');
    final precio = leerNumero(_precio.text);
    if (_vender && (_grupo == null || precio == null || precio <= 0)) {
      return setState(() => _err = 'Para venderlo en la Barra elige el grupo y pon el precio de venta');
    }
    final minimo = _minimo.text.trim().isEmpty ? 0.0 : leerNumero(_minimo.text);
    final coste = _coste.text.trim().isEmpty ? 0.0 : leerNumero(_coste.text);
    final inicial = _inicial.text.trim().isEmpty ? 0.0 : leerNumero(_inicial.text);
    if (minimo == null || minimo < 0 || coste == null || coste < 0 || inicial == null) {
      return setState(() => _err = 'Revisa los números (usa coma para decimales: 0,5)');
    }
    final recetas = <Map<String, dynamic>>[];
    final vistos = <String>{};
    for (final l in _lineas) {
      if (l.producto == null) continue;
      final c = leerNumero(l.ctrl.text);
      if (c == null || c <= 0) return setState(() => _err = 'Cada producto necesita una cantidad mayor que 0');
      if (!vistos.add(l.producto!)) return setState(() => _err = 'Hay un producto repetido en la receta');
      recetas.add({'producto_id': l.producto, 'cantidad': c});
    }
    Navigator.pop(context, {
      'articulo': {
        'nombre': _nombre.text.trim(),
        'unidad': _unidad,
        'minimo': minimo,
        'coste': coste,
        'proveedor_id': _proveedor,
        if (a == null && inicial != 0) 'stock': inicial,
      },
      'recetas': recetas,
      if (_vender) 'vender': {'grupo_id': _grupo, 'precio_venta': precio, 'tipo_iva': _iva},
    });
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: a == null ? 'Nuevo artículo' : 'Editar artículo',
        boton: 'Guardar artículo',
        onBoton: _guardar,
        onBorrar: a == null ? null : () => Navigator.pop(context, {'_borrar': true}),
        textoBorrar: 'Quitar artículo',
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const EtiquetaCampo('Nombre'),
          TextField(
            controller: _nombre,
            autofocus: a == null,
            decoration: const InputDecoration(hintText: 'Ej. Coca-Cola 33 cl, Barril Keler 30 l, Jamón'),
          ),
          const EtiquetaCampo('Se cuenta en'),
          Segmentos(opciones: unidades, actual: _unidad, onCambio: (v) => setState(() => _unidad = v)),
          const EtiquetaCampo('Proveedor'),
          DropdownButtonFormField<String?>(
            initialValue: _proveedor,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: null, child: Text('Sin proveedor')),
              for (final p in widget.proveedores) DropdownMenuItem(value: p['id'] as String, child: Text(p['nombre'] as String)),
            ],
            onChanged: (v) => setState(() => _proveedor = v),
          ),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                EtiquetaCampo('Mínimo ($_unidad)'),
                TextField(
                  controller: _minimo,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(hintText: 'Avisa al llegar aquí'),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                EtiquetaCampo('Coste por $_unidad (sin IVA)'),
                TextField(
                  controller: _coste,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(hintText: '0,00', suffixText: '€'),
                ),
              ]),
            ),
          ]),
          if (a == null) ...[
            EtiquetaCampo('Hay ahora ($_unidad)'),
            TextField(
              controller: _inicial,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(hintText: 'Stock inicial'),
            ),
          ],
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _vender,
            onChanged: (v) => setState(() => _vender = v),
            title: Text(a == null ? 'Venderlo también en la Barra' : 'Crear un producto nuevo en la Carta con él',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Crea el producto en la Carta y cada venta resta 1 del stock'),
          ),
          if (_vender) ...[
            const EtiquetaCampo('Grupo de la carta'),
            DropdownButtonFormField<String>(
              initialValue: _grupo,
              isExpanded: true,
              items: [
                for (final g in widget.grupos) DropdownMenuItem(value: g['id'] as String, child: Text(g['nombre'] as String)),
              ],
              onChanged: (v) => setState(() => _grupo = v),
            ),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const EtiquetaCampo('Precio de venta (IVA incl.)'),
                  TextField(
                    controller: _precio,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(hintText: '2,50', suffixText: '€'),
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const EtiquetaCampo('IVA'),
                  Segmentos(
                    opciones: const {'10': '10 %', '21': '21 %'},
                    actual: _iva.toStringAsFixed(0),
                    onCambio: (v) => setState(() => _iva = double.parse(v)),
                  ),
                ]),
              ),
            ]),
          ],
          const SizedBox(height: 18),
          Text(_vender ? 'Otros productos que lo gastan' : 'Se descuenta al vender', style: titulo(18)),
          const SizedBox(height: 4),
          Text('Cuánto gasta de este artículo cada unidad vendida de la carta (en $_unidad). '
              'Ej.: Coca-Cola → 1; Cubata de ginebra → 0,05 l.',
              style: const TextStyle(color: C.gris, fontSize: 13)),
          const SizedBox(height: 10),
          for (final l in _lineas)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    initialValue: l.producto,
                    isExpanded: true,
                    menuMaxHeight: 420,
                    hint: const Text('Producto de la carta'),
                    items: [
                      for (final p in widget.productos)
                        DropdownMenuItem(value: p['id'] as String, child: Text(p['nombre'] as String, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => l.producto = v),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: l.ctrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(suffixText: _unidad),
                  ),
                ),
                IconButton(
                  tooltip: 'Quitar',
                  onPressed: () => setState(() => _lineas.remove(l)),
                  icon: const Icon(Icons.close, color: C.gris),
                ),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _lineas.add(_LineaReceta(null, null))),
              icon: const Icon(Icons.add),
              label: const Text('Añadir producto'),
            ),
          ),
          _error(_err),
        ]),
      );
}

// =====================================================================
// Entrada de mercancía (un albarán: varias líneas)
// =====================================================================

Future<bool> apuntarEntrada(BuildContext context, List<Map<String, dynamic>> articulos) async {
  if (articulos.isEmpty) throw 'Crea primero los artículos';
  final filas = await mostrarPanel<List<Map<String, dynamic>>>(context, (_) => _PanelEntrada(articulos: articulos));
  if (filas == null || filas.isEmpty) return false;
  await supabase.from('movimientos_stock').insert(filas);
  return true;
}

class _LineaEntrada {
  String? articulo;
  final cantidad = TextEditingController();
  final coste = TextEditingController();
}

class _PanelEntrada extends StatefulWidget {
  const _PanelEntrada({required this.articulos});
  final List<Map<String, dynamic>> articulos;

  @override
  State<_PanelEntrada> createState() => _PanelEntradaState();
}

class _PanelEntradaState extends State<_PanelEntrada> {
  final _lineas = [_LineaEntrada()];
  final _nota = TextEditingController();
  String? _err;

  void _guardar() {
    final filas = <Map<String, dynamic>>[];
    for (final l in _lineas) {
      if (l.articulo == null && l.cantidad.text.trim().isEmpty) continue;
      final c = leerNumero(l.cantidad.text);
      final coste = l.coste.text.trim().isEmpty ? null : leerNumero(l.coste.text);
      if (l.articulo == null || c == null || c <= 0) return setState(() => _err = 'Cada línea necesita artículo y cantidad');
      if (l.coste.text.trim().isNotEmpty && (coste == null || coste < 0)) return setState(() => _err = 'Revisa los precios');
      filas.add({
        'articulo_id': l.articulo,
        'tipo': 'entrada',
        'cantidad': c,
        'coste': ?coste,
        if (_nota.text.trim().isNotEmpty) 'nota': _nota.text.trim(),
      });
    }
    if (filas.isEmpty) return setState(() => _err = 'Añade al menos una línea');
    Navigator.pop(context, filas);
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: 'Entrada de mercancía',
        boton: 'Guardar entrada',
        onBoton: _guardar,
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Lo que llega en el albarán. El precio (sin IVA, por unidad) es opcional: si lo pones, '
              'queda como coste del artículo.', style: TextStyle(color: C.gris, fontSize: 13)),
          const SizedBox(height: 12),
          for (final l in _lineas)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(border: Border.all(color: C.borde), borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Row(children: [
                  Expanded(child: _selectorArticulo(widget.articulos, l.articulo, (v) => setState(() => l.articulo = v))),
                  if (_lineas.length > 1)
                    IconButton(onPressed: () => setState(() => _lineas.remove(l)), icon: const Icon(Icons.close, color: C.gris)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: l.cantidad,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Cantidad', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: l.coste,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Precio/ud', suffixText: '€', isDense: true),
                    ),
                  ),
                ]),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _lineas.add(_LineaEntrada())),
              icon: const Icon(Icons.add),
              label: const Text('Otra línea'),
            ),
          ),
          const EtiquetaCampo('Nota'),
          TextField(controller: _nota, decoration: const InputDecoration(hintText: 'Nº de albarán, proveedor… (opcional)')),
          _error(_err),
        ]),
      );
}

// =====================================================================
// Merma: rotura, caducado, invitación…
// =====================================================================

Future<bool> apuntarMerma(BuildContext context, List<Map<String, dynamic>> articulos) async {
  if (articulos.isEmpty) throw 'Crea primero los artículos';
  final fila = await mostrarPanel<Map<String, dynamic>>(context, (_) => _PanelMerma(articulos: articulos));
  if (fila == null) return false;
  await supabase.from('movimientos_stock').insert(fila);
  return true;
}

class _PanelMerma extends StatefulWidget {
  const _PanelMerma({required this.articulos});
  final List<Map<String, dynamic>> articulos;

  @override
  State<_PanelMerma> createState() => _PanelMermaState();
}

class _PanelMermaState extends State<_PanelMerma> {
  String? _articulo;
  final _cantidad = TextEditingController();
  String _motivo = 'Rotura';
  String? _err;

  void _guardar() {
    final c = leerNumero(_cantidad.text);
    if (_articulo == null || c == null || c <= 0) return setState(() => _err = 'Elige el artículo y la cantidad');
    Navigator.pop(context, {'articulo_id': _articulo, 'tipo': 'merma', 'cantidad': -c, 'nota': _motivo});
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: 'Merma',
        boton: 'Guardar merma',
        onBoton: _guardar,
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const EtiquetaCampo('Artículo'),
          _selectorArticulo(widget.articulos, _articulo, (v) => setState(() => _articulo = v)),
          const EtiquetaCampo('Cantidad que se pierde'),
          TextField(controller: _cantidad, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const EtiquetaCampo('Motivo'),
          Segmentos(
            opciones: const {'Rotura': 'Rotura', 'Caducado': 'Caducado', 'Invitación': 'Invitación', 'Otro': 'Otro'},
            actual: _motivo,
            onCambio: (v) => setState(() => _motivo = v),
          ),
          _error(_err),
        ]),
      );
}

// =====================================================================
// Recuento: se apunta lo que hay de verdad y se corrige la diferencia
// =====================================================================

Future<bool> hacerRecuento(BuildContext context, List<Map<String, dynamic>> articulos) async {
  if (articulos.isEmpty) throw 'Crea primero los artículos';
  final filas = await mostrarPanel<List<Map<String, dynamic>>>(context, (_) => _PanelRecuento(articulos: articulos));
  if (filas == null || filas.isEmpty) return false;
  await supabase.from('movimientos_stock').insert(filas);
  return true;
}

class _PanelRecuento extends StatefulWidget {
  const _PanelRecuento({required this.articulos});
  final List<Map<String, dynamic>> articulos;

  @override
  State<_PanelRecuento> createState() => _PanelRecuentoState();
}

class _PanelRecuentoState extends State<_PanelRecuento> {
  late final _campos = {for (final a in widget.articulos) a['id'] as String: TextEditingController()};
  String? _err;

  void _guardar() {
    final filas = <Map<String, dynamic>>[];
    for (final a in widget.articulos) {
      final t = _campos[a['id']]!.text;
      if (t.trim().isEmpty) continue;
      final real = leerNumero(t);
      if (real == null || real < 0) return setState(() => _err = 'Revisa la cantidad de ${a['nombre']}');
      final sistema = num0(a['stock']);
      final dif = double.parse((real - sistema).toStringAsFixed(3));
      if (dif == 0) continue;
      filas.add({
        'articulo_id': a['id'],
        'tipo': 'recuento',
        'cantidad': dif,
        'nota': 'Contado ${cantidad(real)}, el sistema decía ${cantidad(sistema)}',
      });
    }
    Navigator.pop(context, filas);
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: 'Recuento',
        boton: 'Guardar recuento',
        onBoton: _guardar,
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Cuenta lo que hay y escríbelo. Lo que dejes vacío no se toca.',
              style: TextStyle(color: C.gris, fontSize: 13)),
          const SizedBox(height: 12),
          for (final a in widget.articulos)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a['nombre'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('El sistema dice ${conUnidad(num0(a['stock']), a['unidad'] as String)}',
                        style: const TextStyle(color: C.gris, fontSize: 12)),
                  ]),
                ),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _campos[a['id']],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(hintText: 'Hay', suffixText: a['unidad'] as String, isDense: true),
                  ),
                ),
              ]),
            ),
          _error(_err),
        ]),
      );
}
