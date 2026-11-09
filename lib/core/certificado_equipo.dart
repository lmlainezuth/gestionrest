import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Certificado (.pfx) guardado en este equipo para enviar las facturas a Hacienda.
/// La firma la hace el servidor; el envío necesita el certificado para la conexión segura.
class CertificadoEquipo {
  static const _kArchivo = 'tbai_pfx', _kClave = 'tbai_pfx_clave', _kNombre = 'tbai_pfx_nombre';

  static Future<void> guardar(List<int> bytes, String clave, String nombre) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kArchivo, base64.encode(bytes));
    await p.setString(_kClave, clave);
    await p.setString(_kNombre, nombre);
  }

  static Future<({List<int> bytes, String clave, String nombre})?> leer() async {
    final p = await SharedPreferences.getInstance();
    final a = p.getString(_kArchivo);
    if (a == null) return null;
    return (bytes: base64.decode(a), clave: p.getString(_kClave) ?? '', nombre: p.getString(_kNombre) ?? 'certificado');
  }

  static Future<void> quitar() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kArchivo);
    await p.remove(_kClave);
    await p.remove(_kNombre);
  }
}
