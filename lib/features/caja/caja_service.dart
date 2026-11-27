import '../../main.dart';

/// Acceso a la caja y su turno abierto.
class CajaService {
  static Future<Map<String, dynamic>> caja() async {
    final c = await supabase.from('cajas').select().eq('activo', true).limit(1).single();
    ultimaCajaId = c['id'] as String?;
    return c;
  }

  /// Id de la última caja leída en este equipo (el cobro pide su turno sin esperar a leerla).
  static String? ultimaCajaId;

  /// Turno abierto de la caja, por el servidor (migración 0051): sin el permiso de cierres, el
  /// camarero no lee la tabla de turnos y el fondo inicial solo le llega si abrió él la caja.
  static Future<Map<String, dynamic>?> turnoAbierto(String cajaId) async {
    final r = await supabase.rpc('turno_abierto', params: {'p_caja': cajaId});
    return r == null ? null : Map<String, dynamic>.from(r as Map);
  }
}
