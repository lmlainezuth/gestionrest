import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/permisos.dart';
import '../../core/red.dart';
import '../../core/software.dart';
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
  final bool usaCocina; // ajuste del bar (migración 0056); sin él, sí

  const Perfil({
    required this.id,
    required this.nombre,
    required this.rol,
    required this.activo,
    this.permisos,
    this.empresaId,
    this.empresaNombre,
    this.usaCocina = true,
  });

  /// Último perfil cargado (para saber el rol desde cualquier pantalla).
  static Perfil? cache;

  bool get esAdmin => rol == Rol.admin;

  /// ¿Puede usar esta función? Lo marcado para él dentro de lo que su rol permite;
  /// sin marcar nada, lo que su rol tiene por defecto. En un bar sin pantalla de cocina (Ajustes ›
  /// Empresa) el permiso «cocina» no vale para nadie.
  bool puede(String permiso) =>
      (permiso != 'cocina' || usaCocina) &&
      permisosPermitidos[rol]!.contains(permiso) &&
      (permisos == null ? permisosPorDefecto[rol]!.contains(permiso) : permisos!.contains(permiso));

  /// Perfil en la empresa actual. Devuelve null si no hay sesión.
  /// Si el usuario no tiene empresa elegida, empresaId viene null.
  static Future<Perfil?> actual() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    Map<String, dynamic> m;
    try {
      final filas = await supabase.rpc('mi_perfil') as List;
      if (filas.isEmpty) return cache = null;
      m = Map<String, dynamic>.from(filas.first as Map);
      // Ajuste del bar: ¿usa pantalla de cocina? (antes de la 0056 no existe: sí)
      try {
        final e = await supabase.from('empresa').select('usa_cocina').limit(1).maybeSingle();
        m['usa_cocina'] = e?['usa_cocina'] as bool? ?? true;
      } catch (_) {
        m['usa_cocina'] = true;
      }
      // Datos del programa (licencia, desarrollador) al día en este equipo
      Software.cargar().ignore();
      // Copia en el equipo: si se abre la app sin internet, se entra con el último perfil
      SharedPreferences.getInstance().then((p) => p.setString('perfil_$uid', jsonEncode(m))).ignore();
    } catch (e) {
      if (!esErrorDeRed(e)) rethrow;
      final copia = (await SharedPreferences.getInstance()).getString('perfil_$uid');
      if (copia == null) rethrow;
      m = Map<String, dynamic>.from(jsonDecode(copia) as Map);
    }
    return cache = Perfil(
      id: m['id'] as String,
      nombre: m['nombre'] as String,
      rol: m['rol'] == null ? Rol.camarero : Rol.values.byName(m['rol'] as String),
      activo: m['rol'] != null && m['activo'] == true,
      permisos: (m['permisos'] as List?)?.cast<String>(),
      empresaId: m['empresa_id'] as String?,
      empresaNombre: m['empresa_nombre'] as String?,
      usaCocina: m['usa_cocina'] as bool? ?? true,
    );
  }
}
