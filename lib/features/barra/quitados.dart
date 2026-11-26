import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../main.dart';

/// Control: cada producto que se quita de una venta de Barra antes de cobrarla queda apuntado
/// (migración 0033) y el dueño lo ve en Anulaciones. Si no hay internet, se guarda en el equipo
/// y se sube con el siguiente.
class Quitados {
  static const _clave = 'quitados_pendientes';
  static bool _subiendo = false;

  static Future<void> apuntar(String descripcion, double cantidad, double importe) async {
    if (cantidad <= 0) return;
    try {
      final p = await SharedPreferences.getInstance();
      final cola = p.getStringList(_clave) ?? [];
      cola.add(jsonEncode({
        'p_descripcion': descripcion,
        'p_cantidad': cantidad,
        'p_importe': (importe * 100).roundToDouble() / 100,
        'p_momento': DateTime.now().toUtc().toIso8601String(),
      }));
      await p.setStringList(_clave, cola);
    } catch (_) {}
    subir();
  }

  /// Sube lo pendiente, en orden. Lo que falle se queda para el siguiente intento.
  static Future<void> subir() async {
    if (_subiendo) return;
    _subiendo = true;
    try {
      final p = await SharedPreferences.getInstance();
      while (true) {
        final cola = p.getStringList(_clave) ?? [];
        if (cola.isEmpty) break;
        await supabase.rpc('registrar_quitado', params: Map<String, dynamic>.from(jsonDecode(cola.first) as Map));
        // Se vuelve a leer: mientras subía pudo apuntarse otro
        final ahora = p.getStringList(_clave) ?? [];
        if (ahora.isNotEmpty) await p.setStringList(_clave, ahora.sublist(1));
      }
    } catch (_) {
      // sin internet o sin la migración 0033: se reintenta con el siguiente
    }
    _subiendo = false;
  }
}
