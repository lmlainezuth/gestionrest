import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Firma RSA-SHA256 (PKCS#1 v1.5) de unos bytes con la clave privada del certificado.
typedef FirmadorRsa = Future<List<int>> Function(List<int> datos);

/// Firma XAdES-EPES "enveloped" de un fichero TicketBAI hecha en el propio equipo, sin
/// internet. Produce la misma estructura que la Edge Function (xadesjs), que Hacienda acepta:
/// C14N 1.0 inclusiva, RSA-SHA256, SigningCertificateV2 y la política de firma de Gipuzkoa.
///
/// La canonicalización no es genérica: el XML de [TbaiXml] se genera ya en forma canónica
/// (sin declaración de atributos salvo el espacio de nombres raíz, sin etiquetas vacías
/// abreviadas, sin comillas escapadas ni caracteres de control), así que sus bytes son los
/// que se resumen. Los nodos de la firma se escriben a mano en forma canónica y, para
/// SignedInfo y SignedProperties, con los espacios de nombres heredados que añade la C14N
/// inclusiva, ordenados por prefijo.
class FirmaXades {
  static const _ds = 'http://www.w3.org/2000/09/xmldsig#';
  static const _xades = 'http://uri.etsi.org/01903/v1.3.2#';
  static const _c14n = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315';
  static const _rsaSha256 = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256';
  static const _sha256 = 'http://www.w3.org/2001/04/xmlenc#sha256';
  static const _enveloped = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature';
  static const _tipoSignedProperties = 'http://uri.etsi.org/01903#SignedProperties';
  static const politicaUrl = 'https://www.gipuzkoa.eus/ticketbai/sinadura';
  static const politicaHash = '4LDJbY5hqHHHX858s9QV1P8yVGzo6H23P/iNRRv+PnQ=';

  static Future<({String xml, String signatureValue})> firmar(
    String xml, {
    required String certificadoBase64, // DER del certificado de firma, en Base64
    required FirmadorRsa firmarRsa,
    DateTime? ahora,
    String? id,
  }) async {
    // 1 · Documento sin la declaración XML (la C14N la quita)
    var doc = xml.trim();
    if (doc.startsWith('<?xml')) doc = doc.substring(doc.indexOf('?>') + 2);
    final raiz = RegExp(r'^<(\w+):(\w+) xmlns:(\w+)="([^"]+)">').firstMatch(doc);
    if (raiz == null || raiz.group(1) != raiz.group(3)) {
      throw const FormatException('Firma local: el XML no empieza por <T:... xmlns:T="...">');
    }
    final prefijo = raiz.group(1)!;
    final nsRaiz = raiz.group(4)!;
    final cierre = '</$prefijo:${raiz.group(2)}>';
    if (!doc.endsWith(cierre)) throw const FormatException('Firma local: falta la etiqueta de cierre');
    // Garantías de forma canónica (si fallan, no se firma: mejor un error que una firma inválida)
    // (el texto lleva < y > escapados, así que todo <...> es una etiqueta; solo la raíz tiene atributos)
    if (RegExp(r'<[^>\s]+\s[^>]*>').allMatches(doc).length != 1 ||
        doc.contains('/>') ||
        doc.contains('&quot;') ||
        doc.contains('&apos;') ||
        doc.contains('&#') ||
        doc.contains('<!') ||
        doc.contains('<?') ||
        RegExp(r'[\x00-\x08\x0B-\x1F\x7F]').hasMatch(doc) ||
        doc.contains('\r') ||
        doc.contains('\t') ||
        doc.contains('\n')) {
      throw const FormatException('Firma local: el XML no está en forma canónica');
    }

    String b64Sha(List<int> bytes) => base64.encode(sha256.convert(bytes).bytes);
    final cert = certificadoBase64.replaceAll(RegExp(r'\s'), '');
    final idFirma = id ?? 'id-${_hex(6)}';
    final hora = _hora((ahora ?? DateTime.now()).toUtc());

    // Espacios de nombres en scope que la C14N inclusiva pone en el elemento raíz del subconjunto
    String ns(Map<String, String> m) {
      final claves = m.keys.toList()..sort();
      return claves.map((k) => 'xmlns:$k="${m[k]}"').join(' ');
    }

    // 2 · Resumen del documento (transformación "enveloped": el documento sin la firma)
    final resumenDoc = b64Sha(utf8.encode(doc));

    // 3 · Propiedades firmadas
    final contenidoSp = '<xades:SignedSignatureProperties>'
        '<xades:SigningTime>$hora</xades:SigningTime>'
        '<xades:SigningCertificateV2><xades:Cert><xades:CertDigest>'
        '<ds:DigestMethod Algorithm="$_sha256"></ds:DigestMethod>'
        '<ds:DigestValue>${b64Sha(base64.decode(cert))}</ds:DigestValue>'
        '</xades:CertDigest></xades:Cert></xades:SigningCertificateV2>'
        '<xades:SignaturePolicyIdentifier><xades:SignaturePolicyId>'
        '<xades:SigPolicyId><xades:Identifier>$politicaUrl</xades:Identifier></xades:SigPolicyId>'
        '<xades:SigPolicyHash><ds:DigestMethod Algorithm="$_sha256"></ds:DigestMethod>'
        '<ds:DigestValue>$politicaHash</ds:DigestValue></xades:SigPolicyHash>'
        '</xades:SignaturePolicyId></xades:SignaturePolicyIdentifier>'
        '</xades:SignedSignatureProperties>';
    final spCanonica = '<xades:SignedProperties ${ns({prefijo: nsRaiz, 'ds': _ds, 'xades': _xades})} '
        'Id="xades-$idFirma">$contenidoSp</xades:SignedProperties>';
    final spEnDoc = '<xades:SignedProperties Id="xades-$idFirma">$contenidoSp</xades:SignedProperties>';

    // 4 · SignedInfo (atributos en orden canónico: Id, Type, URI)
    final contenidoSi = '<ds:CanonicalizationMethod Algorithm="$_c14n"></ds:CanonicalizationMethod>'
        '<ds:SignatureMethod Algorithm="$_rsaSha256"></ds:SignatureMethod>'
        '<ds:Reference Id="Reference-TicketBai" URI="">'
        '<ds:Transforms><ds:Transform Algorithm="$_enveloped"></ds:Transform></ds:Transforms>'
        '<ds:DigestMethod Algorithm="$_sha256"></ds:DigestMethod>'
        '<ds:DigestValue>$resumenDoc</ds:DigestValue></ds:Reference>'
        '<ds:Reference Type="$_tipoSignedProperties" URI="#xades-$idFirma">'
        '<ds:DigestMethod Algorithm="$_sha256"></ds:DigestMethod>'
        '<ds:DigestValue>${b64Sha(utf8.encode(spCanonica))}</ds:DigestValue></ds:Reference>';
    final siCanonica = '<ds:SignedInfo ${ns({prefijo: nsRaiz, 'ds': _ds})}>$contenidoSi</ds:SignedInfo>';

    // 5 · Firma RSA del SignedInfo canónico
    final valor = base64.encode(await firmarRsa(utf8.encode(siCanonica)));

    final firma = '<ds:Signature xmlns:ds="$_ds" Id="$idFirma">'
        '<ds:SignedInfo>$contenidoSi</ds:SignedInfo>'
        '<ds:SignatureValue>$valor</ds:SignatureValue>'
        '<ds:KeyInfo><ds:X509Data><ds:X509Certificate>$cert</ds:X509Certificate></ds:X509Data></ds:KeyInfo>'
        '<ds:Object><xades:QualifyingProperties xmlns:xades="$_xades" Target="#$idFirma">'
        '$spEnDoc</xades:QualifyingProperties></ds:Object>'
        '</ds:Signature>';
    final salida = '<?xml version="1.0" encoding="UTF-8"?>'
        '${doc.substring(0, doc.length - cierre.length)}$firma$cierre';
    return (xml: salida, signatureValue: valor);
  }

  static String _hex(int n) {
    final r = Random.secure();
    return List.generate(n, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 2026-11-09T14:40:38.761Z (milisegundos, como xadesjs)
  static String _hora(DateTime u) {
    String d(int v, [int n = 2]) => v.toString().padLeft(n, '0');
    return '${d(u.year, 4)}-${d(u.month)}-${d(u.day)}T${d(u.hour)}:${d(u.minute)}:${d(u.second)}.${d(u.millisecond, 3)}Z';
  }
}
