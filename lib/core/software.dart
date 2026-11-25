import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import 'software_privado.dart';

/// Datos del software TicketBAI. Son del programa (iguales en todas las empresas)
/// y van en cada factura y en la pantalla de verificación presencial (art. 8 OF 521/2020).
/// Si se cambia la versión, hay que comunicarlo en el Registro de Software TicketBAI.
///
/// Nombre y NIF del desarrollador y las licencias se cambian en Ajustes › Programa (solo el
/// programador; tabla `programa`, migración 0030). Lo de aquí abajo es lo que vale si esa tabla
/// está vacía o no se puede leer; el equipo guarda una copia para facturar sin internet.
class Software {
  static const nombre = 'GestionRest';
  static const version = '1.0';

  /// Va en software_privado.dart (fuera de git). Si falta, no compila: copiar software_privado.dart.ejemplo.
  static String nifDesarrollador = nifDesarrolladorPrivado;
  static String nombreDesarrollador = 'LEVIN MAURICIO LAINEZ AGUIRRE';

  /// Licencia TicketBAI del programa: la da Hacienda al software, es la misma en todos los bares.
  static String licenciaPruebas = 'TBAIGIPRE00000001337';
  /// La definitiva, cuando Hacienda inscriba el software. Mientras esté vacía no se puede pasar a producción.
  static String licenciaProduccion = '';

  /// ¿El usuario que ha entrado puede cambiar estos datos? (Ajustes › Programa)
  static bool esProgramador = false;

  static const _kCopia = 'datos_programa';

  /// Lo guardado en el equipo (al arrancar, antes de tener conexión).
  static Future<void> cargarCopia() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(_kCopia);
      if (s != null) _aplicar(Map<String, dynamic>.from(jsonDecode(s) as Map));
    } catch (_) {}
  }

  /// Lee los datos del programa del servidor y guarda una copia en el equipo.
  static Future<void> cargar() async {
    try {
      final fila = await supabase.from('programa').select().maybeSingle();
      if (fila != null) {
        _aplicar(fila);
        await (await SharedPreferences.getInstance()).setString(_kCopia, jsonEncode(fila));
      }
      esProgramador = await supabase.rpc('es_programador') == true;
    } catch (_) {
      // Sin internet o sin la migración 0030: se sigue con la copia o con lo de serie
    }
  }

  static void _aplicar(Map<String, dynamic> f) {
    String? v(String k) {
      final x = (f[k] as String?)?.trim() ?? '';
      return x.isEmpty ? null : x;
    }

    nombreDesarrollador = v('nombre_desarrollador') ?? nombreDesarrollador;
    nifDesarrollador = v('nif_desarrollador') ?? nifDesarrollador;
    licenciaPruebas = v('licencia_pruebas') ?? licenciaPruebas;
    licenciaProduccion = v('licencia_produccion') ?? '';
  }

  /// Pone en la configuración del bar la licencia y el NIF del desarrollador del programa.
  /// Son del software, no de cada bar: no se escriben en Ajustes › Empresa (lo guardado allí se ignora).
  static Map<String, dynamic> completar(Map<String, dynamic> config) {
    final licencia = config['entorno'] == 'produccion' ? licenciaProduccion : licenciaPruebas;
    return {
      ...config,
      'licencia_tbai': licencia.isEmpty ? null : licencia,
      'nif_desarrollador': nifDesarrollador,
    };
  }

  /// Art. 8.d (OF 64/2026, desde 1/1/2027): declaración responsable visible en la verificación presencial.
  static String get declaracionResponsable =>
      'La persona desarrolladora del software $nombre ($nombreDesarrollador, NIF $nifDesarrollador) '
      'manifiesta que, al inscribir la declaración responsable en el Registro de Software TicketBAI de la '
      'Diputación Foral de Gipuzkoa, este software cumple de forma incondicionada, sin salvedad ni reserva '
      'alguna, todas las condiciones y requisitos establecidos en la normativa tributaria vigente relativa '
      'al sistema informático TicketBAI.';
}
