import 'package:shared_preferences/shared_preferences.dart';

/// Web: las copias van al almacenamiento del navegador.
class AlmacenCache {
  static Future<String?> leer(String clave) async => (await SharedPreferences.getInstance()).getString('c_$clave');
  static Future<void> escribir(String clave, String texto) async =>
      (await SharedPreferences.getInstance()).setString('c_$clave', texto);
  static Future<void> borrar(String clave) async => (await SharedPreferences.getInstance()).remove('c_$clave');
}
