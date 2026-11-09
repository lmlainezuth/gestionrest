import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';

/// Clientes para facturas con NIF.
class ClientesTab extends StatefulWidget {
  const ClientesTab({super.key});

  @override
  State<ClientesTab> createState() => _ClientesTabState();
}

class _ClientesTabState extends State<ClientesTab> {
  List<Map<String, dynamic>> _clientes = [];
  String _buscar = '';
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    _clientes = List<Map<String, dynamic>>.from(await supabase.from('clientes').select().eq('activo', true).order('nombre'));
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _editar([Map<String, dynamic>? c]) async {
    final r = await editarCliente(context, c);
    if (r != null) await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final t = _buscar.toLowerCase();
    final lista = _clientes
        .where((c) => '${c['nombre']} ${c['documento'] ?? ''}'.toLowerCase().contains(t))
        .toList();
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(children: [
          Expanded(
            child: TextField(
              onChanged: (v) => setState(() => _buscar = v),
              decoration: const InputDecoration(hintText: 'Buscar por nombre o NIF', prefixIcon: Icon(Icons.search), isDense: true),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(onPressed: _editar, icon: const Icon(Icons.person_add_alt), label: const Text('Nuevo cliente')),
        ]),
        const SizedBox(height: 16),
        if (lista.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Sin clientes', style: TextStyle(color: C.gris))),
        for (final c in lista)
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(c['nombre'] as String),
            subtitle: Text([c['documento'], c['direccion']].where((x) => x != null && '$x'.isNotEmpty).join(' · ')),
            onTap: () => _editar(c),
          ),
      ],
    );
  }
}

/// Diálogo de alta/edición de cliente. Devuelve el cliente guardado.
Future<Map<String, dynamic>?> editarCliente(BuildContext context, [Map<String, dynamic>? c]) async {
  final nombre = TextEditingController(text: c?['nombre'] as String?);
  final nif = TextEditingController(text: c?['documento'] as String?);
  final telefono = TextEditingController(text: c?['telefono'] as String?);
  final direccion = TextEditingController(text: c?['direccion'] as String?);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(c == null ? 'Nuevo cliente' : 'Editar cliente'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nombre, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre o razón social')),
            const SizedBox(height: 12),
            TextField(controller: nif, decoration: const InputDecoration(labelText: 'NIF / CIF')),
            const SizedBox(height: 12),
            TextField(controller: direccion, decoration: const InputDecoration(labelText: 'Dirección')),
            const SizedBox(height: 12),
            TextField(controller: telefono, decoration: const InputDecoration(labelText: 'Teléfono (opcional)')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
      ],
    ),
  );
  if (ok != true || nombre.text.trim().isEmpty) return null;
  final datos = {
    'nombre': nombre.text.trim(),
    'documento': nif.text.trim().toUpperCase(),
    'direccion': direccion.text.trim(),
    'telefono': telefono.text.trim(),
  };
  try {
    return c == null
        ? await supabase.from('clientes').insert(datos).select().single()
        : await supabase.from('clientes').update(datos).eq('id', c['id']).select().single();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    return null;
  }
}
