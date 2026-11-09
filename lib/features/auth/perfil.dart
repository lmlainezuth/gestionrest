import '../../main.dart';

enum Rol { admin, camarero, cocinero }

class Perfil {
  final String id;
  final String nombre;
  final Rol rol;
  final bool activo;

  const Perfil({
    required this.id,
    required this.nombre,
    required this.rol,
    required this.activo,
  });

  factory Perfil.fromMap(Map<String, dynamic> m) => Perfil(
        id: m['id'] as String,
        nombre: m['nombre'] as String,
        rol: Rol.values.byName(m['rol'] as String),
        activo: m['activo'] as bool,
      );

  /// Último perfil cargado (para saber el rol desde cualquier pantalla).
  static Perfil? cache;

  bool get esAdmin => rol == Rol.admin;

  /// Perfil del usuario con sesión iniciada (null si no existe).
  static Future<Perfil?> actual() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    final fila = await supabase
        .from('perfiles')
        .select('id, nombre, rol, activo')
        .eq('id', uid)
        .maybeSingle();
    cache = fila == null ? null : Perfil.fromMap(fila);
    return cache;
  }
}
