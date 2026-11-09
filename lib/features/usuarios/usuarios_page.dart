import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../../core/permisos.dart';
import '../auth/perfil.dart';
import '../auth/pin.dart';

const _roles = {'admin': 'Administrador', 'camarero': 'Camarero', 'cocinero': 'Cocina'};

/// Tipos al crear un usuario. "Gestión" es un camarero que solo ve caja diaria, gastos, proveedores y resumen
/// (para la tablet de la oficina): sin mesas, barra ni cobros.
const _tiposNuevo = {'admin': 'Admin', 'camarero': 'Camarero', 'cocinero': 'Cocina', 'gestion': 'Gestión'};

/// Gestión del equipo: alta de usuarios, rol, activación y contraseña.
class UsuariosPage extends StatefulWidget {
  const UsuariosPage({super.key});

  @override
  State<UsuariosPage> createState() => _UsuariosPageState();
}

class _UsuariosPageState extends State<UsuariosPage> {
  List<Map<String, dynamic>> _perfiles = [];
  bool _cargando = true;
  String? _error;

  String get _yo => supabase.auth.currentUser!.id;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      _perfiles = List<Map<String, dynamic>>.from(await supabase.rpc('equipo_empresa'));
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _actualizar(Map<String, dynamic> p, Map<String, dynamic> cambios) async {
    try {
      // Rol, activo y permisos son de esta empresa
      await supabase.from('empresa_usuarios').update(cambios).eq('usuario_id', p['id']);
      await _cargar();
    } catch (e) {
      _avisar('No se pudo guardar: $e');
    }
  }

  void _avisar(String texto) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  /// Llama a la Edge Function y devuelve el mensaje de error, o null si fue bien.
  Future<String?> _funcion(Map<String, dynamic> cuerpo) async {
    try {
      await supabase.functions.invoke('crear-usuario', body: cuerpo);
      return null;
    } on FunctionException catch (e) {
      final d = e.details;
      return d is Map && d['error'] != null ? '${d['error']}' : 'Error ${e.status}: ${e.reasonPhrase ?? d}';
    } catch (e) {
      return '$e';
    }
  }

  Future<void> _nuevo() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _NuevoUsuario(funcion: _funcion));
    if (ok == true) {
      _avisar('Usuario creado');
      await _cargar();
    }
  }

  Future<void> _cambiarClave(Map<String, dynamic> p) async {
    final ctrl = TextEditingController();
    final clave = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Nuevo PIN de ${p['nombre']}'),
        content: SizedBox(
          width: 300,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 8,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, letterSpacing: 12),
            decoration: const InputDecoration(labelText: 'PIN (1 a 8 cifras)', counterText: ''),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Cambiar')),
        ],
      ),
    );
    if (clave == null) return;
    final error = await _funcion({'accion': 'pin', 'id': p['id'], 'pin': clave});
    _avisar(error ?? 'PIN cambiado');
  }

  Future<void> _permisos(Map<String, dynamic> p) async {
    final rol = Rol.values.byName(p['rol'] as String);
    final posibles = permisosPermitidos[rol]!;
    final marcados = {...((p['permisos'] as List?)?.cast<String>() ?? permisosPorDefecto[rol]!)};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Permisos de ${p['nombre']}'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final k in posibles)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(nombresPermiso[k] ?? k),
                  value: marcados.contains(k),
                  onChanged: (v) => setD(() => v == true ? marcados.add(k) : marcados.remove(k)),
                ),
            ])),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    // Todos marcados = sin restricciones (null)
    await _actualizar(p, {'permisos': marcados.toList()});
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Error: $_error'));
    final pendientes = _perfiles.where((p) => p['activo'] != true).length;

    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${_perfiles.length} personas en el equipo'
                '${pendientes > 0 ? ' · $pendientes pendientes de activar' : ''}',
                style: const TextStyle(color: C.gris),
              ),
            ),
            FilledButton.icon(onPressed: _nuevo, icon: const Icon(Icons.person_add_alt), label: const Text('Nuevo usuario')),
          ],
        ),
        const SizedBox(height: 20),
        for (final p in _perfiles) _fila(p),
      ],
    );
  }

  Widget _fila(Map<String, dynamic> p) {
    final soyYo = p['id'] == _yo;
    final activo = p['activo'] == true;
    final nombre = (p['nombre'] as String?) ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: C.blanco,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: activo ? C.borde : C.naranja),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: activo ? C.verde : C.bordeFuerte,
            child: Text(nombre.isEmpty ? '?' : nombre[0].toUpperCase(),
                style: const TextStyle(color: C.sobreAccion, fontWeight: FontWeight.w700, fontSize: 18)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(soyYo ? '$nombre (tú)' : nombre, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                Text(esUsuarioPin(p['correo'] as String?) ? 'Entra con PIN' : 'Entra con correo · ${p['correo']}',
                    style: const TextStyle(color: C.gris, fontSize: 13)),
              ],
            ),
          ),
          SizedBox(
            width: 190,
            child: DropdownButtonFormField<String>(
              initialValue: p['rol'] as String,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Rol', isDense: true),
              items: [
                for (final r in _roles.entries) DropdownMenuItem(value: r.key, child: Text(r.value)),
              ],
              onChanged: soyYo ? null : (v) => _actualizar(p, {'rol': v}),
            ),
          ),
          const SizedBox(width: 16),
          Column(
            children: [
              Switch(value: activo, onChanged: soyYo ? null : (v) => _actualizar(p, {'activo': v})),
              Text(activo ? 'Activo' : 'Inactivo', style: const TextStyle(fontSize: 11, color: C.gris)),
            ],
          ),
          IconButton(
            tooltip: 'Permisos',
            onPressed: soyYo ? null : () => _permisos(p),
            icon: Icon(p['permisos'] == null ? Icons.lock_open_outlined : Icons.lock_person_outlined),
          ),
          IconButton(
            tooltip: 'Cambiar PIN',
            onPressed: esUsuarioPin(p['correo'] as String?) ? () => _cambiarClave(p) : null,
            icon: const Icon(Icons.pin_outlined),
          ),
        ],
      ),
    );
  }
}

