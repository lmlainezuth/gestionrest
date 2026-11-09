import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/modelos.dart' show euros;
import 'colores.dart' show leerImporte;

/// Lista de modificadores (extras y cambios) para usar en los productos.
class ModificadoresDialog extends StatefulWidget {
  const ModificadoresDialog({super.key});

  @override
  State<ModificadoresDialog> createState() => _ModificadoresDialogState();
}

class _ModificadoresDialogState extends State<ModificadoresDialog> {
  List<Map<String, dynamic>> _mods = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    _mods = List<Map<String, dynamic>>.from(await supabase.from('modificadores').select().order('nombre'));
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _editar([Map<String, dynamic>? m]) async {
    final nombre = TextEditingController(text: m?['nombre'] as String?);
    final precio = TextEditingController(text: m == null ? '0' : (m['precio'] as num).toStringAsFixed(2).replaceAll('.', ','));
    var activo = (m?['activo'] as bool?) ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(m == null ? 'Nuevo modificador' : 'Editar modificador'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nombre, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre (Extra queso, Sin cebolla…)')),
              const SizedBox(height: 12),
              TextField(controller: precio, decoration: const InputDecoration(labelText: 'Precio extra', suffixText: '€', helperText: '0 si no cambia el precio')),
              if (m != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Activo'),
                  value: activo,
                  onChanged: (v) => setD(() => activo = v),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true || nombre.text.trim().isEmpty) return;
    final datos = {'nombre': nombre.text.trim(), 'precio': leerImporte(precio.text) ?? 0, 'activo': activo};
    m == null
        ? await supabase.from('modificadores').insert(datos)
        : await supabase.from('modificadores').update(datos).eq('id', m['id']);
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Modificadores'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: _cargando
            ? const Center(child: CircularProgressIndicator())
            : _mods.isEmpty
                ? const Center(child: Text('Crea el primero: Extra queso, Sin cebolla…', style: TextStyle(color: C.gris)))
                : ListView(children: [
                    for (final m in _mods)
                      ListTile(
                        title: Text(m['nombre'] as String,
                            style: TextStyle(decoration: m['activo'] == true ? null : TextDecoration.lineThrough)),
                        trailing: Text((m['precio'] as num) > 0 ? '+${euros(m['precio'] as num)}' : 'sin coste',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        onTap: () => _editar(m),
                      ),
                  ]),
      ),
      actions: [
        TextButton.icon(onPressed: () => _editar(), icon: const Icon(Icons.add), label: const Text('Nuevo')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Listo')),
      ],
    );
  }
}
