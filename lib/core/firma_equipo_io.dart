import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Firma RSA-SHA256 con el certificado (.pfx) instalado en este equipo, sin internet.
/// Android: KeyStore PKCS12 de Java (MainActivity.kt). Windows: .NET desde PowerShell.
class FirmaEquipo {
  static const _canal = MethodChannel('gestionrest/firma');

  static bool get soportada => Platform.isAndroid || Platform.isWindows;

  // El certificado no cambia entre tickets: se guarda en memoria
  static String? _claveCache;
  static ({String der, String titular, DateTime caduca})? _certCache;

  static String _huella(List<int> p12, String clave) => '${p12.length}:${p12.fold<int>(0, (a, b) => (a * 31 + b) & 0x3FFFFFFF)}:$clave';

  /// Certificado de firma (DER en Base64), titular y caducidad. Comprueba también la contraseña.
  static Future<({String der, String titular, DateTime caduca})> certificado(List<int> p12, String clave) async {
    final h = _huella(p12, clave);
    if (_claveCache == h && _certCache != null) return _certCache!;
    final ({String der, String titular, DateTime caduca}) c;
    if (Platform.isAndroid) {
      final r = Map<String, dynamic>.from(
          await _canal.invokeMethod('certificado', {'p12': Uint8List.fromList(p12), 'clave': clave}) as Map);
      c = (
        der: base64.encode(r['der'] as Uint8List),
        titular: r['titular'] as String,
        caduca: DateTime.fromMillisecondsSinceEpoch(r['caduca'] as int),
      );
    } else {
      final out = await _powershell('cert', p12, clave, const []);
      final partes = out.split('|');
      c = (der: partes[0], titular: partes[1], caduca: DateTime.parse(partes[2]));
    }
    _claveCache = h;
    _certCache = c;
    return c;
  }

  static Future<List<int>> firmar(List<int> p12, String clave, List<int> datos) async {
    if (Platform.isAndroid) {
      final r = await _canal.invokeMethod('firmar',
          {'p12': Uint8List.fromList(p12), 'clave': clave, 'datos': Uint8List.fromList(datos)});
      return r as Uint8List;
    }
    return base64.decode(await _powershell('firmar', p12, clave, datos));
  }

  static const _script = r'''
$ErrorActionPreference = 'Stop'
$F = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]
function Abrir($flags) {
  $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
  $col.Import($env:TBAI_PFX, $env:TBAI_CLAVE, $flags)
  return $col
}
# Primero en memoria (claves CNG, admiten SHA-256); si no, en el almacén del usuario
try { $col = Abrir $F::EphemeralKeySet } catch { $col = Abrir ($F::UserKeySet -bor $F::Exportable) }
$c = $col | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
if ($null -eq $c) { throw 'El certificado no contiene la clave privada' }
if ($env:TBAI_ACCION -eq 'cert') {
  [Console]::Out.Write([Convert]::ToBase64String($c.RawData) + '|' + $c.Subject + '|' + $c.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
  exit 0
}
$datos = [IO.File]::ReadAllBytes($env:TBAI_DATOS)
$H = [System.Security.Cryptography.HashAlgorithmName]::SHA256
$P = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($c)
try {
  $f = $rsa.SignData($datos, $H, $P)
} catch {
  # Proveedor antiguo (CAPI) sin SHA-256: se copia la clave a CNG y se firma ahí
  $cng = New-Object System.Security.Cryptography.RSACng
  $cng.ImportParameters($rsa.ExportParameters($true))
  $f = $cng.SignData($datos, $H, $P)
}
[Console]::Out.Write([Convert]::ToBase64String($f))
''';

  static Future<String> _powershell(String accion, List<int> p12, String clave, List<int> datos) async {
    final dir = await Directory.systemTemp.createTemp('tbaif');
    try {
      final pfx = File('${dir.path}\\c.pfx');
      final dat = File('${dir.path}\\d.bin');
      final ps1 = File('${dir.path}\\f.ps1');
      await pfx.writeAsBytes(p12, flush: true);
      await dat.writeAsBytes(datos, flush: true);
      await ps1.writeAsString(_script, flush: true);
      final r = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1.path],
        environment: {'TBAI_PFX': pfx.path, 'TBAI_CLAVE': clave, 'TBAI_DATOS': dat.path, 'TBAI_ACCION': accion},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final out = '${r.stdout}'.trim();
      if (r.exitCode != 0 || out.isEmpty) {
        throw StateError('Firma en el equipo: ${'${r.stderr}'.trim().split('\n').first}');
      }
      return out;
    } finally {
      await dir.delete(recursive: true);
    }
  }
}
