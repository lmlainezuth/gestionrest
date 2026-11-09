import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import 'almacen_cache.dart' if (dart.library.io) 'almacen_cache_io.dart';
import 'cliente_base.dart' if (dart.library.io) 'cliente_base_io.dart';
import 'config.dart';
import 'red.dart';

/// Sabe si hay conexión con el servidor, sin esperar a que cada pantalla agote su tiempo.
/// Comprueba cada 20 s (cada 5 s mientras no hay conexión) y al primer fallo de red.
class Conexion {
  Conexion._();
  static final enLinea = ValueNotifier<bool>(true);
  static Timer? _timer;
  static final _sonda = clienteBase();

  static void iniciar() {
    if (_timer != null) return;
    comprobar();
    _programar();
  }

  static void _programar() {
    _timer?.cancel();
    _timer = Timer(Duration(seconds: enLinea.value ? 10 : 5), () async {
      await comprobar();
      _programar();
    });
  }

  static Future<bool> comprobar() async {
    var ok = false;
    try {
      final r = await _sonda
          .get(Uri.parse('${Config.supabaseUrl}/auth/v1/health'), headers: {'apikey': Config.supabaseKey})
          .timeout(const Duration(seconds: 4));
      ok = r.statusCode < 500;
    } catch (_) {}
    _poner(ok);
    return ok;
  }

  /// Un fallo de red en cualquier petición: se pasa a "sin conexión" al momento.
  static void sinConexion() => _poner(false);

  static void _poner(bool ok) {
    if (enLinea.value == ok) return;
    enLinea.value = ok;
    _programar();
  }
}

/// Cliente HTTP de Supabase.
/// - Guarda en el equipo la última respuesta de cada consulta de lectura. Sin internet
///   devuelve esa copia: todas las pantallas siguen enseñando sus datos (los últimos vistos).
/// - Sin internet, lo que no está guardado (y las escrituras) falla al instante.
/// - Con internet, corta a los 12 s una petición que no responde.
class ClienteConLimite extends http.BaseClient {
  final _c = clienteBase();

  // Funciones de solo lectura que también se guardan (el resto de /rpc/ escribe o no debe
  // leerse de una copia, como la última factura de la cadena)
  static const _rpcLectura = {'mi_perfil', 'mis_empresas', 'equipo_empresa'};

  static String? _clave(http.BaseRequest r, List<int>? cuerpo) {
    final ruta = r.url.path;
    if (!ruta.contains('/rest/v1/')) return null;
    final rpc = ruta.contains('/rest/v1/rpc/');
    if (r.method == 'GET' && !rpc) {
      // ok
    } else if (r.method == 'POST' && rpc && _rpcLectura.contains(ruta.split('/').last)) {
      // ok
    } else {
      return null;
    }
    final usuario = supabase.auth.currentUser?.id ?? '-';
    final h = r.headers;
    final base = [
      usuario,
      r.method,
      r.url.toString(),
      h['Accept'] ?? h['accept'] ?? '',
      h['Prefer'] ?? h['prefer'] ?? '',
      h['Range'] ?? h['range'] ?? '',
      if (cuerpo != null) utf8.decode(cuerpo, allowMalformed: true),
    ].join('|');
    return 'http_${sha1.convert(utf8.encode(base))}';
  }

