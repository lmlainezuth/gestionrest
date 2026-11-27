import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/certificado_equipo.dart';
import '../../core/config.dart';
import '../../core/firma_equipo.dart' if (dart.library.io) '../../core/firma_equipo_io.dart';
import '../../main.dart';
import 'firma_xades.dart';
import 'titular_nif.dart';

class FirmaResultado {
  final String xmlFirmado;
  final String signatureValue;
  const FirmaResultado(this.xmlFirmado, this.signatureValue);
}

class EnvioResultado {
  final String estado; // enviada | error | pendiente | simulada | ocupada (otro equipo la envía)
  final String respuesta; // JSON con estado, CSV, descripción y avisos de Hacienda
  const EnvioResultado(this.estado, this.respuesta);
}

/// Quien firma (XAdES con el certificado del negocio) y envía a la Hacienda Foral.
/// Se envía siempre algo ya GUARDADO en la base: [tabla] (facturas, anulaciones o subsanaciones)
/// e [id]. El servidor lee el fichero guardado y apunta él mismo el resultado (migración 0050).
abstract class TicketBaiProveedor {
  Future<FirmaResultado> firmar(String xml);
  Future<EnvioResultado> enviar(String tabla, String id);
}

/// Llamada a la función "ticketbai" del servidor.
Future<Map<String, dynamic>> llamarTicketbai(Map<String, dynamic> cuerpo) async {
  try {
    // En la región de la base: las consultas de la función no cruzan Europa
    final r = await supabase.functions.invoke('ticketbai', body: cuerpo, region: Config.regionServidor);
    return Map<String, dynamic>.from(r.data as Map);
  } on FunctionException catch (e) {
    final d = e.details;
    if (d is Map && d['code'] == '23505') throw CadenaOcupada();
    throw StateError(d is Map && d['error'] != null ? '${d['error']}' : 'TicketBAI: error ${e.status}');
  }
}

/// Otro equipo de la misma cadena acaba de guardar una factura: hay que numerar de nuevo.
class CadenaOcupada implements Exception {}

/// Modo simulado (tesis y pruebas sin certificado): firma de prueba con el mismo
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
    final cierre = xml.lastIndexOf('</T:');
    final xmlFirmado = '${xml.substring(0, cierre)}'
        '<ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#">'
        '<ds:SignatureValue>$firma</ds:SignatureValue>'
        '</ds:Signature>${xml.substring(cierre)}';
    return FirmaResultado(xmlFirmado, firma);
  }

  @override
  Future<EnvioResultado> enviar(String tabla, String id) async {
    final r = await llamarTicketbai({'accion': 'simular_envio', 'tabla': tabla, 'id': id});
    return EnvioResultado(r['estado'] as String, r['respuesta'] as String);
  }
}

/// Gipuzkoa real: firma XAdES-EPES en el servidor (Edge Function "ticketbai") o en el equipo con
/// el certificado instalado, y envío siempre por el servicio puente con lo guardado en la base.
class ProveedorGipuzkoa implements TicketBaiProveedor {
  ProveedorGipuzkoa(this.entorno);
  final String entorno; // pruebas | produccion

  @override
  Future<FirmaResultado> firmar(String xml) async {
    // Con certificado instalado en este equipo se firma aquí mismo (sirve sin internet)
    final local = await firmarEnEquipo(xml);
    if (local != null) return local;
    final r = await llamarTicketbai({'accion': 'firmar', 'xml': xml});
    return FirmaResultado(r['xmlFirmado'] as String, r['signatureValue'] as String);
  }

  /// Envío por el servicio puente (Netlify, Node): Hacienda pide una "renegociación" TLS que
  /// Flutter (BoringSSL) y Supabase no admiten. El puente lee el fichero guardado y el servidor
  /// apunta el resultado; aquí solo se recibe para enseñarlo.
  @override
  Future<EnvioResultado> enviar(String tabla, String id) async {
    if (Config.puenteTbai.isEmpty) {
      return EnvioResultado('pendiente', jsonEncode({'descripcion': 'Falta configurar el servicio puente'}));
    }
    try {
      final token = supabase.auth.currentSession?.accessToken ?? '';
      final r = await http
          .post(
            Uri.parse(Config.puenteTbai),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
            body: jsonEncode({'tabla': tabla, 'id': id}),
          )
          .timeout(const Duration(seconds: 60));
      final d = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
      if (d['ocupada'] == true) return const EnvioResultado('ocupada', '');
      if (d['error'] != null) throw StateError('${d['error']}');
      return EnvioResultado(d['estado'] as String, d['respuesta'] as String);
    } catch (e) {
      // Sin conexión o Hacienda caída: sigue pendiente en la base y se reenvía después
      return EnvioResultado('pendiente', jsonEncode({'descripcion': 'No enviada todavía: $e'}));
    }
  }
}

/// Firma en este equipo si tiene el certificado instalado (Android o Windows). Devuelve null
/// si no lo tiene (entonces firma el servidor).
Future<FirmaResultado?> firmarEnEquipo(String xml) async {
  if (kIsWeb || !FirmaEquipo.soportada) return null;
  final cert = await CertificadoEquipo.leer();
  if (cert == null) return null;
  final c = await FirmaEquipo.certificado(cert.bytes, cert.clave);
  // El certificado del equipo solo firma lo de su titular: si el usuario está en otro bar, firma el
  // servidor con el certificado de ese bar (y comprueba el NIF)
  final nif = nifEmisor(xml);
  if (nif == null || !certificadoDelNif(c.titular, nif)) return null;
  if (c.caduca.isBefore(DateTime.now())) {
    throw StateError('El certificado de este equipo caducó el ${c.caduca.toLocal().toString().substring(0, 10)}: renuévalo');
  }
  final r = await FirmaXades.firmar(xml,
      certificadoBase64: c.der, firmarRsa: (datos) => FirmaEquipo.firmar(cert.bytes, cert.clave, datos));
  return FirmaResultado(r.xml, r.signatureValue);
}

/// Deja el firmador del equipo arrancado (Windows: PowerShell tarda en abrir).
Future<void> precalentarFirma() async {
  try {
    if (kIsWeb || !FirmaEquipo.soportada) return;
    final cert = await CertificadoEquipo.leer();
    if (cert != null) FirmaEquipo.precalentar(cert.bytes, cert.clave);
  } catch (_) {}
}

/// Comprueba el certificado configurado en el servidor.
Future<Map<String, dynamic>> probarCertificado() async {
  final r = await supabase.functions.invoke('ticketbai', body: {'accion': 'probar'}, region: Config.regionServidor);
  return Map<String, dynamic>.from(r.data as Map);
}

TicketBaiProveedor proveedorPara(String entorno) => switch (entorno) {
      'pruebas' || 'produccion' => ProveedorGipuzkoa(entorno),
      _ => ProveedorSimulado(),
    };
