import '../main.dart';
import 'conexion.dart';

/// Comprueba la hora del equipo contra la del servidor. Los tickets llevan la fecha y hora
/// del equipo que cobra: si el reloj del TPV va mal, la factura sale con la hora mal.
class HoraEquipo {
  HoraEquipo._();

  static const margen = Duration(minutes: 2);
  static ({Duration desfase, DateTime mirado})? _cache;

  /// Hora del equipo menos hora del servidor (positivo: el equipo va adelantado).
  /// null si no se pudo mirar (sin internet o sin la migración 0028). Se mira como mucho
  /// cada 10 min salvo con [forzar].
  static Future<Duration?> desfase({bool forzar = false}) async {
    final ahora = DateTime.now();
    if (!forzar && _cache != null && ahora.difference(_cache!.mirado) < const Duration(minutes: 10)) {
      return _cache!.desfase;
    }
    if (!Conexion.enLinea.value) return _cache?.desfase;
    try {
      final antes = DateTime.now();
      final r = await supabase.rpc('hora_servidor');
      final despues = DateTime.now();
      final servidor = DateTime.parse(r as String);
      // La respuesta tarda: se compara con el punto medio de la ida y la vuelta
      final local = antes.add(despues.difference(antes) ~/ 2);
      final d = local.difference(servidor);
      _cache = (desfase: d, mirado: despues);
      return d;
    } catch (_) {
      return _cache?.desfase;
    }
  }

  /// true si el desfase supera el margen.
  static bool mal(Duration? d) => d != null && d.abs() > margen;

  /// "adelantada 5 min" / "atrasada 1 h 12 min"
  static String texto(Duration d) {
    final m = d.inMinutes.abs();
    final cuanto = m >= 60 ? '${m ~/ 60} h ${m % 60} min' : '$m min';
    return '${d.isNegative ? 'atrasada' : 'adelantada'} $cuanto';
  }
}
