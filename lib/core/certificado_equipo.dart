import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Certificado (.pfx) del titular instalado en este equipo (firma sin internet y envío).
///
/// Se guarda cifrado: el .pfx va en las preferencias cifrado con AES-256-GCM, y la llave de
/// ese cifrado y la contraseña del certificado van en el almacén seguro del sistema
/// (Android Keystore; en Windows, el almacén de credenciales). Copiar las preferencias del
/// equipo no sirve de nada sin ese almacén.
class CertificadoEquipo {
  static const _kCifrado = 'tbai_pfx_cifrado', _kNombre = 'tbai_pfx_nombre';
  static const _kLlave = 'tbai_pfx_llave', _kClave = 'tbai_pfx_clave';
  static const _kAntiguo = 'tbai_pfx'; // formato anterior, sin cifrar (se migra solo)
  static const _seguro = FlutterSecureStorage();

  static Future<void> guardar(List<int> bytes, String clave, String nombre) async {
    final p = await SharedPreferences.getInstance();
    final llave = _aleatorio(32);
    await _seguro.write(key: _kLlave, value: base64.encode(llave));
    await _seguro.write(key: _kClave, value: clave);
    await p.setString(_kCifrado, base64.encode(_aes(true, llave, bytes)));
    await p.setString(_kNombre, nombre);
    // Lo del formato anterior (sin cifrar) se borra
    await p.remove(_kAntiguo);
    await p.remove(_kClave);
  }

  static Future<({List<int> bytes, String clave, String nombre})?> leer() async {
    final p = await SharedPreferences.getInstance();
    final nombre = p.getString(_kNombre) ?? 'certificado';
    final cifrado = p.getString(_kCifrado);
    if (cifrado != null) {
      try {
        final llave = await _seguro.read(key: _kLlave);
        if (llave == null) return null; // se perdió el almacén seguro: hay que volver a instalarlo
        final bytes = _aes(false, base64.decode(llave), base64.decode(cifrado));
        return (bytes: bytes, clave: await _seguro.read(key: _kClave) ?? '', nombre: nombre);
      } catch (_) {
        return null; // no se puede leer o descifrar: hay que volver a instalarlo
      }
    }
    // Formato anterior (sin cifrar): se pasa al cifrado y se borra
    final antiguo = p.getString(_kAntiguo);
    if (antiguo == null) return null;
    final bytes = base64.decode(antiguo);
    final clave = p.getString(_kClave) ?? '';
    await guardar(bytes, clave, nombre);
    return (bytes: bytes, clave: clave, nombre: nombre);
  }

  static Future<void> quitar() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [_kCifrado, _kNombre, _kAntiguo, _kClave]) {
      await p.remove(k);
    }
    await _seguro.delete(key: _kLlave);
    await _seguro.delete(key: _kClave);
  }

  static Uint8List _aleatorio(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  /// AES-256-GCM. Resultado del cifrado: nonce (12 bytes) + texto cifrado + etiqueta (16 bytes).
  static Uint8List _aes(bool cifrar, List<int> llave, List<int> datos) {
    final gcm = GCMBlockCipher(AESEngine());
    final k = KeyParameter(Uint8List.fromList(llave));
    if (cifrar) {
      final nonce = _aleatorio(12);
      gcm.init(true, AEADParameters(k, 128, nonce, Uint8List(0)));
      return Uint8List.fromList([...nonce, ...gcm.process(Uint8List.fromList(datos))]);
    }
    final d = Uint8List.fromList(datos);
    gcm.init(false, AEADParameters(k, 128, d.sublist(0, 12), Uint8List(0)));
    return gcm.process(d.sublist(12));
  }
}
