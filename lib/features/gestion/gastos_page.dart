import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/modelos.dart' show euros;
import 'comun.dart';
import 'proveedores_page.dart' show editarProveedor;

const _rojo = Color(0xFFB3261E);
const _rojoSuave = Color(0xFFFBE9E7);
const _ambar = Color(0xFFB45309);
const _ambarSuave = Color(0xFFFDF0DC);
const _verdeSuave = Color(0xFFE3F1EC);

String _diaCorto(String isoFecha) {
  final d = DateTime.parse(isoFecha);
  return '${d.day} ${meses[d.month - 1].substring(0, 3)}';
}

double _imp(Map<String, dynamic> g) => (g['importe'] as num).toDouble();

/// Facturas de gastos: fijos sueltos y compras agrupadas por proveedor.
class GastosPage extends StatefulWidget {
  const GastosPage({super.key});

  @override
  State<GastosPage> createState() => _GastosPageState();
}

class _GastosPageState extends State<GastosPage> {
  DateTime _mes = DateTime.now();
  String _filtro = 'todos'; // todos | fijos | materia | otros | debe
  List<Map<String, dynamic>> _gastos = [];
  List<Map<String, dynamic>> _provs = [];
  final Set<String> _abiertos = {};
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final (desde, hasta) = rangoMes(_mes);
    var q = supabase.from('gastos').select('*, proveedores(nombre)');
    // "Debe" enseña todo lo pendiente, sea del mes que sea
    q = _filtro == 'debe' ? q.eq('estado', 'pendiente') : q.gte('fecha', desde).lte('fecha', hasta);
    _gastos = List<Map<String, dynamic>>.from(await q.order('fecha', ascending: false));
    _provs = List<Map<String, dynamic>>.from(await supabase.from('proveedores').select().order('nombre'));
    if (mounted) setState(() => _cargando = false);
  }

  void _cambiarFiltro(String f) {
    final recargar = f == 'debe' || _filtro == 'debe';
    setState(() => _filtro = f);
    if (recargar) _cargar();
  }

  Future<void> _pagado(Map<String, dynamic> g) async {
    await supabase.from('gastos').update({'estado': 'registrado'}).eq('id', g['id']);
    await _cargar();
  }

  /// Formulario en un panel lateral (a pantalla completa en pantallas estrechas).
  Future<void> _editar([Map<String, dynamic>? g]) async {
    final r = await showGeneralDialog<_ResultadoGasto>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, _, __) => _PanelGasto(gasto: g, proveedores: _provs),
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
    if (r == null) return;
    try {
      if (r.borrar) {
        await supabase.from('gastos').delete().eq('id', g!['id']);
      } else {
        g == null
            ? await supabase.from('gastos').insert(r.datos!)
            : await supabase.from('gastos').update(r.datos!).eq('id', g['id']);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final visibles = switch (_filtro) {
      'fijos' || 'materia' || 'otros' => _gastos.where((g) => g['categoria'] == _filtro).toList(),
      _ => _gastos,
    };
    final total = visibles.fold(0.0, (s, g) => s + _imp(g));
    final iva = visibles.fold(0.0, (s, g) => s + ivaGasto(g));
    final pendiente = visibles.where((g) => g['estado'] == 'pendiente').fold(0.0, (s, g) => s + _imp(g));

    // Compras agrupadas por proveedor; los gastos sin proveedor van sueltos
    final grupos = <String, List<Map<String, dynamic>>>{};
    final sueltos = <Map<String, dynamic>>[];
    for (final g in visibles) {
      final id = g['proveedor_id'] as String?;
      id == null ? sueltos.add(g) : (grupos[id] ??= []).add(g);
    }
    final filas = <({String fecha, Widget widget})>[
      for (final g in sueltos) (fecha: g['fecha'] as String, widget: _FilaGasto(g, onTap: () => _editar(g), onPagado: () => _pagado(g))),
      for (final e in grupos.entries)
        (
          fecha: e.value.first['fecha'] as String,
          widget: _FilaProveedor(
            nombre: ((e.value.first['proveedores'] as Map?)?['nombre'] as String?) ?? 'Proveedor',
            facturas: e.value,
            abierto: _abiertos.contains(e.key),
            onToggle: () => setState(() => _abiertos.contains(e.key) ? _abiertos.remove(e.key) : _abiertos.add(e.key)),
            onEditar: _editar,
            onPagado: _pagado,
          ),
        ),
    ]..sort((a, b) => b.fecha.compareTo(a.fecha));

    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Row(children: [
          if (_filtro != 'debe')
            SelectorMes(mes: _mes, onCambio: (m) {
              _mes = m;
              _cargar();
            })
          else
            Text('Todo lo pendiente de pago', style: titulo(18)),
          const Spacer(),
          FilledButton.icon(
            onPressed: () => _editar(),
            icon: const Icon(Icons.add),
            label: const Text('Añadir gasto'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
          ),
        ]),
        const SizedBox(height: 18),
        // Tarjeta resumen
        Container(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          decoration: BoxDecoration(color: _rojoSuave, borderRadius: BorderRadius.circular(18)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_filtro == 'debe' ? 'Pendiente de pago' : 'Registrado este mes',
                    style: const TextStyle(color: C.gris, fontSize: 14)),
                const SizedBox(height: 4),
                Text(euros(total), style: titulo(34, color: _rojo)),
                const SizedBox(height: 4),
                Text(
                  '${visibles.length} ${visibles.length == 1 ? 'factura' : 'facturas'} · IVA soportado ${euros(iva)}'
                  '${pendiente > 0 && _filtro != 'debe' ? ' · se debe ${euros(pendiente)}' : ''}',
                  style: const TextStyle(color: C.gris, fontSize: 13),
                ),
              ]),
            ),
            const Icon(Icons.receipt_long_outlined, color: _rojo, size: 34),
          ]),
        ),
        const SizedBox(height: 16),
        // Filtros
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in const {'todos': 'Todos', 'fijos': 'Fijos', 'materia': 'Materia prima', 'otros': 'Otros', 'debe': 'Debe'}.entries)
            ChoiceChip(
              label: Text(f.value),
              selected: _filtro == f.key,
              showCheckmark: false,
              selectedColor: C.verde,
              labelStyle: TextStyle(
                color: _filtro == f.key ? Colors.white : C.tinta,
                fontWeight: FontWeight.w600,
              ),
              backgroundColor: C.blanco,
              side: BorderSide(color: _filtro == f.key ? C.verde : C.borde),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              onSelected: (_) => _cambiarFiltro(f.key),
            ),
        ]),
        const SizedBox(height: 16),
        if (_cargando) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_cargando && filas.isEmpty)
          Container(
            padding: const EdgeInsets.all(30),
            alignment: Alignment.center,
            child: Text(_filtro == 'debe' ? 'No debes nada. ✅' : 'Sin gastos este mes.', style: const TextStyle(color: C.gris)),
          ),
        for (final f in filas) Padding(padding: const EdgeInsets.only(bottom: 10), child: f.widget),
      ],
    );
  }
}

