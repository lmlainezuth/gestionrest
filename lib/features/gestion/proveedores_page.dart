import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/modelos.dart' show euros;
import 'comun.dart';

/// Proveedores y lo que se les debe.
class ProveedoresPage extends StatefulWidget {
  const ProveedoresPage({super.key});

  @override
  State<ProveedoresPage> createState() => _ProveedoresPageState();
}

class _ProveedoresPageState extends State<ProveedoresPage> {
  List<Map<String, dynamic>> _provs = [];
  Map<String, double> _debe = {};
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    _provs = List<Map<String, dynamic>>.from(await supabase.from('proveedores').select().order('nombre'));
    final pend = await supabase.from('gastos').select('proveedor_id, importe').eq('estado', 'pendiente');
    _debe = {};
    for (final g in pend) {
      final k = g['proveedor_id'] as String?;
      if (k != null) _debe[k] = (_debe[k] ?? 0) + (g['importe'] as num).toDouble();
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _editar([Map<String, dynamic>? p]) async {
    final r = await editarProveedor(context, p);
    if (r != null) await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(children: [
          Expanded(child: Text('${_provs.length} proveedores', style: const TextStyle(color: C.gris))),
          FilledButton.icon(onPressed: _editar, icon: const Icon(Icons.add), label: const Text('Nuevo proveedor')),
        ]),
        const SizedBox(height: 16),
        for (final p in _provs)
          Card(
            elevation: 0,
            color: C.blanco,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: C.borde)),
            child: ListTile(
              onTap: () => _editar(p),
              leading: const CircleAvatar(backgroundColor: Color(0xFFE3EEEA), child: Icon(Icons.local_shipping_outlined, color: C.verde)),
              title: Text(p['nombre'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([
                if ((p['suministra'] as String?)?.isNotEmpty ?? false) p['suministra'],
                if ((p['telefono'] as String?)?.isNotEmpty ?? false) p['telefono'],
                'IVA ${p['iva_habitual'] == 'mixto' ? 'mixto' : '${p['iva_habitual']} %'}',
              ].join(' · ')),
              trailing: (_debe[p['id']] ?? 0) > 0
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      const Text('Le debes', style: TextStyle(fontSize: 12, color: C.gris)),
                      Text(euros(_debe[p['id']]!), style: titulo(18, color: C.naranja)),
                    ])
                  : null,
            ),
          ),
      ],
    );
  }
}

/// Alta/edición de proveedor. Devuelve el proveedor guardado.
Future<Map<String, dynamic>?> editarProveedor(BuildContext context, [Map<String, dynamic>? p]) async {
  final nombre = TextEditingController(text: p?['nombre'] as String?);
  final suministra = TextEditingController(text: p?['suministra'] as String?);
  final telefono = TextEditingController(text: p?['telefono'] as String?);
  var iva = (p?['iva_habitual'] as String?) ?? '10';
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(p == null ? 'Nuevo proveedor' : 'Editar proveedor'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: nombre, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre')),
            const SizedBox(height: 12),
            TextField(controller: suministra, decoration: const InputDecoration(labelText: 'Qué suministra (bebidas, verdura…)')),
            const SizedBox(height: 12),
            TextField(controller: telefono, decoration: const InputDecoration(labelText: 'Teléfono')),
            const SizedBox(height: 16),
            const Text('IVA habitual de sus facturas'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [for (final t in tiposIva) ButtonSegment(value: t, label: Text(t == 'mixto' ? 'Mixto' : '$t %'))],
              selected: {iva},
              onSelectionChanged: (s) => setD(() => iva = s.first),
            ),
          ]),
        ),
        actions: [
          if (p != null) TextButton(onPressed: () => Navigator.pop(ctx, 'borrar'), child: const Text('Borrar')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'guardar'), child: const Text('Guardar')),
        ],
      ),
    ),
  );
  try {
    if (r == 'borrar') {
      await supabase.from('proveedores').delete().eq('id', p!['id']);
      return p;
    }
    if (r != 'guardar' || nombre.text.trim().isEmpty) return null;
    final datos = {
      'nombre': nombre.text.trim(),
      'suministra': suministra.text.trim(),
      'telefono': telefono.text.trim(),
      'iva_habitual': iva,
    };
    return p == null
        ? await supabase.from('proveedores').insert(datos).select().single()
        : await supabase.from('proveedores').update(datos).eq('id', p['id']).select().single();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    return null;
  }
}
