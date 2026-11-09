import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'modelos.dart';
import 'tbai_codigos.dart';
import 'tbai_proveedor.dart';
import 'tbai_xml.dart';

/// Emite facturas TicketBAI: numera, encadena, firma, genera el
/// identificador y el QR, guarda y envía.
class FacturacionService {
  Future<Map<String, dynamic>> emitir({
    required List<LineaFactura> lineas,
    String? pedidoId,
    String? cajaId,
  }) async {
    final config = await supabase.from('tbai_config').select().limit(1).single();
    final caja = cajaId == null
        ? await supabase.from('cajas').select('id, serie_factura').limit(1).single()
        : await supabase.from('cajas').select('id, serie_factura').eq('id', cajaId).single();
    final serie = caja['serie_factura'] as String;
    final proveedor = proveedorPara(config['entorno'] as String);
    final desglose = Desglose.de(lineas, (config['tipo_iva'] as num).toDouble());

    // Dos intentos por si otra caja con la misma serie emite a la vez
    for (var intento = 0; intento < 2; intento++) {
      final previa = await supabase
          .from('facturas')
          .select('serie, numero, fecha, firma')
          .eq('serie', serie)
          .order('numero', ascending: false)
          .limit(1)
          .maybeSingle();
      final anterior = previa == null
          ? null
          : FacturaAnterior(previa['serie'] as String, previa['numero'] as int,
              DateTime.parse(previa['fecha'] as String).toLocal(), previa['firma'] as String);
      final numero = (anterior?.numero ?? 0) + 1;
      final fecha = DateTime.now();

      final xml = TbaiXml.construir(
        nifEmisor: config['nif'] as String,
        razonSocial: config['razon_social'] as String,
        serie: serie,
        numero: numero,
        fecha: fecha,
        lineas: lineas,
        desglose: desglose,
        anterior: anterior,
        licenciaTbai: (config['licencia_tbai'] as String?) ?? 'SIN-LICENCIA',
        nifDesarrollador: (config['nif_desarrollador'] as String?) ?? config['nif'] as String,
        nombreSoftware: config['nombre_software'] as String,
        versionSoftware: config['version_software'] as String,
      );
      final firma = await proveedor.firmar(xml);
      final id = TbaiCodigos.identificador(
        nif: config['nif'] as String,
        fecha: fecha,
        signatureValue: firma.signatureValue,
      );
      final qr = TbaiCodigos.urlQr(
        identificador: id,
        serie: serie,
        numero: numero,
        importeTotal: desglose.total,
      );

      try {
        final factura = await supabase.from('facturas').insert({
          'pedido_id': pedidoId,
          'caja_id': caja['id'],
          'serie': serie,
          'numero': numero,
          'fecha': fecha.toUtc().toIso8601String(),
          'nif_emisor': config['nif'],
          'razon_social_emisor': config['razon_social'],
          'lineas': lineas.map((l) => l.toMap()).toList(),
          'base_imponible': desglose.base,
          'tipo_iva': desglose.tipoIva,
          'cuota_iva': desglose.cuota,
          'importe_total': desglose.total,
          'anterior_serie': anterior?.serie,
          'anterior_numero': anterior?.numero,
          'anterior_fecha': anterior?.fecha.toUtc().toIso8601String(),
          'anterior_firma100': anterior?.firma100,
          'firma': firma.signatureValue,
          'tbai_id': id,
          'qr_url': qr,
          'xml': firma.xmlFirmado,
          'creado_por': supabase.auth.currentUser?.id,
        }).select().single();

        final envio = await proveedor.enviar(firma.xmlFirmado);
        return await supabase
            .from('facturas')
            .update({'estado_envio': envio.estado, 'respuesta_envio': envio.respuesta})
            .eq('id', factura['id'])
            .select()
            .single();
      } on PostgrestException catch (e) {
        if (e.code == '23505' && intento == 0) continue; // número ya usado
        rethrow;
      }
    }
    throw StateError('No se pudo numerar la factura');
  }
}
