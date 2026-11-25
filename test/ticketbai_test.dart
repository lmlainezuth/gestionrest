import 'package:flutter_test/flutter_test.dart';
import 'package:gestionrest/features/ticketbai/crc8.dart';
import 'package:gestionrest/features/ticketbai/modelos.dart';
import 'package:gestionrest/features/ticketbai/tbai_codigos.dart';
import 'package:gestionrest/features/ticketbai/tbai_xml.dart';

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
    final d = Desglose.de(const [LineaFactura('x', 1, 78.40)]);
    expect(d.base, 71.27);
    expect(d.cuota, 7.13);
    expect(d.total, 78.40);
  });

  test('Desglose con varios tipos de IVA (10 % en local, 21 % para llevar)', () {
    final d = Desglose.de(const [
      LineaFactura('Café', 2, 1.80, 10),
      LineaFactura('Lata refresco para llevar', 1, 2.42, 21),
    ]);
    expect(d.tramos.length, 2);
    expect(d.tramos[0].tipo, 10);
    expect(d.tramos[0].base, 3.27);
    expect(d.tramos[0].cuota, 0.33);
    expect(d.tramos[1].tipo, 21);
    expect(d.tramos[1].base, 2.00);
    expect(d.tramos[1].cuota, 0.42);
    expect(d.total, 6.02);
    expect(d.tipoIva, 10);
  });

  test('Fichero Zuzendu: datos corregidos, huella y firma del original', () {
    const original = '<?xml version="1.0" encoding="UTF-8"?><T:TicketBai xmlns:T="urn:ticketbai:emision">'
        '<Cabecera><IDVersionTBAI>1.2</IDVersionTBAI></Cabecera><Sujetos><Emisor><NIF>A</NIF></Emisor></Sujetos>'
        '<Factura><X>viejo</X></Factura><HuellaTBAI><Software><Nombre>GestionRest</Nombre></Software></HuellaTBAI>'
        '<ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#"></ds:Signature></T:TicketBai>';
    final corregido = original.replaceAll('viejo', 'nuevo').replaceAll('<NIF>A</NIF>', '<NIF>B</NIF>');
    final z = TbaiXml.zuzenduAlta(xmlCorregido: corregido, xmlOriginal: original, firmaOriginal: 'f' * 344);
    expect(z, startsWith('<?xml version="1.0" encoding="UTF-8"?><T:SubsanacionModificacionTicketBAI xmlns:T="urn:ticketbai:zuzendu-alta">'));
    expect(z, contains('<Cabecera><IDVersion>1.0</IDVersion><Accion>SUBSANAR</Accion></Cabecera><Sujetos><Emisor><NIF>B</NIF>'));
    expect(z, contains('<Factura><X>nuevo</X></Factura><HuellaTBAI><Software><Nombre>GestionRest</Nombre></Software></HuellaTBAI>'));
    expect(z, endsWith('<SignatureValueFirmaFactura>${'f' * 100}</SignatureValueFirmaFactura></T:SubsanacionModificacionTicketBAI>'));
    expect(z, isNot(contains('ds:Signature')));
  });
}
