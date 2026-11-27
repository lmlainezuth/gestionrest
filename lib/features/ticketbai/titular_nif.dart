/// ¿Es este certificado del NIF que factura? Misma regla que la función "ticketbai" del servidor.
///
/// Si el certificado lleva identificador de entidad (VATES-…, el del titular en los certificados de
/// representante), el NIF tiene que ser ese: así no vale el DNI del representante que también va
/// en el sujeto. Si no lo lleva (persona física, o el sistema lo devuelve codificado), el NIF tiene
/// que aparecer como palabra suelta en el sujeto, no como trozo de otra.
bool certificadoDelNif(String titular, String nif) {
  final t = titular.toUpperCase();
  final n = nif.trim().toUpperCase();
  if (n.length != 9) return false;
  final entidad = RegExp(r'VATES-?([A-Z0-9]{9})').allMatches(t).map((m) => m.group(1)).toSet();
  if (entidad.isNotEmpty) return entidad.contains(n);
  return RegExp('(^|[^A-Z0-9])${RegExp.escape(n)}([^A-Z0-9]|\$)').hasMatch(t);
}

/// NIF del emisor de un fichero TicketBAI (alta, anulación o subsanación), o null si no lo lleva.
String? nifEmisor(String xml) =>
    RegExp(r'<(?:[\w.-]+:)?Emisor>\s*<(?:[\w.-]+:)?NIF>\s*([^<\s]+)\s*<').firstMatch(xml)?.group(1)?.toUpperCase();
