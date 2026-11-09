import '../../main.dart';

/// Acceso a la caja y su turno abierto.
class CajaService {
  static Future<Map<String, dynamic>> caja() =>
      supabase.from('cajas').select().eq('activo', true).limit(1).single();

  static Future<Map<String, dynamic>?> turnoAbierto(String cajaId) => supabase
      .from('turnos_caja')
      .select()
      .eq('caja_id', cajaId)
      .eq('estado', 'abierto')
      .maybeSingle();
}