// ---------- Filas de la lista ----------

class _Tarjeta extends StatelessWidget {
  const _Tarjeta({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: C.blanco,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
            child: child,
          ),
        ),
      );
}

class _Icono extends StatelessWidget {
  const _Icono(this.icono, this.color);
  final IconData icono;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
        child: Icon(icono, color: color),
      );
}

class _Estado extends StatelessWidget {
  const _Estado(this.texto, {required this.debe});
  final String texto;
  final bool debe;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: debe ? _ambarSuave : _verdeSuave, borderRadius: BorderRadius.circular(8)),
        child: Text(texto, style: TextStyle(color: debe ? _ambar : C.verde, fontWeight: FontWeight.w700, fontSize: 12.5)),
      );
}

IconData _iconoCategoria(String c) => switch (c) {
      'fijos' => Icons.home_outlined,
      'materia' => Icons.inventory_2_outlined,
      _ => Icons.sell_outlined,
    };

class _FilaGasto extends StatelessWidget {
  const _FilaGasto(this.g, {required this.onTap, required this.onPagado});
  final Map<String, dynamic> g;
  final VoidCallback onTap, onPagado;

  @override
  Widget build(BuildContext context) {
    final debe = g['estado'] == 'pendiente';
    final cat = g['categoria'] as String;
    return _Tarjeta(
      onTap: onTap,
      child: Row(children: [
        _Icono(_iconoCategoria(cat), coloresCategoria[cat] ?? C.gris),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(g['concepto'] as String, style: titulo(17), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text('${_diaCorto(g['fecha'] as String)} · ${categorias[cat]}', style: const TextStyle(color: C.gris, fontSize: 13)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(euros(_imp(g)), style: titulo(18)),
          const SizedBox(height: 4),
          debe
              ? InkWell(onTap: onPagado, child: const _Estado('Debe · marcar pagado', debe: true))
              : const _Estado('Pagado', debe: false),
        ]),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right, color: C.gris),
      ]),
    );
  }
}

