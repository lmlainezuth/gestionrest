import 'modelos.dart';

/// Construye el fichero TicketBAI (alta de factura) sin firmar,
/// según la estructura del esquema TicketBAI 1.2 (urn:ticketbai:emision).
/// Antes de pasar a producción debe validarse contra el XSD oficial.
class TbaiXml {
  static String construir({
    required String nifEmisor,
    required String razonSocial,
    required String serie,
    required int numero,
    required DateTime fecha,
    required List<LineaFactura> lineas,
    required Desglose desglose,
    required FacturaAnterior? anterior,
    required String licenciaTbai,
    required String nifDesarrollador,
    required String nombreSoftware,
    required String versionSoftware,
    Map<String, dynamic>? cliente,
    bool sustituyeSimplificada = false, // factura completa que sustituye a un ticket
    String? codigoRectificativa, // R1..R5 (por diferencias)
    List<({String serie, int numero, DateTime fecha})> referencias = const [],
  }) {
    String n2(double v) => v.toStringAsFixed(2);
    String dos(int v) => v.toString().padLeft(2, '0');
    String f(DateTime d) => '${dos(d.day)}-${dos(d.month)}-${d.year}';
    String h(DateTime d) => '${dos(d.hour)}:${dos(d.minute)}:${dos(d.second)}';
    final iva = 1 + desglose.tipoIva / 100;

    final b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?>')
      ..write('<T:TicketBai xmlns:T="urn:ticketbai:emision">')
      ..write('<Cabecera><IDVersionTBAI>1.2</IDVersionTBAI></Cabecera>')
      ..write('<Sujetos><Emisor>')
      ..write('<NIF>${_e(nifEmisor)}</NIF>')
      ..write('<ApellidosNombreRazonSocial>${_e(razonSocial)}</ApellidosNombreRazonSocial>')
      ..write('</Emisor>');
    if (cliente != null) {
      b
        ..write('<Destinatarios><IDDestinatario>')
        ..write('<NIF>${_e(cliente['documento'] as String)}</NIF>')
        ..write('<ApellidosNombreRazonSocial>${_e(cliente['nombre'] as String)}</ApellidosNombreRazonSocial>');
      final dir = cliente['direccion'] as String?;
      if (dir != null && dir.isNotEmpty) b.write('<Direccion>${_e(dir)}</Direccion>');
      b.write('</IDDestinatario></Destinatarios>');
    }
    b
      ..write('<EmitidaPorTercerosODestinatario>N</EmitidaPorTercerosODestinatario></Sujetos>')
      ..write('<Factura><CabeceraFactura>')
      ..write('<SerieFactura>${_e(serie)}</SerieFactura>')
      ..write('<NumFactura>$numero</NumFactura>')
      ..write('<FechaExpedicionFactura>${f(fecha)}</FechaExpedicionFactura>')
      ..write('<HoraExpedicionFactura>${h(fecha)}</HoraExpedicionFactura>')
      ..write('<FacturaSimplificada>${cliente == null ? 'S' : 'N'}</FacturaSimplificada>');
    if (sustituyeSimplificada) b.write('<FacturaEmitidaSustitucionSimplificada>S</FacturaEmitidaSustitucionSimplificada>');
    if (codigoRectificativa != null) {
      b.write('<FacturaRectificativa><Codigo>$codigoRectificativa</Codigo><Tipo>I</Tipo></FacturaRectificativa>');
    }
    if (referencias.isNotEmpty) {
      b.write('<FacturasRectificadasSustituidas>');
      for (final r in referencias) {
        b
          ..write('<IDFacturaRectificadaSustituida>')
          ..write('<SerieFactura>${_e(r.serie)}</SerieFactura>')
          ..write('<NumFactura>${r.numero}</NumFactura>')
          ..write('<FechaExpedicionFactura>${f(r.fecha)}</FechaExpedicionFactura>')
          ..write('</IDFacturaRectificadaSustituida>');
      }
      b.write('</FacturasRectificadasSustituidas>');
    }
    b
      ..write('</CabeceraFactura><DatosFactura>')
      ..write('<DescripcionFactura>Servicio de restauración</DescripcionFactura>')
      ..write('<DetallesFactura>');
    for (final l in lineas) {
      b
        ..write('<IDDetalleFactura>')
        ..write('<DescripcionDetalle>${_e(l.descripcion)}</DescripcionDetalle>')
        ..write('<Cantidad>${n2(l.cantidad)}</Cantidad>')
        ..write('<ImporteUnitario>${n2(l.precioUnitario / iva)}</ImporteUnitario>')
        ..write('<Descuento>0.00</Descuento>')
        ..write('<ImporteTotal>${n2(l.total)}</ImporteTotal>')
        ..write('</IDDetalleFactura>');
    }
    b
      ..write('</DetallesFactura>')
      ..write('<ImporteTotalFactura>${n2(desglose.total)}</ImporteTotalFactura>')
      ..write('<Claves><IDClave><ClaveRegimenIvaOpTrascendencia>01</ClaveRegimenIvaOpTrascendencia></IDClave></Claves>')
      ..write('</DatosFactura>')
      ..write('<TipoDesglose><DesgloseFactura><Sujeta><NoExenta><DetalleNoExenta>')
      ..write('<TipoNoExenta>S1</TipoNoExenta><DesgloseIVA><DetalleIVA>')
      ..write('<BaseImponible>${n2(desglose.base)}</BaseImponible>')
      ..write('<TipoImpositivo>${n2(desglose.tipoIva)}</TipoImpositivo>')
      ..write('<CuotaImpuesto>${n2(desglose.cuota)}</CuotaImpuesto>')
      ..write('</DetalleIVA></DesgloseIVA></DetalleNoExenta></NoExenta></Sujeta></DesgloseFactura></TipoDesglose>')
      ..write('</Factura><HuellaTBAI>');
    if (anterior != null) {
      b
        ..write('<EncadenamientoFacturaAnterior>')
        ..write('<SerieFacturaAnterior>${_e(anterior.serie)}</SerieFacturaAnterior>')
        ..write('<NumFacturaAnterior>${anterior.numero}</NumFacturaAnterior>')
        ..write('<FechaExpedicionFacturaAnterior>${f(anterior.fecha)}</FechaExpedicionFacturaAnterior>')
        ..write('<SignatureValueFirmaFacturaAnterior>${_e(anterior.firma100)}</SignatureValueFirmaFacturaAnterior>')
        ..write('</EncadenamientoFacturaAnterior>');
    }
    b
      ..write('<Software>')
      ..write('<LicenciaTBAI>${_e(licenciaTbai)}</LicenciaTBAI>')
      ..write('<EntidadDesarrolladora><NIF>${_e(nifDesarrollador)}</NIF></EntidadDesarrolladora>')
      ..write('<Nombre>${_e(nombreSoftware)}</Nombre>')
      ..write('<Version>${_e(versionSoftware)}</Version>')
      ..write('</Software></HuellaTBAI></T:TicketBai>');
    return b.toString();
  }

