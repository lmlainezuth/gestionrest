import 'package:flutter_test/flutter_test.dart';
import 'package:gestionrest/features/ticketbai/crc8.dart';
import 'package:gestionrest/features/ticketbai/modelos.dart';
import 'package:gestionrest/features/ticketbai/tbai_codigos.dart';

/// Vectores de prueba del Anexo V (Diputación Foral de Gipuzkoa).
void main() {
  test('CRC-8 del identificador del Anexo V', () {
    expect(crc8Tbai('TBAI-00000006Y-251019-btFpwP8dcLGAF-'), '237');
  });

  test('Identificador TBAI de 39 caracteres', () {
    final id = TbaiCodigos.identificador(
      nif: '00000006Y',
      fecha: DateTime(2019, 10, 25),
      signatureValue: 'btFpwP8dcLGAFresto-de-la-firma',
    );
    expect(id, 'TBAI-00000006Y-251019-btFpwP8dcLGAF-237');
    expect(id.length, 39);
  });

  test('URL del QR del Anexo V (cr=182)', () {
    final url = TbaiCodigos.urlQr(
      identificador: 'TBAI-44619360G-261020-EzyQEMtxw37Gm-161',
      serie: 'TB-2020-F',
      numero: 419,
      importeTotal: 1542.75,
    );
    expect(url,
        'https://tbai.egoitza.gipuzkoa.eus/qr/?id=TBAI-44619360G-261020-EzyQEMtxw37Gm-161'
        '&s=TB-2020-F&nf=419&i=1542.75&cr=182');
  });

  test('Desglose de IVA del 10 % con precios IVA incluido', () {
    final d = Desglose.de(const [LineaFactura('x', 1, 78.40)], 10);
    expect(d.base, 71.27);
    expect(d.cuota, 7.13);
    expect(d.total, 78.40);
  });
}