class _FilaProveedor extends StatelessWidget {
  const _FilaProveedor({
    required this.nombre,
    required this.facturas,
    required this.abierto,
    required this.onToggle,
    required this.onEditar,
    required this.onPagado,
  });
  final String nombre;
  final List<Map<String, dynamic>> facturas;
  final bool abierto;
  final VoidCallback onToggle;
  final void Function(Map<String, dynamic>) onEditar, onPagado;

  @override
  Widget build(BuildContext context) {
    final total = facturas.fold(0.0, (s, g) => s + _imp(g));
    final debe = facturas.where((g) => g['estado'] == 'pendiente').fold(0.0, (s, g) => s + _imp(g));
    final n = facturas.length;
    return _Tarjeta(
      onTap: onToggle,
      child: Column(children: [
        Row(children: [
          const _Icono(Icons.local_shipping_outlined, C.verde),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(nombre, style: titulo(17), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('$n ${n == 1 ? 'factura' : 'facturas'} · última ${_diaCorto(facturas.first['fecha'] as String)}',
                  style: const TextStyle(color: C.gris, fontSize: 13)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(euros(total), style: titulo(18)),
            const SizedBox(height: 4),
            debe > 0 ? _Estado('Debe ${euros(debe)}', debe: true) : const _Estado('Pagado', debe: false),
          ]),
          const SizedBox(width: 4),
          Icon(abierto ? Icons.expand_less : Icons.expand_more, color: C.gris),
        ]),
        if (abierto) ...[
          const SizedBox(height: 8),
          const Divider(height: 1, color: C.borde),
          for (final g in facturas)
            InkWell(
              onTap: () => onEditar(g),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(60, 10, 30, 10),
                child: Row(children: [
                  Expanded(
                    child: Text('${_diaCorto(g['fecha'] as String)} · ${g['concepto']}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  if (g['estado'] == 'pendiente')
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: InkWell(onTap: () => onPagado(g), child: const _Estado('Marcar pagado', debe: true)),
                    ),
                  Text(euros(_imp(g)), style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
        ],
      ]),
    );
  }
}

// ---------- Panel lateral del formulario ----------

class _ResultadoGasto {
  const _ResultadoGasto({this.datos, this.borrar = false});
  final Map<String, dynamic>? datos;
  final bool borrar;
}

class _PanelGasto extends StatefulWidget {
  const _PanelGasto({required this.gasto, required this.proveedores});
  final Map<String, dynamic>? gasto;
  final List<Map<String, dynamic>> proveedores;

  @override
  State<_PanelGasto> createState() => _PanelGastoState();
}

class _PanelGastoState extends State<_PanelGasto> {
  late final g = widget.gasto;
  late DateTime _fecha = g == null ? DateTime.now() : DateTime.parse(g!['fecha'] as String);
  static String _f(num? v) => v == null ? '' : v.toStringAsFixed(2).replaceAll('.', ',');
  late final _concepto = TextEditingController(text: g?['concepto'] as String?);
  late final _importe = TextEditingController(text: _f(g?['importe'] as num?));
  late final _ivaImp = TextEditingController(text: _f(g?['iva_importe'] as num?));
  late String? _proveedor = g?['proveedor_id'] as String?;
  late String _categoria = (g?['categoria'] as String?) ?? 'materia';
  late String _iva = (g?['iva_tipo'] as String?) ?? '10';
  late String _estado = (g?['estado'] as String?) ?? 'registrado';
  String? _error;

  Widget _etiqueta(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      );

  Widget _segmentos(Map<String, String> opciones, String actual, ValueChanged<String> onCambio) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: C.crema, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          for (final o in opciones.entries)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onCambio(o.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: actual == o.key ? C.blanco : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: actual == o.key ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))] : null,
                  ),
                  child: Text(o.value,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: actual == o.key ? C.verde : C.gris,
                      )),
                ),
              ),
            ),
        ]),
      );

  String get _textoIva {
    final total = leerImporte(_importe.text);
    if (_iva == 'mixto') return 'Escribe abajo el IVA total que pone la factura.';
    if (total == null || total <= 0) return 'El IVA se calcula al escribir el importe.';
    final t = double.parse(_iva);
    return 'IVA incluido ($_iva %): ${euros(total * t / (100 + t))}';
  }

  void _guardar() {
    final imp = leerImporte(_importe.text);
    if (_concepto.text.trim().isEmpty || imp == null || imp < 0) {
      setState(() => _error = 'Escribe el concepto y el importe');
      return;
    }
    final vi = leerImporte(_ivaImp.text);
    if (_iva == 'mixto' && (vi == null || vi < 0 || vi >= imp)) {
      setState(() => _error = 'Escribe el IVA total que aparece al pie de la factura');
      return;
    }
    Navigator.pop(
      context,
      _ResultadoGasto(datos: {
        'proveedor_id': _proveedor,
        'fecha': iso(_fecha),
        'concepto': _concepto.text.trim(),
        'importe': imp,
        'categoria': _categoria,
        'iva_tipo': _iva,
        'iva_importe': _iva == 'mixto' ? vi : null,
        'estado': _estado,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ancho = MediaQuery.sizeOf(context).width;
    final provs = widget.proveedores;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: C.blanco,
        child: SizedBox(
          width: ancho < 600 ? ancho : 440,
          height: double.infinity,
          child: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 12, 4),
                child: Row(children: [
                  Expanded(child: Text(g == null ? 'Añadir gasto' : 'Editar gasto', style: titulo(26))),
                  IconButton(tooltip: 'Cerrar', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ]),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: [
                    _etiqueta('Concepto'),
                    TextField(
                      controller: _concepto,
                      autofocus: g == null,
                      decoration: const InputDecoration(hintText: 'Ej. Bebidas, alquiler, luz'),
                    ),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _etiqueta('Importe total'),
                          TextField(
                            controller: _importe,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(hintText: '0,00', suffixText: '€'),
                          ),
                        ]),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _etiqueta('Fecha'),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              alignment: Alignment.centerLeft,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () async {
                              final d = await showDatePicker(
                                  context: context, initialDate: _fecha, firstDate: DateTime(2023), lastDate: DateTime.now());
                              if (d != null) setState(() => _fecha = d);
                            },
                            icon: const Icon(Icons.calendar_today_outlined, size: 18),
                            label: Text('${_fecha.day} ${meses[_fecha.month - 1].substring(0, 3)} ${_fecha.year}'),
                          ),
                        ]),
                      ),
                    ]),
                    _etiqueta('Proveedor'),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          initialValue: _proveedor,
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem(value: null, child: Text('Sin proveedor')),
                            for (final p in provs) DropdownMenuItem(value: p['id'] as String, child: Text(p['nombre'] as String)),
                          ],
                          onChanged: (v) => setState(() {
                            _proveedor = v;
                            final p = provs.where((x) => x['id'] == v).firstOrNull;
                            if (p != null) {
                              _iva = p['iva_habitual'] as String;
                              _categoria = 'materia';
                            }
                          }),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Nuevo proveedor',
                        onPressed: () async {
                          final nuevo = await editarProveedor(context);
                          if (nuevo != null) {
                            provs.add(nuevo);
                            setState(() {
                              _proveedor = nuevo['id'] as String;
                              _iva = nuevo['iva_habitual'] as String;
                            });
                          }
                        },
                        icon: const Icon(Icons.add_business_outlined),
                      ),
                    ]),
                    _etiqueta('Categoría'),
                    _segmentos(const {'fijos': 'Fijos', 'materia': 'Mat. prima', 'otros': 'Otros'}, _categoria,
                        (v) => setState(() => _categoria = v)),
                    _etiqueta('IVA de la factura'),
                    _segmentos({for (final t in tiposIva) t: t == 'mixto' ? 'Mixto' : '$t %'}, _iva, (v) => setState(() => _iva = v)),
                    const SizedBox(height: 8),
                    Text(_textoIva, style: const TextStyle(color: C.gris, fontSize: 13)),
                    if (_iva == 'mixto') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _ivaImp,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'IVA total de la factura', suffixText: '€'),
                      ),
                    ],
                    _etiqueta('Estado'),
                    _segmentos(const {'registrado': 'Pagado', 'pendiente': 'Debe'}, _estado, (v) => setState(() => _estado = v)),
                    const SizedBox(height: 8),
                    const Text(
                      'Los dos cuentan como gasto del mes. «Debe» queda en lo que le debes al proveedor hasta que lo marques como pagado.',
                      style: TextStyle(color: C.gris, fontSize: 13),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: _rojo, fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
                child: Column(children: [
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                    onPressed: _guardar,
                    child: Text(g == null ? 'Guardar gasto' : 'Guardar cambios', style: const TextStyle(fontSize: 16)),
                  ),
                  if (g != null)
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context, const _ResultadoGasto(borrar: true)),
                      icon: const Icon(Icons.delete_outline, color: _rojo),
                      label: const Text('Borrar gasto', style: TextStyle(color: _rojo)),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
