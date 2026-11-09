import 'dart:convert';

import 'package:crypto/crypto.dart';

class FirmaResultado {
  final String xmlFirmado;
  final String signatureValue;
  const FirmaResultado(this.xmlFirmado, this.signatureValue);
}

class EnvioResultado {
  final String estado; // enviada | error | simulada
  final String respuesta;
  const EnvioResultado(this.estado, this.respuesta);
}

/// Quien firma (XAdES con el certificado del negocio) y envía a la
/// Hacienda Foral. Para producción se implementa con un proveedor
/// certificado y registrado en el Registro de Software TicketBAI.
abstract class TicketBaiProveedor {
  Future<FirmaResultado> firmar(String xml);
  Future<EnvioResultado> enviar(String xmlFirmado);
}

/// Proveedor de la tesis: genera una firma de prueba con el mismo
/// formato que una RSA-2048 (344 caracteres Base64) y no envía nada.
class ProveedorSimulado implements TicketBaiProveedor {
  @override
  Future<FirmaResultado> firmar(String xml) async {
    final bytes = <int>[];
    var bloque = sha256.convert(utf8.encode(xml)).bytes;
    while (bytes.length < 256) {
      bytes.addAll(bloque);
      bloque = sha256.convert(bloque).bytes;
    }
    final firma = base64.encode(bytes);
    final xmlFirmado = xml.replaceFirst(
      '</T:TicketBai>',
      '<ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#">'
          '<ds:SignatureValue>$firma</ds:SignatureValue>'
          '</ds:Signature></T:TicketBai>',
    );
    return FirmaResultado(xmlFirmado, firma);
  }

  @override
  Future<EnvioResultado> enviar(String xmlFirmado) async =>
      const EnvioResultado('simulada', 'Modo simulado: no se envía a la Hacienda Foral');
}

TicketBaiProveedor proveedorPara(String entorno) => switch (entorno) {
      'simulado' => ProveedorSimulado(),
      _ => throw UnimplementedError(
          'Entorno "$entorno": conecta un proveedor TicketBAI certificado'),
    };
