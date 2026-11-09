import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Android/Windows: cada copia es un archivo propio. Así no se carga todo en memoria al
/// arrancar ni se reescribe un archivo enorme en cada consulta (como pasaría en las
/// preferencias), y la app va igual de rápida con internet.
class AlmacenCache {
  static Directory? _dir;

  static Future<Directory> _carpeta() async {
    if (_dir != null) return _dir!;
    final d = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}copias');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  static Future<File> _archivo(String clave) async => File('${(await _carpeta()).path}${Platform.pathSeparator}$clave');

  static Future<String?> leer(String clave) async {
    final f = await _archivo(clave);
    return await f.exists() ? f.readAsString() : null;
  }

  static Future<void> escribir(String clave, String texto) async {
    // Se escribe en un temporal y se renombra: nunca queda una copia a medias
    final f = await _archivo(clave);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(texto, flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> borrar(String clave) async {
    final f = await _archivo(clave);
    if (await f.exists()) await f.delete();
  }
}
