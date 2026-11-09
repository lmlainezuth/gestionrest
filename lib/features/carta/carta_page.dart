import 'package:flutter/material.dart';

import '../../core/red.dart';
import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/modelos.dart' show euros;
import 'alergenos.dart';
import 'carta_qr.dart';
import 'colores.dart';
import 'grupo_dialog.dart';
import 'modificadores_dialog.dart';
import 'producto_dialog.dart';

/// Gestión de la carta: grupos a la izquierda, productos del grupo a la derecha.
class CartaPage extends StatefulWidget {
  const CartaPage({super.key});

  @override
  State<CartaPage> createState() => _CartaPageState();
}

class _CartaPageState extends State<CartaPage> {
  List<Map<String, dynamic>> _grupos = [];
  List<Map<String, dynamic>> _productos = [];
  List<Map<String, dynamic>> _areas = [];
  String? _grupoId;
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargarTodo();
  }

  Future<void> _cargarTodo() async {
    try {
      final grupos = await supabase
          .from('grupos_productos')
          .select()
          .order('orden')
          .order('nombre');
      final areas = await supabase.from('areas_preparacion').select().eq('activo', true);
      _grupos = List<Map<String, dynamic>>.from(grupos);
      _areas = List<Map<String, dynamic>>.from(areas);
      if (_grupoId == null || !_grupos.any((g) => g['id'] == _grupoId)) {
        _grupoId = _grupos.isEmpty ? null : _grupos.first['id'] as String;
      }
      await _cargarProductos();
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _cargarProductos() async {
    if (_grupoId == null) {
      _productos = [];
      return;
    }
    final filas = await supabase
        .from('productos')
        .select()
        .eq('grupo_id', _grupoId!)
        .order('nombre');
    _productos = List<Map<String, dynamic>>.from(filas);
  }

  Future<void> _elegirGrupo(String id) async {
    setState(() => _grupoId = id);
    await _cargarProductos();
    if (mounted) setState(() {});
  }

  Future<void> _abrirGrupo([Map<String, dynamic>? grupo]) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => GrupoDialog(grupo: grupo),
    );
    if (ok == true) await _cargarTodo();
  }

  Future<void> _abrirProducto([Map<String, dynamic>? producto]) async {
    if (_grupoId == null) return;
    final ok = await mostrarPanel<bool>(
      context,
      (_) => ProductoDialog(grupoId: _grupoId!, areas: _areas, producto: producto),
    );
    if (ok == true) {
      await _cargarProductos();
      if (mounted) setState(() {});
    }
  }

  String _nombreArea(Object? id) =>
      _areas.firstWhere((a) => a['id'] == id, orElse: () => {'nombre': '—'})['nombre'] as String;

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AvisoSinConexion(textoError(_error), onReintentar: () {
        setState(() {
          _error = null;
          _cargando = true;
        });
        _cargarTodo();
      });
    }

    final grupo = _grupos.where((g) => g['id'] == _grupoId).firstOrNull;
    final tema = Theme.of(context);

    return Row(
      children: [
        // ---------------- Grupos ----------------
        SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(
                  children: [
                    Expanded(child: Text('Grupos', style: tema.textTheme.titleLarge)),
                    IconButton(
                      tooltip: 'Modificadores (extras)',
                      icon: const Icon(Icons.tune),
                      onPressed: () => showDialog<bool>(context: context, builder: (_) => const ModificadoresDialog()),
                    ),
                    IconButton(
                      tooltip: 'Nuevo grupo',
                      icon: const Icon(Icons.add),
                      onPressed: () => _abrirGrupo(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _grupos.isEmpty
                    ? const Center(child: Text('Crea el primer grupo'))
                    : ListView(
                        children: [
                          for (final g in _grupos)
                            ListTile(
                              selected: g['id'] == _grupoId,
                              selectedTileColor: tema.colorScheme.secondaryContainer,
                              leading: CircleAvatar(radius: 10, backgroundColor: colorDe(g['color'] as String?)),
                              title: Text(
                                g['nombre'] as String,
                                style: TextStyle(
                                  decoration: g['activo'] == true ? null : TextDecoration.lineThrough,
                                ),
                              ),
                              trailing: IconButton(
                                tooltip: 'Editar grupo',
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                onPressed: () => _abrirGrupo(g),
                              ),
                              onTap: () => _elegirGrupo(g['id'] as String),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        // ---------------- Productos ----------------
        Expanded(
          child: grupo == null
              ? const Center(child: Text('Selecciona o crea un grupo'))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${grupo['nombre']} · ${_productos.length} productos',
                              style: tema.textTheme.titleLarge,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => mostrarQrCarta(context),
                            icon: const Icon(Icons.qr_code_2),
                            label: const Text('Carta QR'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: () => _abrirProducto(),
                            icon: const Icon(Icons.add),
                            label: const Text('Nuevo producto'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _productos.isEmpty
                          ? const Center(child: Text('Este grupo no tiene productos'))
                          : GridView.extent(
                              maxCrossAxisExtent: 240,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 1.05,
                              padding: const EdgeInsets.all(20),
                              children: [for (final p in _productos) _tarjeta(p, grupo)],
                            ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _tarjeta(Map<String, dynamic> p, Map<String, dynamic> grupo) {
    final activo = p['activo'] == true;
    final al = ((p['alergenos'] as List?) ?? []).cast<String>();
    return Opacity(
      opacity: activo ? 1 : 0.45,
      child: Material(
        color: C.blanco,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _abrirProducto(p),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: colorDe(grupo['color'] as String?), width: 6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (p['imagen_url'] != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(p['imagen_url'] as String, height: 44, width: 44, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink()),
                    ),
                  ),
                Text(p['nombre'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 4),
                Text(_nombreArea(p['area_id']), style: const TextStyle(fontSize: 12, color: C.gris)),
                const Spacer(),
                if (al.isNotEmpty)
                  Text(al.map((a) => alergenos[a] ?? a).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: C.naranja)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(euros(p['precio_venta'] as num),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                    const Spacer(),
                    if (!activo) const Text('No disponible', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
