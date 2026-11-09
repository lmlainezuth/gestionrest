import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'modelos.dart';
import 'tbai_codigos.dart';
import 'tbai_proveedor.dart';
import 'tbai_xml.dart';

/// Emite facturas TicketBAI: numera, encadena, firma, genera el
/// identificador y el QR, guarda y envía. También anula, rectifica y
/// convierte un ticket en factura con NIF.
class FacturacionService {
  Future<Map<String, dynamic>> _config() => supabase.from('tbai_config').select().limit(1).single();

  Future<Map<String, dynamic>> emitir({
    required List<LineaFactura> lineas,
    String? pedidoId,
    String? cajaId,
    Map<String, dynamic>? cliente, // con NIF: factura completa
    Map<String, dynamic>? original, // factura que se rectifica o se sustituye
    bool rectificativa = false, // por diferencias (devolución): líneas en negativo
    bool sustituyeSimplificada = false, // factura con NIF que sustituye a un ticket
  }) async {
    final config = await _config();
    final caja = cajaId == null
        ? await supabase.from('cajas').select('id, serie_factura').limit(1).single()
        : await supabase.from('cajas').select('id, serie_factura').eq('id', cajaId).single();
    // Cada tipo en su serie: tickets T1, con NIF T1F, rectificativas T1R
    final serie = '${caja['serie_factura']}${rectificativa ? 'R' : cliente == null ? '' : 'F'}';
    final proveedor = proveedorPara(config['entorno'] as String);
    final desglose = Desglose.de(lineas, (config['tipo_iva'] as num).toDouble());
    final codigoRect = !rectificativa ? null : (original?['tipo'] == 'completa' ? 'R4' : 'R5');
    final referencias = original == null
        ? const <({String serie, int numero, DateTime fecha})>[]
        : [
            (
              serie: original['serie'] as String,
              numero: original['numero'] as int,
              fecha: DateTime.parse(original['fecha'] as String).toLocal(),
            ),
          ];

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
        cliente: cliente,
        sustituyeSimplificada: sustituyeSimplificada,
        codigoRectificativa: codigoRect,
        referencias: referencias,
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
          'pedido_id': original == null ? pedidoId : null,
          'caja_id': caja['id'],
          'serie': serie,
          'numero': numero,
          'fecha': fecha.toUtc().toIso8601String(),
          'tipo': rectificativa ? 'rectificativa' : (cliente == null ? 'simplificada' : 'completa'),
          'cliente_nif': cliente?['documento'],
          'cliente_nombre': cliente?['nombre'],
          'cliente_direccion': cliente?['direccion'],
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
          'rectifica_id': original?['id'],
          'rectificativa_codigo': codigoRect,
          'sustituye_simplificada': sustituyeSimplificada,
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

  /// Devolución o corrección: rectificativa por diferencias con las líneas devueltas en negativo.
  Future<Map<String, dynamic>> rectificar(Map<String, dynamic> original, List<LineaFactura> devueltas) {
    final cliente = original['cliente_nif'] == null
        ? null
        : {'documento': original['cliente_nif'], 'nombre': original['cliente_nombre'], 'direccion': original['cliente_direccion']};
    return emitir(
      lineas: [for (final l in devueltas) LineaFactura(l.descripcion, -l.cantidad.abs(), l.precioUnitario)],
      cajaId: original['caja_id'] as String?,
      cliente: cliente,
      original: original,
      rectificativa: true,
    );
  }

  /// El cliente pide factura con NIF de un ticket ya hecho: factura completa que lo sustituye.
  Future<Map<String, dynamic>> facturaConNif(Map<String, dynamic> ticket, Map<String, dynamic> cliente) {
    final lineas = (ticket['lineas'] as List).map((m) => LineaFactura.fromMap(Map<String, dynamic>.from(m as Map))).toList();
    return emitir(
      lineas: lineas,
      cajaId: ticket['caja_id'] as String?,
      cliente: cliente,
      original: ticket,
      sustituyeSimplificada: true,
    );
  }

  /// Anula en Hacienda una factura enviada por error (la factura se conserva).
  Future<Map<String, dynamic>> anular(Map<String, dynamic> factura, {String? motivo}) async {
    final config = await _config();
    final proveedor = proveedorPara(config['entorno'] as String);
    final xml = TbaiXml.anulacion(
      nifEmisor: factura['nif_emisor'] as String,
      razonSocial: factura['razon_social_emisor'] as String,
      serie: factura['serie'] as String,
      numero: factura['numero'] as int,
      fecha: DateTime.parse(factura['fecha'] as String).toLocal(),
      licenciaTbai: (config['licencia_tbai'] as String?) ?? 'SIN-LICENCIA',
      nifDesarrollador: (config['nif_desarrollador'] as String?) ?? config['nif'] as String,
      nombreSoftware: config['nombre_software'] as String,
      versionSoftware: config['version_software'] as String,
    );
    final firma = await proveedor.firmar(xml);
    final fila = await supabase.from('tbai_anulaciones').upsert({
      'factura_id': factura['id'],
      'motivo': motivo,
      'xml': firma.xmlFirmado,
      'firma': firma.signatureValue,
      'estado_envio': 'pendiente',
    }, onConflict: 'factura_id').select().single();
    final envio = await proveedor.enviar(firma.xmlFirmado, baja: true);
    return await supabase
        .from('tbai_anulaciones')
        .update({'estado_envio': envio.estado, 'respuesta_envio': envio.respuesta})
        .eq('id', fila['id'])
        .select()
        .single();
  }

  /// Reenvía a Hacienda una factura o anulación que quedó pendiente.
  Future<Map<String, dynamic>> reenviar(Map<String, dynamic> factura) async {
    final config = await supabase.from('tbai_config').select('entorno').limit(1).single();
    final envio = await proveedorPara(config['entorno'] as String).enviar(factura['xml'] as String);
    return await supabase
        .from('facturas')
        .update({'estado_envio': envio.estado, 'respuesta_envio': envio.respuesta})
        .eq('id', factura['id'])
        .select()
        .single();
  }

  Future<Map<String, dynamic>> reenviarAnulacion(Map<String, dynamic> anulacion) async {
    final config = await supabase.from('tbai_config').select('entorno').limit(1).single();
    final envio = await proveedorPara(config['entorno'] as String).enviar(anulacion['xml'] as String, baja: true);
    return await supabase
        .from('tbai_anulaciones')
        .update({'estado_envio': envio.estado, 'respuesta_envio': envio.respuesta})
        .eq('id', anulacion['id'])
        .select()
        .single();
  }
}
