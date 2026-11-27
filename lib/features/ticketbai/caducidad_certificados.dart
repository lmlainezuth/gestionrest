import '../../core/certificado_equipo.dart';
import '../../core/firma_equipo.dart' if (dart.library.io) '../../core/firma_equipo_io.dart';
import '../../main.dart';
import 'cadena_equipo.dart';
import 'tbai_proveedor.dart' show probarCertificado;

/// Caducidad de los certificados de firma. El día que caduca un certificado ya no se puede
/// firmar (ni cobrar con él), así que se avisa con 30 días de margen: en la franja de arriba
/// del equipo que lo tiene y en el panel del dueño (tabla tbai_certificados, migración 0027).
class CaducidadCertificados {
  CaducidadCertificados._();

  static const diasAviso = 30;
  static DateTime? _servidorMirado;
  static ({DateTime? caduca, DateTime mirado})? _cache; // la franja de aviso pregunta cada 2 min

  /// Días que le quedan al certificado de este equipo (negativo si ya caducó); null si no tiene.
  static Future<int?> diasEquipo() async {
    final ahora = DateTime.now();
    if (_cache == null || ahora.difference(_cache!.mirado) > const Duration(hours: 1)) {
      _cache = (caduca: (await _equipo())?.caduca, mirado: ahora);
    }
    final caduca = _cache!.caduca;
    if (caduca == null) return null;
    return caduca.isBefore(ahora) ? -1 : _dias(caduca);
  }

  /// Tras instalar o quitar el certificado de este equipo.
  static void olvidar() => _cache = null;

  /// Apunta en la base de datos cuándo caduca el certificado de este equipo (con internet).
  static Future<void> registrarEquipo() async {
    try {
      final c = await _equipo();
      if (c == null) return;
      final serie = await CadenaEquipo.serie();
      await supabase.from('tbai_certificados').upsert({
        'origen': serie == null ? 'equipo' : 'equipo $serie',
        'titular': c.titular,
        'caduca': c.caduca.toUtc().toIso8601String(),
        'actualizado_en': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'empresa_id,origen');
    } catch (_) {
      // Sin la migración 0027 o sin conexión: no se avisa, pero no se rompe nada
    }
  }

  /// Pide al servidor que compruebe su certificado (como mucho cada 12 h). La caducidad la apunta
  /// el propio servidor en tbai_certificados (migración 0053): la app no puede escribir esa fila.
  static Future<void> registrarServidor() async {
    final ahora = DateTime.now();
    if (_servidorMirado != null && ahora.difference(_servidorMirado!) < const Duration(hours: 12)) return;
    _servidorMirado = ahora;
    try {
      await probarCertificado();
    } catch (_) {}
  }

  /// Certificados de la empresa que caducan en menos de 30 días (o ya caducados). Se ignoran
  /// los que nadie ha vuelto a apuntar en 30 días (equipo retirado o certificado quitado).
  static Future<List<({String origen, String? titular, DateTime caduca, int dias})>> porCaducar() async {
    final ahora = DateTime.now();
    final filas = List<Map<String, dynamic>>.from(await supabase
        .from('tbai_certificados')
        .select('origen, titular, caduca, actualizado_en')
        .lt('caduca', ahora.add(const Duration(days: diasAviso)).toUtc().toIso8601String())
        .gte('actualizado_en', ahora.subtract(const Duration(days: diasAviso)).toUtc().toIso8601String())
        .order('caduca'));
    return [
      for (final f in filas)
        (
          origen: f['origen'] as String,
          titular: f['titular'] as String?,
          caduca: DateTime.parse(f['caduca'] as String).toLocal(),
          dias: _dias(DateTime.parse(f['caduca'] as String)),
        ),
    ];
  }

  static Future<({String titular, DateTime caduca})?> _equipo() async {
    try {
      final cert = await CertificadoEquipo.leer();
      if (cert == null) return null;
      final c = await FirmaEquipo.certificado(cert.bytes, cert.clave);
      return (titular: c.titular, caduca: c.caduca);
    } catch (_) {
      return null;
    }
  }

  static int _dias(DateTime caduca) => caduca.difference(DateTime.now()).inDays;
}
