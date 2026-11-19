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
///
/// Si el equipo no tiene un almacén seguro que funcione (pasa en algunos TPV), se guarda
/// como antes, sin cifrar, para que pueda seguir firmando sin internet.
class CertificadoEquipo {
  static const _kCifrado = 'tbai_pfx_cifrado', _kNombre = 'tbai_pfx_nombre';
  static const _kLlave = 'tbai_pfx_llave', _kClave = 'tbai_pfx_clave';
  static const _kAntiguo = 'tbai_pfx'; // sin cifrar (formato anterior o equipo sin almacén seguro)
  static const _kSinAlmacen = 'tbai_pfx_sin_almacen';

  // Llave AES del Android Keystore en vez de un par RSA: algunos TPV no pueden crear claves
  // RSA OAEP con SHA-256 (lo que usa el paquete por defecto) y fallan con "Failed to generate key pair".
  static final _seguro = FlutterSecureStorage(
    aOptions: AndroidOptions(
      keyCipherAlgorithm: KeyCipherAlgorithm.AES_GCM_NoPadding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
    ),
  );

  /// true si en este equipo el certificado está guardado cifrado.
  static Future<bool> estaCifrado() async =>
      (await SharedPreferences.getInstance()).getString(_kCifrado) != null;

  static Future<void> guardar(List<int> bytes, String clave, String nombre) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kNombre, nombre);
    try {
      final llave = _aleatorio(32);
      await _seguro.write(key: _kLlave, value: base64.encode(llave));
      await _seguro.write(key: _kClave, value: clave);
      await p.setString(_kCifrado, base64.encode(_aes(true, llave, bytes)));
      await p.remove(_kAntiguo);
      await p.remove(_kClave);
      await p.remove(_kSinAlmacen);
    } catch (_) {
      // El almacén seguro de este equipo no funciona: se guarda sin cifrar, como antes
      await _borrarSeguro();
      await p.remove(_kCifrado);
      await p.setString(_kAntiguo, base64.encode(bytes));
      await p.setString(_kClave, clave);
      await p.setBool(_kSinAlmacen, true);
    }
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
    final antiguo = p.getString(_kAntiguo);
    if (antiguo == null) return null;
    final bytes = base64.decode(antiguo);
    final clave = p.getString(_kClave) ?? '';
    // Formato anterior: se intenta cifrar una vez (si el equipo no puede, se queda como está)
    if (!(p.getBool(_kSinAlmacen) ?? false)) await guardar(bytes, clave, nombre);
    return (bytes: bytes, clave: clave, nombre: nombre);
  }

  static Future<void> quitar() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [_kCifrado, _kNombre, _kAntiguo, _kClave, _kSinAlmacen]) {
      await p.remove(k);
    }
    await _borrarSeguro();
  }

  static Future<void> _borrarSeguro() async {
    try {
      await _seguro.delete(key: _kLlave);
      await _seguro.delete(key: _kClave);
    } catch (_) {}
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
