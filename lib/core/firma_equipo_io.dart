import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart';

/// Firma RSA-SHA256 con el certificado (.pfx) instalado en este equipo, sin internet.
/// Android: KeyStore PKCS12 de Java (MainActivity.kt). Windows: .NET desde PowerShell.
/// PowerShell por su ruta completa (no por el PATH, que podría apuntar a otro programa).
final _rutaPowershell = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}' r'\System32\WindowsPowerShell\v1.0\powershell.exe';

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
    // Rápido: clave en memoria y firma en Dart (sin abrir PowerShell en cada ticket)
    if (_rsaFallo != _huella(p12, clave)) try {
      final k = await _clave(p12, clave);
      final f = _firmarDart(k, datos);
      return f;
    } catch (_) {
      _rsaFallo = _huella(p12, clave); // no se reintenta en cada ticket
    }
    if (!_usarServidor) {
      final f = await _powershell('firmar', p12, clave, datos);
      return base64.decode(f);
    }
    try {
      final f = await _Servidor.firmar(_huella(p12, clave), p12, clave, datos);
      return base64.decode(f);
    } catch (_) {
      // Si el firmador rápido falla, el método de siempre (lento pero seguro)
      final f = await _powershell('firmar', p12, clave, datos);
      return base64.decode(f);
    }
  }

  /// Arranca ya el firmador de Windows para que el primer cobro no espere.
  // Clave privada RSA solo en memoria (nunca en disco); se lee una vez por sesión
  static RSAPrivateKey? _rsa;
  static String? _rsaHuella;
  static Future<RSAPrivateKey>? _cargandoRsa;
  static String? _rsaFallo;

  static BigInt _big(String b64) =>
      base64.decode(b64).fold<BigInt>(BigInt.zero, (a, b) => (a << 8) | BigInt.from(b));

  static Future<RSAPrivateKey> _clave(List<int> p12, String clave) async {
    final h = _huella(p12, clave);
    if (_rsa != null && _rsaHuella == h) return _rsa!;
    if (_cargandoRsa != null) return _cargandoRsa!;
    _cargandoRsa = () async {
      final partes = (await _powershell('clave', p12, clave, const [])).split('|');
      final k = RSAPrivateKey(_big(partes[0]), _big(partes[2]), _big(partes[3]), _big(partes[4]));
      // Comprobación: lo firmado tiene que verificarse con la clave pública
      final prueba = [1, 2, 3, 4];
      final firma = _firmarDart(k, prueba);
      final v = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(false, PublicKeyParameter<RSAPublicKey>(RSAPublicKey(k.modulus!, _big(partes[1]))));
      if (!v.verifySignature(Uint8List.fromList(prueba), RSASignature(Uint8List.fromList(firma)))) {
        throw StateError('la clave leída no verifica');
      }
      _rsa = k;
      _rsaHuella = h;
      return k;
    }();
    try {
      return await _cargandoRsa!;
    } finally {
      _cargandoRsa = null;
    }
  }

  static List<int> _firmarDart(RSAPrivateKey k, List<int> datos) {
    final s = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(k));
    return s.generateSignature(Uint8List.fromList(datos)).bytes;
  }

  /// Firmador en segundo plano: desactivado (en Windows se quedaba sin responder).
  static const _usarServidor = false;

  static void precalentar(List<int> p12, String clave) {
    if (Platform.isWindows) _clave(p12, clave).ignore();
    if (_usarServidor && Platform.isWindows) _Servidor.asegurar(_huella(p12, clave), p12, clave).ignore();
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
if ($env:TBAI_ACCION -eq 'clave') {
  $X = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]
  try { $pp = $X::GetRSAPrivateKey($c).ExportParameters($true) } catch {
    $col = Abrir ($F::UserKeySet -bor $F::Exportable)
    $c = $col | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
    $pp = $X::GetRSAPrivateKey($c).ExportParameters($true)
  }
  $partes = @($pp.Modulus, $pp.Exponent, $pp.D, $pp.P, $pp.Q) | ForEach-Object { [Convert]::ToBase64String($_) }
  [Console]::Out.Write($partes -join '|')
  exit 0
}
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
        _rutaPowershell,
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

/// PowerShell abierto en segundo plano con el certificado ya cargado: arrancar PowerShell
/// tarda 1–3 s, así que se arranca una vez y cada firma es una línea (Base64) por stdin.
class _Servidor {
  static Process? _p;
  static String? _huella;
  static StreamIterator<String>? _lineas;
  static Future<void>? _arrancando;
  static Future<void> _cola = Future.value();

