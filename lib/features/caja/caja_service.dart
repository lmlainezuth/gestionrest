import '../../main.dart';

/// Acceso a la caja y su turno abierto.
class CajaService {
  static Future<Map<String, dynamic>> caja() =>
      supabase.from('cajas').select().eq('activo', true).limit(1).single();

  /// Turno abierto de la caja, por el servidor (migración 0051): sin el permiso de cierres, el
  /// camarero no lee la tabla de turnos y el fondo inicial solo le llega si abrió él la caja.
  static Future<Map<String, dynamic>?> turnoAbierto(String cajaId) async {
    final r = await supabase.rpc('turno_abierto', params: {'p_caja': cajaId});
    return r == null ? null : Map<String, dynamic>.from(r as Map);
  }
}
