import 'dart:convert';

/// CRC-8 de TicketBAI (Anexo V, Gipuzkoa):
/// polinomio x^8+x^2+x+1 (0x07), init 0, sin reflexión, XorOut 0.
/// Devuelve 3 dígitos decimales con ceros a la izquierda.
String crc8Tbai(String entrada) {
  var crc = 0;
  for (final byte in utf8.encode(entrada)) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc.toString().padLeft(3, '0');
}
