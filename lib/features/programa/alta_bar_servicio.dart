import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

/// Llamadas a la función "alta-bar" (migración 0054). Solo programadores con cuenta de correo:
/// el servidor lo comprueba en cada llamada. El certificado se manda una vez y no vuelve nunca.
Future<Map<String, dynamic>> llamarAltaBar(Map<String, dynamic> cuerpo) async {
  try {
    final r = await supabase.functions.invoke('alta-bar', body: cuerpo);
    return Map<String, dynamic>.from(r.data as Map);
  } on FunctionException catch (e) {
    final d = e.details;
    throw StateError(d is Map && d['error'] != null ? '${d['error']}' : 'Alta de bar: error ${e.status}');
  }
}

/// Texto de un error de "alta-bar" para enseñarlo tal cual.
String textoAltaBar(Object e) => e is StateError ? e.message : '$e';

/// Certificado elegido en el equipo, listo para mandarlo (nombre y contenido en base64).
class CertificadoElegido {
  const CertificadoElegido(this.nombre, this.base64);
  final String nombre;
  final String base64;

  static Future<CertificadoElegido?> elegir() async {
    final f = await FilePicker.pickFile();
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    if (bytes.length > 50000) throw StateError('El fichero es demasiado grande para ser un certificado .p12/.pfx');
    return CertificadoElegido(f.name, base64Encode(bytes));
  }
}
