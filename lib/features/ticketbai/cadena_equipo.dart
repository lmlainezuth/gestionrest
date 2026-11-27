import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Serie propia de este equipo (por ejemplo "B1" en el TPV de barra) y última factura de su
/// cadena. Un equipo que cobra sin internet necesita una serie que SOLO use él: así su cadena
/// nunca se cruza con la de otro equipo (FAQ Gipuzkoa: varios dispositivos, cada uno su serie).
/// Mientras hay conexión manda la base de datos; esto guarda la última por si se va internet.
class CadenaEquipo {
  static const _kSerie = 'tbai_serie_equipo', _kUltima = 'tbai_ultima_equipo', _kNumeros = 'tbai_numeros_equipo';

  static Future<String?> serie() async {
    final s = (await SharedPreferences.getInstance()).getString(_kSerie);
    return s == null || s.isEmpty ? null : s;
  }

  static Future<void> guardarSerie(String? serie) async {
    final p = await SharedPreferences.getInstance();
    final s = serie?.trim().toUpperCase() ?? '';
    if (s.isEmpty) {
      await p.remove(_kSerie);
    } else if (s != p.getString(_kSerie)) {
      await p.setString(_kSerie, s);
      // Serie nueva: lo guardado de la anterior ya no vale
      await p.remove(_kUltima);
      await p.remove(_kNumeros);
    }
  }

  /// Última factura de la cadena de este equipo: {id, serie, numero, fecha, firma}.
  static Future<Map<String, dynamic>?> ultima() async {
    final s = (await SharedPreferences.getInstance()).getString(_kUltima);
    return s == null ? null : Map<String, dynamic>.from(jsonDecode(s) as Map);
  }

  /// Siguiente número de una serie de este equipo (sin internet).
  static Future<int?> ultimoNumero(String serie) async {
    final s = (await SharedPreferences.getInstance()).getString(_kNumeros);
    if (s == null) return null;
    return (jsonDecode(s) as Map)[serie] as int?;
  }

  /// Apunta una factura emitida por este equipo como la última de su cadena.
  static Future<void> registrar(Map<String, dynamic> f) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kUltima,
        jsonEncode({
          'id': f['id'],
          'serie': f['serie'],
          'numero': f['numero'],
          'fecha': f['fecha'],
          'firma': f['firma'],
        }));
    final numeros = Map<String, dynamic>.from(jsonDecode(p.getString(_kNumeros) ?? '{}') as Map);
    final n = f['numero'] as int;
    if (((numeros[f['serie']] as int?) ?? 0) < n) numeros[f['serie'] as String] = n;
    await p.setString(_kNumeros, jsonEncode(numeros));
  }

  /// Con conexión y sin ventas pendientes de subir: deja la copia local EXACTAMENTE igual que la
  /// base de datos del bar actual. Si el equipo cambió de bar, lo del anterior no se arrastra
  /// (si no, la primera factura sin internet encadenaría con una factura del otro bar).
  static Future<void> sincronizarCon(Map<String, dynamic>? ultimaBd, Map<String, int> numerosBd) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kUltima);
    await p.setString(_kNumeros, jsonEncode(numerosBd));
    if (ultimaBd != null) await registrar(ultimaBd);
  }
}