  /// Fichero de anulación (urn:ticketbai:anulacion) de una factura ya enviada.
  static String anulacion({
    required String nifEmisor,
    required String razonSocial,
    required String serie,
    required int numero,
    required DateTime fecha,
    required String licenciaTbai,
    required String nifDesarrollador,
    required String nombreSoftware,
    required String versionSoftware,
  }) {
    String dos(int v) => v.toString().padLeft(2, '0');
    final fe = '${dos(fecha.day)}-${dos(fecha.month)}-${fecha.year}';
    return '<?xml version="1.0" encoding="UTF-8"?>'
        '<T:AnulaTicketBai xmlns:T="urn:ticketbai:anulacion">'
        '<Cabecera><IDVersionTBAI>1.2</IDVersionTBAI></Cabecera>'
        '<IDFactura><Emisor><NIF>${_e(nifEmisor)}</NIF>'
        '<ApellidosNombreRazonSocial>${_e(razonSocial)}</ApellidosNombreRazonSocial></Emisor>'
        '<CabeceraFactura><SerieFactura>${_e(serie)}</SerieFactura><NumFactura>$numero</NumFactura>'
        '<FechaExpedicionFactura>$fe</FechaExpedicionFactura></CabeceraFactura></IDFactura>'
        '<HuellaTBAI><Software><LicenciaTBAI>${_e(licenciaTbai)}</LicenciaTBAI>'
        '<EntidadDesarrolladora><NIF>${_e(nifDesarrollador)}</NIF></EntidadDesarrolladora>'
        '<Nombre>${_e(nombreSoftware)}</Nombre><Version>${_e(versionSoftware)}</Version></Software></HuellaTBAI>'
        '</T:AnulaTicketBai>';
  }

  static String _e(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
