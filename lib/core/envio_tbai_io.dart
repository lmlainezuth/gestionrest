import 'dart:convert';
import 'dart:io';

/// Envía el XML firmado a Hacienda autenticándose con el certificado (.pfx) de este equipo.
///
/// El servidor de Hacienda pide el certificado con una "renegociación" TLS, que el motor
/// de Flutter (BoringSSL) no admite. En Windows se usa curl.exe, que viene con Windows y
/// usa el sistema de seguridad de Windows (sí la admite).
Future<(int, String)> enviarConCertificado(String url, String xml, List<int> p12, String clave) async {
  if (Platform.isWindows) return _conCurl(url, xml, p12, clave);
  return _conDart(url, xml, p12, clave);
}

Future<(int, String)> _conCurl(String url, String xml, List<int> p12, String clave) async {
  final dir = await Directory.systemTemp.createTemp('tbai');
  try {
    final pfx = File('${dir.path}\\c.pfx');
    final cuerpo = File('${dir.path}\\f.xml');
    await pfx.writeAsBytes(p12, flush: true);
    await cuerpo.writeAsBytes(utf8.encode(xml), flush: true);
    final r = await Process.run('curl.exe', [
      '-sS',
      '--max-time', '40',
      '--cert-type', 'P12',
      '--cert', '${pfx.path}:${clave.replaceAll(':', r'\:')}',
      '-H', 'Content-Type: application/xml;charset=UTF-8',
      '--data-binary', '@${cuerpo.path}',
      '-w', '\n__HTTP__%{http_code}',
      url,
    ], stdoutEncoding: utf8, stderrEncoding: utf8);
    final out = '${r.stdout}';
    final i = out.lastIndexOf('__HTTP__');
    if (r.exitCode != 0 || i < 0) {
      throw StateError('curl (${r.exitCode}): ${'${r.stderr}'.trim()}');
    }
    return (int.tryParse(out.substring(i + 8).trim()) ?? 0, out.substring(0, i).trim());
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<(int, String)> _conDart(String url, String xml, List<int> p12, String clave) async {
  final contexto = SecurityContext(withTrustedRoots: true)
    ..useCertificateChainBytes(p12, password: clave)
    ..usePrivateKeyBytes(p12, password: clave);
  final cliente = HttpClient(context: contexto)..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await cliente.postUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/xml;charset=UTF-8');
    final cuerpo = utf8.encode(xml);
    req.contentLength = cuerpo.length;
    req.add(cuerpo);
    final r = await req.close().timeout(const Duration(seconds: 30));
    final texto = await r.transform(utf8.decoder).join();
    return (r.statusCode, texto);
  } finally {
    cliente.close(force: true);
  }
}
