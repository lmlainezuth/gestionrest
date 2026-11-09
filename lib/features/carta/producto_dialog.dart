import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'alergenos.dart';
import 'colores.dart';

/// Crear o editar un producto. Devuelve true si se guardó.
class ProductoDialog extends StatefulWidget {
  const ProductoDialog({
    super.key,
    required this.grupoId,
    required this.areas,
    this.producto,
  });
  final String grupoId;
  final List<Map<String, dynamic>> areas;
  final Map<String, dynamic>? producto;

  @override
  State<ProductoDialog> createState() => _ProductoDialogState();
}

class _ProductoDialogState extends State<ProductoDialog> {
  final _form = GlobalKey<FormState>();
  late final p = widget.producto;
  late final _nombre = TextEditingController(text: p?['nombre'] as String?);
  late final _codigo = TextEditingController(text: p?['codigo'] as String?);
  late final _venta = TextEditingController(text: _fmt(p?['precio_venta']));
  late final _compra = TextEditingController(text: _fmt(p?['precio_compra']));
  late String? _area = p?['area_id'] as String? ??
      (widget.areas.isEmpty ? null : widget.areas.first['id'] as String);
  late final Set<String> _alergenos = {...((p?['alergenos'] as List?) ?? []).cast<String>()};
  late bool _activo = (p?['activo'] as bool?) ?? true;
  String? _error;
  bool _guardando = false;

  static String _fmt(Object? v) =>
      v == null ? '' : (v as num).toStringAsFixed(2).replaceAll('.', ',');

  Future<void> _guardar() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _guardando = true);
    final datos = {
      'grupo_id': widget.grupoId,
      'area_id': _area,
      'nombre': _nombre.text.trim(),
      'codigo': _codigo.text.trim().isEmpty ? null : _codigo.text.trim(),
      'precio_venta': leerImporte(_venta.text),
      'precio_compra': leerImporte(_compra.text) ?? 0,
      'alergenos': _alergenos.toList(),
      'activo': _activo,
    };
    try {
      if (p == null) {
        await supabase.from('productos').insert(datos);
      } else {
        await supabase.from('productos').update(datos).eq('id', p!['id']);
      }
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      setState(() {
        _error = e.message;
        _guardando = false;
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_nombre, _codigo, _venta, _compra]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? importe(String? v, {bool obligatorio = false}) {
      if (v == null || v.trim().isEmpty) return obligatorio ? 'Obligatorio' : null;
      final n = leerImporte(v);
      return n == null || n < 0 ? 'Importe no válido' : null;
    }

    return AlertDialog(
      title: Text(p == null ? 'Nuevo producto' : 'Editar producto'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nombre,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Nombre', border: OutlineInputBorder()),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _venta,
                        decoration: const InputDecoration(
                            labelText: 'Precio venta (IVA incl.)',
                            suffixText: '€',
                            border: OutlineInputBorder()),
                        validator: (v) => importe(v, obligatorio: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _compra,
                        decoration: const InputDecoration(
                            labelText: 'Coste', suffixText: '€', border: OutlineInputBorder()),
                        validator: importe,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _area,
                        decoration: const InputDecoration(
                            labelText: 'Se prepara en', border: OutlineInputBorder()),
                        items: [
                          for (final a in widget.areas)
                            DropdownMenuItem(value: a['id'] as String, child: Text(a['nombre'] as String)),
                        ],
                        onChanged: (v) => setState(() => _area = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _codigo,
                        decoration: const InputDecoration(
                            labelText: 'Código (opcional)', border: OutlineInputBorder()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Alérgenos'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in alergenos.entries)
                      FilterChip(
                        label: Text(e.value),
                        selected: _alergenos.contains(e.key),
                        onSelected: (s) => setState(() {
                          s ? _alergenos.add(e.key) : _alergenos.remove(e.key);
                        }),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Disponible en carta'),
                  value: _activo,
                  onChanged: (v) => setState(() => _activo = v),
                ),
                if (_error != null)
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _guardando ? null : _guardar, child: const Text('Guardar')),
      ],
    );
  }
}