  static const _script = r'''
$ErrorActionPreference = 'Stop'
$F = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]
function Abrir($flags) {
  $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
  $col.Import($env:TBAI_PFX, $env:TBAI_CLAVE, $flags)
  return $col
}
try { $col = Abrir $F::EphemeralKeySet } catch { $col = Abrir ($F::UserKeySet -bor $F::Exportable) }
$c = $col | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
if ($null -eq $c) { throw 'El certificado no contiene la clave privada' }
$H = [System.Security.Cryptography.HashAlgorithmName]::SHA256
$P = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($c)
try { [void]$rsa.SignData([byte[]](1,2,3), $H, $P) } catch {
  $cng = New-Object System.Security.Cryptography.RSACng
  $cng.ImportParameters($rsa.ExportParameters($true))
  $rsa = $cng
}
[Console]::Out.WriteLine('LISTO'); [Console]::Out.Flush()
while ($true) {
  $l = [Console]::In.ReadLine()
  if ($null -eq $l -or $l -eq 'FIN') { break }
  try {
    $f = $rsa.SignData([Convert]::FromBase64String($l), $H, $P)
    [Console]::Out.WriteLine('OK ' + [Convert]::ToBase64String($f))
  } catch { [Console]::Out.WriteLine('ERR ' + $_.Exception.Message) }
  [Console]::Out.Flush()
}
''';

  static Future<void> asegurar(String huella, List<int> p12, String clave) async {
    if (_p != null && _huella == huella) return;
    if (_arrancando != null) return _arrancando;
    _arrancando = _arrancar(huella, p12, clave);
    try {
      await _arrancando;
    } finally {
      _arrancando = null;
    }
  }

  static Future<void> _arrancar(String huella, List<int> p12, String clave) async {
    _p?.kill();
    _p = null;
    final dir = await Directory.systemTemp.createTemp('tbais');
    try {
      final pfx = File('${dir.path}\\c.pfx');
      final ps1 = File('${dir.path}\\s.ps1');
      await pfx.writeAsBytes(p12, flush: true);
      await ps1.writeAsString(_script, flush: true);
      final p = await Process.start(
        _rutaPowershell,
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1.path],
        environment: {'TBAI_PFX': pfx.path, 'TBAI_CLAVE': clave},
      );
      final err = StringBuffer();
      p.stderr.transform(utf8.decoder).listen(err.write);
      final lineas = StreamIterator(p.stdout.transform(utf8.decoder).transform(const LineSplitter()));
      final listo = await lineas.moveNext().timeout(const Duration(seconds: 15), onTimeout: () => false);
      if (!listo || lineas.current.trim() != 'LISTO') {
        p.kill();
        throw StateError('Firma en el equipo: ${err.toString().trim().split('\n').first}');
      }
      _p = p;
      _huella = huella;
      _lineas = lineas;
      p.exitCode.then((_) {
        if (identical(_p, p)) _p = null;
      });
    } finally {
      // El certificado ya está cargado en memoria: el fichero temporal sobra
      dir.delete(recursive: true).ignore();
    }
  }

  /// Una firma cada vez (en cola), por la misma tubería.
  static Future<String> firmar(String huella, List<int> p12, String clave, List<int> datos) {
    final c = Completer<String>();
    _cola = _cola.then((_) async {
      try {
        c.complete(await _firmarUna(huella, p12, clave, datos));
      } catch (e) {
        c.completeError(e);
      }
    });
    return c.future;
  }

  static Future<String> _firmarUna(String huella, List<int> p12, String clave, List<int> datos) async {
    for (var intento = 0; intento < 2; intento++) {
      try {
        await asegurar(huella, p12, clave);
        _p!.stdin.writeln(base64.encode(datos));
        await _p!.stdin.flush();
        final ok = await _lineas!.moveNext().timeout(const Duration(seconds: 5), onTimeout: () => false);
        if (!ok) throw StateError('El firmador no respondió');
        final l = _lineas!.current.trim();
        if (l.startsWith('OK ')) return l.substring(3);
        throw StateError('Firma en el equipo: ${l.startsWith('ERR ') ? l.substring(4) : l}');
      } catch (e) {
        _p?.kill();
        _p = null;
        if (intento == 1) rethrow;
      }
    }
    throw StateError('Firma en el equipo: no disponible');
  }
}
