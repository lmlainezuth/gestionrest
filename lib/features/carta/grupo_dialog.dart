import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'colores.dart';

/// Crear o editar un grupo. Devuelve true si se guardó o borró.
class GrupoDialog extends StatefulWidget {
  const GrupoDialog({super.key, this.grupo});
  final Map<String, dynamic>? grupo;

  @override
  State<GrupoDialog> createState() => _GrupoDialogState();
}

class _GrupoDialogState extends State<GrupoDialog> {
  late final _nombre = TextEditingController(text: widget.grupo?['nombre'] as String?);
  late String _color = (widget.grupo?['color'] as String?) ?? coloresGrupo.first;
  late bool _activo = (widget.grupo?['activo'] as bool?) ?? true;
  String? _error;
  bool _guardando = false;

  bool get _nuevo => widget.grupo == null;

  Future<void> _guardar() async {
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty) {
      setState(() => _error = 'Escribe un nombre');
      return;
    }
    setState(() => _guardando = true);
    try {
      final datos = {'nombre': nombre, 'color': _color, 'activo': _activo};
      if (_nuevo) {
        await supabase.from('grupos_productos').insert(datos);
      } else {
        await supabase.from('grupos_productos').update(datos).eq('id', widget.grupo!['id']);
      }
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      setState(() {
        _error = e.message;
        _guardando = false;
      });
    }
  }

  Future<void> _borrar() async {
    try {
      await supabase.from('grupos_productos').delete().eq('id', widget.grupo!['id']);
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      setState(() => _error = e.code == '23503'
          ? 'Tiene productos: desactívalo en lugar de borrarlo'
          : e.message);
    }
  }

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_nuevo ? 'Nuevo grupo' : 'Editar grupo'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nombre', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            const Text('Color'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final c in coloresGrupo)
                  InkWell(
                    onTap: () => setState(() => _color = c),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colorDe(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == _color ? Colors.black : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Activo'),
              value: _activo,
              onChanged: (v) => setState(() => _activo = v),
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
      actions: [
        if (!_nuevo) TextButton(onPressed: _borrar, child: const Text('Borrar')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _guardando ? null : _guardar, child: const Text('Guardar')),
      ],
    );
  }
}
