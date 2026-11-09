import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestionrest/core/firma_equipo_io.dart';
import 'package:gestionrest/features/ticketbai/firma_xades.dart';
import 'package:gestionrest/features/ticketbai/modelos.dart';
import 'package:gestionrest/features/ticketbai/tbai_xml.dart';

/// Firma TicketBAI en el propio equipo. En Windows usa el certificado de prueba
/// test/fixtures/prueba_tbai.p12 (contraseña 1234, autofirmado, sin validez) y deja los XML
/// firmados en test/salida/ para validarlos con un verificador XAdES externo.
void main() {
  final lineas = [
    const LineaFactura('Café "solo" & bollo > 2', 2, 1.30),
    const LineaFactura("Lata l'Original para llevar", 1, 2.42, 21),
  ];
  String alta() => TbaiXml.construir(
        nifEmisor: '12345678Z',
        razonSocial: 'María Ñúñez · Bar Itsasoa',
        serie: 'B1',
        numero: 7,
        fecha: DateTime(2026, 11, 9, 13, 5, 9),
        lineas: lineas,
        desglose: Desglose.de(lineas),
        anterior: FacturaAnterior('B1F', 2, DateTime(2026, 11, 9, 12), 'A' * 344),
        licenciaTbai: 'TBAIGIPRE00000000001',
        nifDesarrollador: '12345678Z',
        nombreSoftware: 'GestionRest',
        versionSoftware: '1.0',
      );

  test('El XML generado está en forma canónica (sin comillas escapadas ni etiquetas vacías)', () {
    final x = alta();
    expect(x.contains('&quot;'), isFalse);
    expect(x.contains('/>'), isFalse);
    expect(x.contains('<DetalleIVA><BaseImponible>2.36</BaseImponible><TipoImpositivo>10.00</TipoImpositivo>'), isTrue);
    expect(x.contains('<TipoImpositivo>21.00</TipoImpositivo>'), isTrue);
  });

  test('No firma un XML que no esté en forma canónica', () async {
    expect(
      () => FirmaXades.firmar('<T:TicketBai xmlns:T="urn:ticketbai:emision"><A/></T:TicketBai>',
          certificadoBase64: 'AA==', firmarRsa: (d) async => d),
      throwsFormatException,
    );
  });

  test('Firma en el equipo (Windows, PowerShell) de alta y anulación', () async {
    final p12 = File('test/fixtures/prueba_tbai.p12').readAsBytesSync();
    final cert = await FirmaEquipo.certificado(p12, '1234');
    expect(cert.titular, contains('PRUEBA TBAI'));
    Future<List<int>> rsa(List<int> d) => FirmaEquipo.firmar(p12, '1234', d);

    final r = await FirmaXades.firmar(alta(), certificadoBase64: cert.der, firmarRsa: rsa);
    expect(r.signatureValue.length, 344); // RSA-2048
    final anul = TbaiXml.anulacion(
      nifEmisor: '12345678Z',
      razonSocial: 'María Ñúñez · Bar Itsasoa',
      serie: 'B1',
      numero: 7,
      fecha: DateTime(2026, 11, 9),
      licenciaTbai: 'TBAIGIPRE00000000001',
      nifDesarrollador: '12345678Z',
      nombreSoftware: 'GestionRest',
      versionSoftware: '1.0',
    );
    final a = await FirmaXades.firmar(anul, certificadoBase64: cert.der, firmarRsa: rsa);

    Directory('test/salida').createSync();
    File('test/salida/alta_firmada.xml').writeAsStringSync(r.xml);
    File('test/salida/anulacion_firmada.xml').writeAsStringSync(a.xml);
  }, skip: Platform.isWindows ? false : 'Solo en Windows');
}
