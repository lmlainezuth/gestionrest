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
        // 8 decimales, sin redondear a céntimos: con cantidades grandes el redondeo descuadra la línea
        // con su total y Hacienda avisa (5016, 5018)
        ..write('<ImporteUnitario>${(l.precioUnitario / (1 + l.tipoIva / 100)).toStringAsFixed(8)}</ImporteUnitario>')
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
      ..write('<TipoNoExenta>S1</TipoNoExenta><DesgloseIVA>');
    for (final t in desglose.tramos) {
      b
        ..write('<DetalleIVA>')
        ..write('<BaseImponible>${n2(t.base)}</BaseImponible>')
        ..write('<TipoImpositivo>${n2(t.tipo)}</TipoImpositivo>')
        ..write('<CuotaImpuesto>${n2(t.cuota)}</CuotaImpuesto>')
        ..write('</DetalleIVA>');
    }
    b
      ..write('</DesgloseIVA></DetalleNoExenta></NoExenta></Sujeta></DesgloseFactura></TipoDesglose>')
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

  /// Fichero de subsanación (o modificación) del servicio Zuzendu-alta de Gipuzkoa (OF 16/2022,
  /// esquema ZuzenduAlta_ticketBai: urn:ticketbai:zuzendu-alta). No va firmado.
  ///
  /// Lleva los datos de la factura ya corregidos ([xmlCorregido]: un fichero de alta sin firmar
  /// hecho con [construir]) y la MISMA huella del fichero original rechazado ([xmlOriginal]),
  /// más los 100 primeros caracteres de su firma. El fichero original no se toca.
  static String zuzenduAlta({
    required String xmlCorregido,
    required String xmlOriginal,
    required String firmaOriginal,
    bool modificar = false,
  }) {
    String bloque(String xml, String etiqueta) {
      final a = xml.indexOf('<$etiqueta>'), b = xml.indexOf('</$etiqueta>');
      if (a < 0 || b < a) throw FormatException('Zuzendu: falta <$etiqueta> en el fichero');
      return xml.substring(a, b + etiqueta.length + 3);
    }

    final firma100 = firmaOriginal.length > 100 ? firmaOriginal.substring(0, 100) : firmaOriginal;
    return '<?xml version="1.0" encoding="UTF-8"?>'
        '<T:SubsanacionModificacionTicketBAI xmlns:T="urn:ticketbai:zuzendu-alta">'
        '<Cabecera><IDVersion>1.0</IDVersion><Accion>${modificar ? 'MODIFICAR' : 'SUBSANAR'}</Accion></Cabecera>'
        '${bloque(xmlCorregido, 'Sujetos')}'
        '${bloque(xmlCorregido, 'Factura')}'
        '${bloque(xmlOriginal, 'HuellaTBAI')}'
        '<SignatureValueFirmaFactura>${_e(firma100)}</SignatureValueFirmaFactura>'
        '</T:SubsanacionModificacionTicketBAI>';
  }

  /// Escapa el texto tal como lo deja la canonicalización C14N (sin escapar comillas y sin
  /// caracteres de control): así el XML generado ya es su forma canónica y se puede firmar
  /// también en el propio equipo, sin internet.
  static String _e(String s) => s
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
