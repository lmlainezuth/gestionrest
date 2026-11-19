import 'crc8.dart';

/// Códigos impresos en la factura: identificador TBAI y URL del QR.
class TbaiCodigos {
  static const urlQrProduccion = 'https://tbai.egoitza.gipuzkoa.eus/qr/';
  static const urlQrPruebas = 'https://tbai.prep.gipuzkoa.eus/qr/';

  /// En pruebas el QR lleva a la comprobación de pruebas; si no, Hacienda no encuentra el ticket.
  static String baseQr(String? entorno) => entorno == 'produccion' ? urlQrProduccion : urlQrPruebas;

  /// TBAI-NIF(9)-DDMMAA-13 primeros caracteres de la firma-CRC  (39 caracteres)
  static String identificador({
    required String nif,
    required DateTime fecha,
    required String signatureValue,
  }) {
    String dos(int n) => n.toString().padLeft(2, '0');
    final ddmmaa = '${dos(fecha.day)}${dos(fecha.month)}${dos(fecha.year % 100)}';
    final base = 'TBAI-$nif-$ddmmaa-${signatureValue.substring(0, 13)}-';
    return '$base${crc8Tbai(base)}';
  }

  /// URL del QR: id, s, nf, i y cr (CRC de todo lo anterior).
  static String urlQr({
    required String identificador,
    required String serie,
    required int numero,
    required double importeTotal,
    String base = urlQrProduccion,
  }) {
    final sinCrc = '$base?id=${Uri.encodeComponent(identificador)}'
        '&s=${Uri.encodeComponent(serie)}'
        '&nf=$numero'
        '&i=${importeTotal.toStringAsFixed(2)}';
    return '$sinCrc&cr=${crc8Tbai(sinCrc)}';
  }
}
