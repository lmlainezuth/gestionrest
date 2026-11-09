import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/certificado_equipo.dart';
import '../../core/config.dart';
import '../../core/envio_tbai.dart' if (dart.library.io) '../../core/envio_tbai_io.dart';
import '../../core/firma_equipo.dart' if (dart.library.io) '../../core/firma_equipo_io.dart';
import '../../main.dart';
import 'firma_xades.dart';

class FirmaResultado {
  final String xmlFirmado;
  final String signatureValue;
  const FirmaResultado(this.xmlFirmado, this.signatureValue);
}

class EnvioResultado {
  final String estado; // enviada | error | pendiente | simulada
  final String respuesta; // JSON con estado, CSV, descripción y avisos de Hacienda
  const EnvioResultado(this.estado, this.respuesta);
}

/// Quien firma (XAdES con el certificado del negocio) y envía a la Hacienda Foral.
abstract class TicketBaiProveedor {
  Future<FirmaResultado> firmar(String xml);
  Future<EnvioResultado> enviar(String xmlFirmado, {bool baja = false});
}

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
  Future<EnvioResultado> enviar(String xmlFirmado, {bool baja = false}) async =>
      const EnvioResultado('simulada', 'Modo simulado: no se envía a la Hacienda Foral');
}

/// Gipuzkoa real: firma XAdES-EPES y envío con certificado en el servidor
/// (Edge Function "ticketbai"); el certificado nunca está en los dispositivos.
class ProveedorGipuzkoa implements TicketBaiProveedor {
  ProveedorGipuzkoa(this.entorno);
  final String entorno; // pruebas | produccion

  static const _host = {
    'pruebas': 'https://tbai-z.prep.gipuzkoa.eus/sarrerak/',
    'produccion': 'https://tbai-z.egoitza.gipuzkoa.eus/sarrerak/',
  };

  /// Envío por el servicio puente (Netlify, Node): para Android, web o equipos sin certificado.
  /// Hacienda pide una "renegociación" TLS que Flutter (BoringSSL) y Supabase no admiten.
  Future<Map<String, dynamic>> _porPuente(String xmlFirmado, bool baja) async {
    final token = supabase.auth.currentSession?.accessToken ?? '';
    final r = await http
        .post(
          Uri.parse(Config.puenteTbai),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
          body: jsonEncode({'xmlFirmado': xmlFirmado, 'entorno': entorno, 'baja': baja}),
        )
        .timeout(const Duration(seconds: 45));
    final d = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    if (d['error'] != null) throw StateError('Puente: ${d['error']}');
    final texto = d['respuesta'] as String? ?? '';
    final res = leerRespuesta(texto);
    if (res['estado'] == null) res['descripcion'] = 'Respuesta HTTP ${d['http']}: ${texto.length > 300 ? texto.substring(0, 300) : texto}';
    return res;
  }

  Future<Map<String, dynamic>> _llamar(Map<String, dynamic> cuerpo) async {
    try {
      final r = await supabase.functions.invoke('ticketbai', body: cuerpo);
      return Map<String, dynamic>.from(r.data as Map);
    } on FunctionException catch (e) {
      final d = e.details;
      throw StateError(d is Map && d['error'] != null ? '${d['error']}' : 'TicketBAI: error ${e.status}');
    }
  }

  @override
  Future<FirmaResultado> firmar(String xml) async {
    // Con certificado instalado en este equipo se firma aquí mismo (sirve sin internet)
    final local = await firmarEnEquipo(xml);
    if (local != null) return local;
    final r = await _llamar({'accion': 'firmar', 'xml': xml});
    return FirmaResultado(r['xmlFirmado'] as String, r['signatureValue'] as String);
  }

  /// Lee la respuesta XML de Hacienda (Salida/Estado, CSV, ResultadosValidacion).
  static Map<String, dynamic> leerRespuesta(String xml) {
    String? tag(String n) =>
        RegExp('<(?:\\w+:)?$n>([\\s\\S]*?)</(?:\\w+:)?$n>').firstMatch(xml)?.group(1)?.trim();
    final errores = [
      for (final m in RegExp(r'<(?:\w+:)?ResultadosValidacion>([\s\S]*?)</(?:\w+:)?ResultadosValidacion>').allMatches(xml))
        {
          'codigo': RegExp(r'<(?:\w+:)?Codigo>([^<]*)<').firstMatch(m.group(1)!)?.group(1),
          'descripcion': RegExp(r'<(?:\w+:)?Descripcion>([^<]*)<').firstMatch(m.group(1)!)?.group(1),
        },
    ];
    return {
      'estado': tag('Estado'),
      'descripcion': tag('Descripcion'),
      'csv': tag('CSV'),
      'fechaRecepcion': tag('FechaRecepcion'),
      'errores': errores,
    };
  }

  @override
  Future<EnvioResultado> enviar(String xmlFirmado, {bool baja = false}) async {
    try {
      final Map<String, dynamic> r;
      final cert = kIsWeb || defaultTargetPlatform != TargetPlatform.windows ? null : await CertificadoEquipo.leer();
      if (cert != null) {
        // Windows con certificado instalado: envía este equipo (curl.exe)
        final url = '${_host[entorno]!}${baja ? 'baja' : 'alta'}';
        final (codigo, texto) = await enviarConCertificado(url, xmlFirmado, cert.bytes, cert.clave);
        r = leerRespuesta(texto);
        if (r['estado'] == null) r['descripcion'] = 'Respuesta HTTP $codigo: ${texto.length > 300 ? texto.substring(0, 300) : texto}';
      } else if (Config.puenteTbai.isNotEmpty) {
        r = await _porPuente(xmlFirmado, baja);
      } else {
        throw StateError('Este equipo no puede enviar: instala el certificado (Windows) o configura el servicio puente');
      }
      final respuesta = jsonEncode({
        'estado': r['estado'],
        'descripcion': r['descripcion'],
        'csv': r['csv'],
        'fecha': r['fechaRecepcion'],
        'avisos': r['errores'],
      });
      return switch (r['estado']) {
        '00' => EnvioResultado('enviada', respuesta),
        '01' => EnvioResultado('error', respuesta),
        _ => EnvioResultado('pendiente', respuesta),
      };
    } catch (e) {
      // Sin conexión o Hacienda caída: queda pendiente y se reenvía después
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
  if (c.caduca.isBefore(DateTime.now())) {
    throw StateError('El certificado de este equipo caducó el ${c.caduca.toLocal().toString().substring(0, 10)}: renuévalo');
  }
  final r = await FirmaXades.firmar(xml,
      certificadoBase64: c.der, firmarRsa: (datos) => FirmaEquipo.firmar(cert.bytes, cert.clave, datos));
  return FirmaResultado(r.xml, r.signatureValue);
}

/// Comprueba el certificado configurado en el servidor.
Future<Map<String, dynamic>> probarCertificado() async {
  final r = await supabase.functions.invoke('ticketbai', body: {'accion': 'probar'});
  return Map<String, dynamic>.from(r.data as Map);
}

TicketBaiProveedor proveedorPara(String entorno) => switch (entorno) {
      'pruebas' || 'produccion' => ProveedorGipuzkoa(entorno),
      _ => ProveedorSimulado(),
    };
