import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/panel_lateral.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/modelos.dart' show euros;
import 'comun.dart';

/// Proveedores: lo comprado este mes y lo que se les debe.
class ProveedoresPage extends StatefulWidget {
  const ProveedoresPage({super.key});

  @override
  State<ProveedoresPage> createState() => _ProveedoresPageState();
}

class _ProveedoresPageState extends State<ProveedoresPage> {
  List<Map<String, dynamic>> _provs = [];
  Map<String, double> _debe = {};
  Map<String, double> _mes = {};
  String _buscar = '';
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

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
    final (desde, hasta) = rangoMes(DateTime.now());
    final r = await Future.wait([
      supabase.from('proveedores').select().order('nombre'),
      supabase.from('gastos').select('proveedor_id, importe').eq('estado', 'pendiente'),
      supabase.from('gastos').select('proveedor_id, importe').gte('fecha', desde).lte('fecha', hasta),
    ]);
    _provs = List<Map<String, dynamic>>.from(r[0]);
    Map<String, double> sumar(List<dynamic> filas) {
      final m = <String, double>{};
      for (final g in filas) {
        final k = g['proveedor_id'] as String?;
        if (k != null) m[k] = (m[k] ?? 0) + (g['importe'] as num).toDouble();
      }
      return m;
    }

    _debe = sumar(r[1]);
    _mes = sumar(r[2]);
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _editar([Map<String, dynamic>? p]) async {
    final r = await editarProveedor(context, p);
    if (r != null) await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final t = _buscar.toLowerCase();
    final lista = _provs.where((p) => '${p['nombre']} ${p['suministra'] ?? ''}'.toLowerCase().contains(t)).toList()
      ..sort((a, b) => (_debe[b['id']] ?? 0).compareTo(_debe[a['id']] ?? 0));
    final totalDebe = _debe.values.fold(0.0, (a, b) => a + b);
    final totalMes = _mes.values.fold(0.0, (a, b) => a + b);
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Row(children: [
          Expanded(
            child: TextField(
              onChanged: (v) => setState(() => _buscar = v),
              decoration: const InputDecoration(hintText: 'Buscar proveedor', prefixIcon: Icon(Icons.search), isDense: true),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _editar,
            icon: const Icon(Icons.add),
            label: const Text('Nuevo proveedor'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
          ),
        ]),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          decoration: BoxDecoration(color: const Color(0xFFFDF0DC), borderRadius: BorderRadius.circular(18)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Les debes en total', style: TextStyle(color: C.gris, fontSize: 14)),
                const SizedBox(height: 4),
                Text(euros(totalDebe), style: titulo(34, color: const Color(0xFFB45309))),
                const SizedBox(height: 4),
                Text('${_provs.length} proveedores · compras este mes ${euros(totalMes)}',
                    style: const TextStyle(color: C.gris, fontSize: 13)),
              ]),
            ),
            const Icon(Icons.local_shipping_outlined, color: Color(0xFFB45309), size: 34),
          ]),
        ),
        const SizedBox(height: 16),
        if (lista.isEmpty)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Sin proveedores', style: TextStyle(color: C.gris)))),
        for (final p in lista)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TarjetaFila(
              onTap: () => _editar(p),
              child: Row(children: [
                const IconoFila(Icons.local_shipping_outlined, C.verde),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p['nombre'] as String, style: titulo(17), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      [
                        if ((p['suministra'] as String?)?.isNotEmpty ?? false) p['suministra'],
                        if ((p['telefono'] as String?)?.isNotEmpty ?? false) p['telefono'],
                        'IVA ${p['iva_habitual'] == 'mixto' ? 'mixto' : '${p['iva_habitual']} %'}',
                      ].join(' · '),
                      style: const TextStyle(color: C.gris, fontSize: 13),
                    ),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(euros(_mes[p['id']] ?? 0), style: titulo(18)),
                  const Text('este mes', style: TextStyle(color: C.gris, fontSize: 11)),
                  const SizedBox(height: 4),
                  (_debe[p['id']] ?? 0) > 0
                      ? EtiquetaEstado('Debe ${euros(_debe[p['id']]!)}', aviso: true)
                      : const EtiquetaEstado('Todo pagado', aviso: false),
                ]),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: C.gris),
              ]),
            ),
          ),
      ],
    );
  }
}

/// Alta/edición de proveedor en panel lateral. Devuelve el proveedor guardado (o el borrado).
Future<Map<String, dynamic>?> editarProveedor(BuildContext context, [Map<String, dynamic>? p]) async {
  final datos = await mostrarPanel<Map<String, dynamic>>(context, (_) => _PanelProveedor(proveedor: p));
  if (datos == null) return null;
  try {
    if (datos['_borrar'] == true) {
      await supabase.from('proveedores').delete().eq('id', p!['id']);
      return p;
    }
    return p == null
        ? await supabase.from('proveedores').insert(datos).select().single()
        : await supabase.from('proveedores').update(datos).eq('id', p['id']).select().single();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    return null;
  }
}

class _PanelProveedor extends StatefulWidget {
  const _PanelProveedor({required this.proveedor});
  final Map<String, dynamic>? proveedor;

  @override
  State<_PanelProveedor> createState() => _PanelProveedorState();
}

class _PanelProveedorState extends State<_PanelProveedor> {
  late final p = widget.proveedor;
  late final _nombre = TextEditingController(text: p?['nombre'] as String?);
  late final _suministra = TextEditingController(text: p?['suministra'] as String?);
  late final _telefono = TextEditingController(text: p?['telefono'] as String?);
  late String _iva = (p?['iva_habitual'] as String?) ?? '10';
  String? _error;

  void _guardar() {
    if (_nombre.text.trim().isEmpty) {
      setState(() => _error = 'Escribe el nombre del proveedor');
      return;
    }
    Navigator.pop(context, {
      'nombre': _nombre.text.trim(),
      'suministra': _suministra.text.trim(),
      'telefono': _telefono.text.trim(),
      'iva_habitual': _iva,
    });
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: p == null ? 'Nuevo proveedor' : 'Editar proveedor',
        boton: 'Guardar proveedor',
        onBoton: _guardar,
        onBorrar: p == null ? null : () => Navigator.pop(context, {'_borrar': true}),
        textoBorrar: 'Borrar proveedor',
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const EtiquetaCampo('Nombre'),
          TextField(controller: _nombre, autofocus: p == null, decoration: const InputDecoration(hintText: 'Ej. Keller, Monbake')),
          const EtiquetaCampo('Qué suministra'),
          TextField(controller: _suministra, decoration: const InputDecoration(hintText: 'Bebidas, pan, verdura…')),
          const EtiquetaCampo('Teléfono'),
          TextField(controller: _telefono, keyboardType: TextInputType.phone, decoration: const InputDecoration(hintText: 'Opcional')),
          const EtiquetaCampo('IVA habitual de sus facturas'),
          Segmentos(
            opciones: {for (final t in tiposIva) t: t == 'mixto' ? 'Mixto' : '$t %'},
            actual: _iva,
            onCambio: (v) => setState(() => _iva = v),
          ),
          const SizedBox(height: 8),
          const Text('Al apuntar un gasto de este proveedor, el IVA se pone solo.', style: TextStyle(color: C.gris, fontSize: 13)),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
          ],
        ]),
      );
}
