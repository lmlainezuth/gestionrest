import 'package:shared_preferences/shared_preferences.dart';

/// Empresa (bar) con la que trabaja este equipo: decide qué equipo
/// aparece en la pantalla de entrada con PIN.
class EmpresaDispositivo {
  static const _clave = 'empresa_dispositivo';

  static Future<String?> leer() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_clave);
    } catch (_) {
      return null;
    }
  }

  static Future<void> guardar(String id) async =>
      (await SharedPreferences.getInstance()).setString(_clave, id);
}
