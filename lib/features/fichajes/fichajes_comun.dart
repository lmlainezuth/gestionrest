import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../main.dart';

const nombresFichaje = {'entrada': 'Entrada', 'pausa': 'Pausa', 'vuelta': 'Vuelta de pausa', 'salida': 'Salida'};

String hora(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String horasMin(int min) => '${min ~/ 60} h ${(min % 60).toString().padLeft(2, '0')} min';
DateTime momento(Map<String, dynamic> f) => DateTime.parse(f['momento'] as String).toLocal();
String diaClave(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Lo que cuenta: sin las anulaciones ni los registros que otra corrección sustituye.
List<Map<String, dynamic>> vigentes(List<Map<String, dynamic>> todos) {
  final sustituidos = {for (final f in todos) if (f['corrige_id'] != null) f['corrige_id']};
  return [for (final f in todos) if (f['anula'] != true && !sustituidos.contains(f['id'])) f]
    ..sort((a, b) => momento(a).compareTo(momento(b)));
}

/// Una jornada: desde una entrada hasta su salida (se cuenta en el día de la entrada).
class Jornada {
  Jornada(this.dia);
  final String dia;
  final registros = <Map<String, dynamic>>[];
  DateTime? entrada, salida;
  int minutos = 0, pausa = 0;
  bool get abierta => salida == null;
}

/// Agrupa en jornadas los fichajes vigentes de UNA persona, ordenados por hora.
/// Si [ahora] se pasa, la jornada abierta cuenta hasta ahora.
List<Jornada> jornadas(List<Map<String, dynamic>> regs, {DateTime? ahora}) {
  final r = <Jornada>[];
  Jornada? j;
  DateTime? trabajando, enPausa;
  for (final f in regs) {
    final t = momento(f);
    final tipo = f['tipo'] as String;
    if (tipo == 'entrada' || j == null) {
      j = Jornada(diaClave(t));
      r.add(j);
      trabajando = enPausa = null;
    }
    j.registros.add(f);
    switch (tipo) {
      case 'entrada':
        j.entrada = t;
        trabajando = t;
      case 'vuelta':
        if (enPausa != null) j.pausa += t.difference(enPausa).inMinutes;
        enPausa = null;
        trabajando = t;
      case 'pausa':
        if (trabajando != null) j.minutos += t.difference(trabajando).inMinutes;
        trabajando = null;
        enPausa = t;
      case 'salida':
        if (trabajando != null) j.minutos += t.difference(trabajando).inMinutes;
        trabajando = enPausa = null;
        j.salida = t;
        j = null;
    }
  }
  if (j != null && trabajando != null && ahora != null) j.minutos += ahora.difference(trabajando).inMinutes;
  return r;
}

/// Último tipo fichado (para saber qué botones enseñar).
String ultimoTipo(List<Map<String, dynamic>> regs) => regs.isEmpty ? 'salida' : regs.last['tipo'] as String;

class FichajeError implements Exception {
  FichajeError(this.mensaje);
  final String mensaje;
  @override
  String toString() => mensaje;
}

/// Fichar desde el TPV. Sin internet se guarda en el equipo con su hora y se sube después
/// (el PIN se comprueba al subirlo).
class FichajeService {
  static const _kCola = 'fichajes_cola';
  static bool _iniciado = false, _subiendo = false;
  static String? ultimoError;

  static void iniciar() {
    if (_iniciado) return;
    _iniciado = true;
    Conexion.enLinea.addListener(() {
      if (Conexion.enLinea.value) subir();
    });
    subir();
  }

  static String _mensaje(Object e) => e is PostgrestException ? e.message : '$e';

  static Future<Map<String, dynamic>> estado(String empresa, String usuario, String pin) async {
    final r = Map<String, dynamic>.from(await supabase
        .rpc('fichaje_estado', params: {'p_empresa': empresa, 'p_usuario': usuario, 'p_pin': pin}) as Map);
    if (r['error'] != null) throw FichajeError(r['error'] as String);
    return r;
  }

  /// true = registrado en el servidor; false = guardado en el equipo (sin internet).
  static Future<bool> fichar(String empresa, String usuario, String pin, String tipo) async {
    try {
      exigirConexion();
      final r = Map<String, dynamic>.from(await supabase.rpc('fichar',
          params: {'p_empresa': empresa, 'p_usuario': usuario, 'p_pin': pin, 'p_tipo': tipo}) as Map);
      if (r['error'] != null) throw FichajeError(r['error'] as String);
      return true;
    } on FichajeError {
      rethrow;
    } catch (e) {
      if (!esErrorDeRed(e)) throw FichajeError(_mensaje(e));
      final p = await SharedPreferences.getInstance();
      final cola = await pendientes();
      cola.add({
        'p_empresa': empresa,
        'p_usuario': usuario,
        'p_pin': pin,
        'p_tipo': tipo,
        'p_momento': DateTime.now().toUtc().toIso8601String(),
      });
      await p.setString(_kCola, jsonEncode(cola));
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> pendientes() async {
    final s = (await SharedPreferences.getInstance()).getString(_kCola);
    if (s == null) return [];
    return List<Map<String, dynamic>>.from((jsonDecode(s) as List).map((e) => Map<String, dynamic>.from(e as Map)));
  }

  /// Sube en orden lo guardado sin internet. Lo que el servidor rechaza no se reintenta.
  static Future<void> subir() async {
    if (_subiendo || !Conexion.enLinea.value) return;
    _subiendo = true;
    try {
      final p = await SharedPreferences.getInstance();
      var cola = await pendientes();
      while (cola.isNotEmpty) {
        try {
          final r = Map<String, dynamic>.from(await supabase.rpc('fichar', params: cola.first) as Map);
          if (r['error'] != null) ultimoError = 'Fichaje sin internet rechazado: ${r['error']}';
        } catch (e) {
          if (esErrorDeRed(e)) break;
          ultimoError = 'Fichaje sin internet rechazado: ${_mensaje(e)}';
        }
        cola = cola.sublist(1);
        await p.setString(_kCola, jsonEncode(cola));
      }
    } finally {
      _subiendo = false;
    }
  }
}
