import 'dart:async';

import '../main.dart';
import 'config.dart';
import 'conexion.dart';

/// Mantiene cargada la función "ticketbai" en los equipos que están cobrando: arrancarla cuesta
/// más de un segundo y se notaba en cada cobro. Llama a la acción «despertar», que solo contesta
/// «ok» (no lee datos, no firma, no envía). Solo mientras se cobra: si este equipo lleva un rato
/// sin cobrar, deja de llamar (cada llamada cuenta en el cupo de Supabase).
class ServidorDespierto {
  ServidorDespierto._();
  static Timer? _reloj;
  static DateTime? _ultimoUso;
  static const _cada = Duration(minutes: 1);
  static const _durante = Duration(hours: 2); // tras el último cobro o apertura del cobro

  /// Ahora mismo (al abrir la ventana de cobro) y, desde ahora, cada minuto durante un rato.
  static void ya() {
    _ultimoUso = DateTime.now();
    _llamar();
    _reloj ??= Timer.periodic(_cada, (_) {
      final u = _ultimoUso;
      if (u == null || DateTime.now().difference(u) > _durante) {
        _reloj?.cancel();
        _reloj = null;
        return;
      }
      if (Conexion.enLinea.value) _llamar();
    });
  }

  static void _llamar() {
    if (supabase.auth.currentSession == null) return;
    supabase.functions
        .invoke('ticketbai', body: {'accion': 'despertar'}, region: Config.regionServidor)
        .then((_) {}, onError: (_) {});
  }
}