class _NuevoUsuario extends StatefulWidget {
  const _NuevoUsuario({required this.funcion});
  final Future<String?> Function(Map<String, dynamic>) funcion;

  @override
  State<_NuevoUsuario> createState() => _NuevoUsuarioState();
}

class _NuevoUsuarioState extends State<_NuevoUsuario> {
  final _nombre = TextEditingController();
  final _pin = TextEditingController();
  String _rol = 'camarero';
  bool _guardando = false;
  String? _error;

  Future<void> _crear() async {
    setState(() {
      _guardando = true;
      _error = null;
    });
    final gestion = _rol == 'gestion';
    var error = await widget.funcion({
      'nombre': _nombre.text,
      'pin': _pin.text,
      'rol': gestion ? 'camarero' : _rol,
    });
    if (error == null && gestion) {
      // Le dejamos solo los permisos de gestión
      try {
        final equipo = List<Map<String, dynamic>>.from(await supabase.rpc('equipo_empresa'));
        final nuevo = equipo.where((u) => (u['nombre'] as String).trim() == _nombre.text.trim()).toList();
        if (nuevo.isNotEmpty) {
          await supabase.from('empresa_usuarios').update({'permisos': permisosGestion}).eq('usuario_id', nuevo.last['id']);
        }
      } catch (e) {
        error = 'Usuario creado, pero no se pudieron poner los permisos de gestión: $e';
      }
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _guardando = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nuevo usuario'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _nombre, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre')),
            const SizedBox(height: 12),
            TextField(
              controller: _pin,
              maxLength: 8,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, letterSpacing: 12),
              decoration: const InputDecoration(labelText: 'PIN (1 a 8 cifras)', counterText: ''),
            ),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: [
                for (final r in _tiposNuevo.entries) ButtonSegment(value: r.key, label: Text(r.value)),
              ],
              selected: {_rol},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _rol = s.first),
            ),
            if (_rol == 'gestion') ...[
              const SizedBox(height: 8),
              const Text('Solo verá Caja por días, Gastos, Proveedores y Números. Ideal para la tablet de la oficina.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _guardando ? null : _crear, child: Text(_guardando ? 'Creando…' : 'Crear')),
      ],
    );
  }
}
