import '../../core/permisos.dart';
import '../../main.dart';

enum Rol { admin, camarero, cocinero }

/// Usuario con sesión iniciada, con su rol en la empresa actual.
class Perfil {
  final String id;
  final String nombre;
  final Rol rol;
  final bool activo;
  final List<String>? permisos; // null = los de su rol por defecto
  final String? empresaId;
  final String? empresaNombre;

  const Perfil({
    required this.id,
    required this.nombre,
    required this.rol,
    required this.activo,
    this.permisos,
    this.empresaId,
    this.empresaNombre,
  });

  /// Último perfil cargado (para saber el rol desde cualquier pantalla).
  static Perfil? cache;

  bool get esAdmin => rol == Rol.admin;

  /// ¿Puede usar esta función? Lo marcado para él dentro de lo que su rol permite;
  /// sin marcar nada, lo que su rol tiene por defecto.
  bool puede(String permiso) =>
      permisosPermitidos[rol]!.contains(permiso) &&
      (permisos == null ? permisosPorDefecto[rol]!.contains(permiso) : permisos!.contains(permiso));

  /// Perfil en la empresa actual. Devuelve null si no hay sesión.
  /// Si el usuario no tiene empresa elegida, empresaId viene null.
  static Future<Perfil?> actual() async {
    if (supabase.auth.currentUser == null) return null;
    final filas = await supabase.rpc('mi_perfil') as List;
    if (filas.isEmpty) return cache = null;
    final m = Map<String, dynamic>.from(filas.first as Map);
    return cache = Perfil(
      id: m['id'] as String,
      nombre: m['nombre'] as String,
      rol: m['rol'] == null ? Rol.camarero : Rol.values.byName(m['rol'] as String),
      activo: m['rol'] != null && m['activo'] == true,
      permisos: (m['permisos'] as List?)?.cast<String>(),
      empresaId: m['empresa_id'] as String?,
      empresaNombre: m['empresa_nombre'] as String?,
    );
  }
}