  static http.StreamedResponse _respuesta(Map<String, dynamic> g, http.BaseRequest r) {
    final bytes = utf8.encode(g['cuerpo'] as String);
    return http.StreamedResponse(
      Stream.value(bytes),
      g['estado'] as int,
      contentLength: bytes.length,
      request: r,
      headers: Map<String, String>.from(g['cabeceras'] as Map),
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    List<int>? cuerpo;
    if (request is http.Request) cuerpo = request.bodyBytes;
    final clave = _clave(request, request.method == 'POST' ? cuerpo : null);

    Future<http.StreamedResponse> copiaOError(Object e) async {
      if (clave != null) {
        final g = await CacheLectura.leer(clave);
        if (g != null) return _respuesta(g, request);
      }
      throw e;
    }

    if (!Conexion.enLinea.value) {
      return copiaOError(http.ClientException('Sin conexión (SocketException)', request.url));
    }
    final http.StreamedResponse r;
    try {
      r = await _c.send(request).timeout(const Duration(seconds: 10));
    } catch (e) {
      if (!esErrorDeRed(e)) rethrow;
      Conexion.sinConexion();
      return copiaOError(e);
    }
    // 200/206 = datos; 406 = "ninguna fila" de maybeSingle() (p. ej. caja sin turno abierto),
    // que también hay que recordar para que la pantalla cargue igual sin internet
    if (clave == null || !(r.statusCode == 200 || r.statusCode == 206 || r.statusCode == 406)) return r;
    // Lectura correcta: se guarda una copia y se devuelve igual
    final bytes = await r.stream.toBytes();
    final texto = utf8.decode(bytes, allowMalformed: true);
    CacheLectura.guardar(clave, {'estado': r.statusCode, 'cabeceras': r.headers, 'cuerpo': texto}).ignore();
    return http.StreamedResponse(
      Stream.value(bytes),
      r.statusCode,
      contentLength: bytes.length,
      request: request,
      headers: r.headers,
      reasonPhrase: r.reasonPhrase,
    );
  }

  @override
  void close() => _c.close();
}

/// Copias de las lecturas, en el equipo: como mucho 8 MB en total y 2 MB por consulta.
/// Solo se escribe si la respuesta cambió (no ralentiza el equipo).
class CacheLectura {
  static const _kIndice = 'copias_indice';
  static const _maxTotal = 8000000, _maxUna = 2000000;
  static Map<String, dynamic>? _indice; // clave -> {n: tamaño, h: huella}
  static Future<void>? _preparado;

  static Future<Map<String, dynamic>> _cargarIndice() async {
    final p = await SharedPreferences.getInstance();
    // Versión anterior: copias dentro de las preferencias (lentas). Se borran una vez.
    _preparado ??= () async {
      final viejas = p.getKeys().where((k) => k.startsWith('http_')).toList();
      for (final k in viejas) {
        await p.remove(k);
      }
    }();
    await _preparado;
    return _indice ??= Map<String, dynamic>.from(jsonDecode(p.getString(_kIndice) ?? '{}') as Map);
  }

  static Future<Map<String, dynamic>?> leer(String clave) async {
    try {
      final s = await AlmacenCache.leer(clave);
      return s == null ? null : Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> guardar(String clave, Map<String, dynamic> datos) async {
    try {
      final texto = jsonEncode(datos);
      if (texto.length > _maxUna) return;
      final indice = await _cargarIndice();
      final huella = '${texto.length}:${texto.hashCode}';
      if ((indice[clave] as Map?)?['h'] == huella) return; // igual que la guardada
      await AlmacenCache.escribir(clave, texto);
      indice
        ..remove(clave)
        ..[clave] = {'n': texto.length, 'h': huella}; // al final = la más reciente
      var total = indice.values.fold<int>(0, (a, v) => a + ((v as Map)['n'] as int));
      while (total > _maxTotal && indice.length > 1) {
        final vieja = indice.keys.first;
        total -= (indice.remove(vieja) as Map)['n'] as int;
        await AlmacenCache.borrar(vieja);
      }
      await (await SharedPreferences.getInstance()).setString(_kIndice, jsonEncode(indice));
    } catch (_) {}
  }
}

/// Ejecuta una carga: con conexión nunca tarda más de [limite] (así ninguna pantalla se
/// queda cargando). Sin conexión, las lecturas salen de la copia del equipo.
Future<T> online<T>(Future<T> Function() f, {Duration limite = const Duration(seconds: 15)}) async {
  try {
    return await f().timeout(limite);
  } catch (e) {
    if (esErrorDeRed(e)) Conexion.sinConexion();
    rethrow;
  }
}

/// Para lo que solo tiene sentido con conexión real (no con la copia): falla al momento.
void exigirConexion() {
  if (!Conexion.enLinea.value) throw http.ClientException('Sin conexión (SocketException)');
}
