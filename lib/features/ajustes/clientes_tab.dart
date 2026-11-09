import 'package:flutter/material.dart';

import '../../core/panel_lateral.dart';
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
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TarjetaFila(
              onTap: () => _editar(c),
              child: Row(children: [
                const IconoFila(Icons.badge_outlined, C.verde),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c['nombre'] as String, style: titulo(17), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text([c['documento'], c['direccion']].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
                        style: const TextStyle(color: C.gris, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                const Icon(Icons.chevron_right, color: C.gris),
              ]),
            ),
          ),
      ],
    );
  }
}

/// Alta/edición de cliente en panel lateral. Devuelve el cliente guardado.
Future<Map<String, dynamic>?> editarCliente(BuildContext context, [Map<String, dynamic>? c]) async {
  final datos = await mostrarPanel<Map<String, dynamic>>(context, (_) => _PanelCliente(cliente: c));
  if (datos == null) return null;
  try {
    return c == null
        ? await supabase.from('clientes').insert(datos).select().single()
        : await supabase.from('clientes').update(datos).eq('id', c['id']).select().single();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    return null;
  }
}

class _PanelCliente extends StatefulWidget {
  const _PanelCliente({required this.cliente});
  final Map<String, dynamic>? cliente;

  @override
  State<_PanelCliente> createState() => _PanelClienteState();
}

class _PanelClienteState extends State<_PanelCliente> {
  late final c = widget.cliente;
  late final _nombre = TextEditingController(text: c?['nombre'] as String?);
  late final _nif = TextEditingController(text: c?['documento'] as String?);
  late final _direccion = TextEditingController(text: c?['direccion'] as String?);
  late final _telefono = TextEditingController(text: c?['telefono'] as String?);
  String? _error;

  void _guardar() {
    if (_nombre.text.trim().isEmpty || _nif.text.trim().isEmpty) {
      setState(() => _error = 'Para facturar hacen falta el nombre y el NIF');
      return;
    }
    Navigator.pop(context, {
      'nombre': _nombre.text.trim(),
      'documento': _nif.text.trim().toUpperCase(),
      'direccion': _direccion.text.trim(),
      'telefono': _telefono.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: c == null ? 'Nuevo cliente' : 'Editar cliente',
        boton: 'Guardar cliente',
        onBoton: _guardar,
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const EtiquetaCampo('Nombre o razón social'),
          TextField(controller: _nombre, autofocus: c == null, decoration: const InputDecoration(hintText: 'Ej. Construcciones Arana S.L.')),
          const EtiquetaCampo('NIF / CIF'),
          TextField(controller: _nif, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(hintText: 'B12345678')),
          const EtiquetaCampo('Dirección'),
          TextField(controller: _direccion, maxLines: 2, decoration: const InputDecoration(hintText: 'Calle, número, CP y población')),
          const EtiquetaCampo('Teléfono'),
          TextField(controller: _telefono, keyboardType: TextInputType.phone, decoration: const InputDecoration(hintText: 'Opcional')),
          const SizedBox(height: 8),
          const Text('Estos datos salen en la factura completa (con NIF) que pide el cliente.', style: TextStyle(color: C.gris, fontSize: 13)),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
          ],
        ]),
      );
}
