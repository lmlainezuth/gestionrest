import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/foto_producto.dart';
import '../../core/panel_lateral.dart';
import '../../main.dart';
import 'alergenos.dart';
import 'package:file_picker/file_picker.dart';

import '../auth/perfil.dart';
import '../ticketbai/modelos.dart' show euros;
import 'colores.dart';
import 'modificadores_dialog.dart';

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
  late double _iva = ((p?['tipo_iva'] as num?) ?? 10).toDouble();
  String? _error;
  bool _guardando = false;
  late String? _imagen = p?['imagen_url'] as String?;
  bool _subiendo = false;
  List<Map<String, dynamic>> _mods = [];
  final Set<String> _modsSel = {};

  @override
  void initState() {
    super.initState();
    _cargarMods();
  }

  Future<void> _cargarMods() async {
    final mods = await supabase.from('modificadores').select().eq('activo', true).order('nombre');
    if (p != null) {
      final sel = await supabase.from('producto_modificadores').select('modificador_id').eq('producto_id', p!['id']);
      _modsSel.addAll(sel.map((r) => r['modificador_id'] as String));
    }
    if (mounted) setState(() => _mods = List<Map<String, dynamic>>.from(mods));
  }

  Future<void> _elegirImagen() async {
    final f = await FilePicker.pickFile();
    if (f == null) return;
    final ext = (f.extension ?? '').toLowerCase();
    if (!['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(ext)) {
      setState(() => _error = 'Elige una imagen (jpg, png, webp o gif)');
      return;
    }
    setState(() => _subiendo = true);
    try {
      final bytes = await f.readAsBytes();
      // El almacén de fotos admite 2 MB como mucho (migración 0053)
      if (bytes.length > 2 * 1024 * 1024) throw 'la imagen pesa más de 2 MB: redúcela antes de subirla';
      // Cada bar sube a su carpeta: la base solo deja tocar las imágenes de la carpeta propia
      final empresa = Perfil.cache?.empresaId;
      if (empresa == null) throw 'no hay empresa elegida';
      final ruta = '$empresa/${DateTime.now().microsecondsSinceEpoch}.$ext';
      await supabase.storage.from('productos').uploadBinary(ruta, bytes,
          fileOptions: FileOptions(contentType: 'image/${ext == 'jpg' ? 'jpeg' : ext}'));
      // Se guarda la ruta, no una dirección pública: el bucket es privado (migración 0047)
      setState(() => _imagen = ruta);
    } catch (e) {
      setState(() => _error = 'No se pudo subir la imagen: $e');
    }
    if (mounted) setState(() => _subiendo = false);
  }

  static String _fmt(Object? v) =>
      v == null ? '' : (v as num).toStringAsFixed(2).replaceAll('.', ',');

  Future<void> _guardarMods(String productoId) async {
    await supabase.from('producto_modificadores').delete().eq('producto_id', productoId);
    if (_modsSel.isNotEmpty) {
      await supabase.from('producto_modificadores').insert([
        for (final m in _modsSel) {'producto_id': productoId, 'modificador_id': m},
      ]);
    }
  }

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
      'tipo_iva': _iva,
      'imagen_url': _imagen,
    };
    try {
      if (p == null) {
        final nuevo = await supabase.from('productos').insert(datos).select('id').single();
        await _guardarMods(nuevo['id'] as String);
      } else {
        await supabase.from('productos').update(datos).eq('id', p!['id']);
        await _guardarMods(p!['id'] as String);
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

    final ancha = MediaQuery.sizeOf(context).width >= 1000;
    return PanelLateral(
      anchura: ancha ? double.infinity : 460, // en el TPV, a lo ancho de toda la pantalla
      encabezado: p == null ? 'Nuevo producto' : 'Editar producto',
      boton: _guardando ? 'Guardando…' : 'Guardar producto',
      onBoton: _guardando ? null : _guardar,
      cuerpo: Form(
          key: _form,
            child: Builder(builder: (context) {
              // Tres bloques: datos, imagen y extras, alérgenos. En el TPV van en columnas, a lo ancho
              final datos = <Widget>[
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
                const SizedBox(height: 12),
                DropdownButtonFormField<double>(
                  isExpanded: true,
                  initialValue: _iva,
                  decoration: const InputDecoration(labelText: 'IVA', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('10 % · se consume en el bar (lo normal)', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: 21, child: Text('21 % · para llevar: alcohol, refrescos azucarados, tabaco', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: 4, child: Text('4 % · para llevar: pan, leche', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _iva = v ?? 10),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Disponible en carta'),
                  value: _activo,
                  onChanged: (v) => setState(() => _activo = v),
                ),
                if (_error != null)
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ];
              final extras = <Widget>[
                Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 72,
                      height: 72,
                      color: const Color(0xFFEFEAE0),
                      child: _imagen == null
                          ? const Icon(Icons.image_outlined, color: Colors.black38)
                          : FotoProducto(_imagen, ancho: 72, alto: 72,
                              hueco: const Icon(Icons.broken_image_outlined, color: Colors.black38)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _subiendo ? null : _elegirImagen,
                    icon: const Icon(Icons.upload_outlined),
                    label: Text(_subiendo ? 'Subiendo…' : (_imagen == null ? 'Añadir imagen' : 'Cambiar imagen')),
                  ),
                  if (_imagen != null)
                    TextButton(onPressed: () => setState(() => _imagen = null), child: const Text('Quitar')),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  const Text('Extras y cambios'),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      await showDialog<bool>(context: context, builder: (_) => const ModificadoresDialog());
                      await _cargarMods();
                    },
                    child: const Text('Gestionar'),
                  ),
                ]),
                if (_mods.isEmpty)
                  const Text('Sin modificadores creados.', style: TextStyle(fontSize: 13, color: Colors.black54))
                else
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final m in _mods)
                      FilterChip(
                        label: Text((m['precio'] as num) > 0 ? '${m['nombre']} +${euros(m['precio'] as num)}' : '${m['nombre']}'),
                        selected: _modsSel.contains(m['id']),
                        onSelected: (s) => setState(() => s ? _modsSel.add(m['id'] as String) : _modsSel.remove(m['id'])),
                      ),
                  ]),
              ];
              final alergias = <Widget>[
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
              ];
              Widget columna(List<Widget> hijos) =>
                  Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: hijos);
              if (!ancha) {
                return columna([...datos, const SizedBox(height: 16), ...extras, const SizedBox(height: 16), ...alergias]);
              }
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 5, child: columna(datos)),
                const SizedBox(width: 28),
                Expanded(flex: 4, child: columna(extras)),
                const SizedBox(width: 28),
                Expanded(flex: 4, child: columna(alergias)),
              ]);
            }),
      ),
    );
  }
}
