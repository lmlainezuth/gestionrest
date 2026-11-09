import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import '../barra/venta_offline.dart';
import 'cadena_equipo.dart';
import 'modelos.dart';
import 'tbai_codigos.dart';
import 'tbai_proveedor.dart';
import 'tbai_xml.dart';

/// Emite facturas TicketBAI: numera, encadena, firma, genera el
/// identificador y el QR, guarda y envía. También anula, rectifica y
/// convierte un ticket en factura con NIF.
class FacturacionService {
  Future<Map<String, dynamic>> _config() => supabase.from('tbai_config').select().limit(1).single();

  /// En producción no se emite nada con datos de prueba o sin licencia.
  static void comprobarConfig(Map<String, dynamic> config) {
    if (config['entorno'] != 'produccion') return;
    final licencia = (config['licencia_tbai'] as String?)?.trim() ?? '';
    if (licencia.isEmpty || licencia.startsWith('TBAIGIPRE') || licencia == 'SIN-LICENCIA') {
      throw StateError('Producción sin licencia TicketBAI definitiva: ponla en Ajustes → Empresa');
    }
    if (((config['nif_desarrollador'] as String?) ?? '').trim().length != 9) {
      throw StateError('Falta el NIF del desarrollador del software en Ajustes → Empresa');
    }
    final nif = (config['nif'] as String?) ?? '';
    if (nif == 'B00000000' || nif.length != 9) throw StateError('NIF del bar no válido en Ajustes → Empresa');
  }

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
    comprobarConfig(config);
    final caja = cajaId == null
        ? await supabase.from('cajas').select('id, serie_factura').limit(1).single()
        : await supabase.from('cajas').select('id, serie_factura').eq('id', cajaId).single();
    // Cada punto de emisión tiene su cadena (serie base). Cada tipo en su serie:
    // tickets T1, con NIF T1F, rectificativas T1R; las tres en la MISMA cadena.
    // Un equipo con serie propia (el que cobra sin internet) usa siempre su cadena
    final equipo = await CadenaEquipo.serie();
    if (equipo != null) {
      // Antes, las ventas hechas sin internet: van primero en la cadena y en la numeración
      await VentaOffline.sincronizar();
      if ((await VentaOffline.cola()).isNotEmpty) {
        throw StateError('Hay ventas hechas sin internet que aún no se han podido subir'
            '${VentaOffline.ultimoError == null ? '' : ': ${VentaOffline.ultimoError}'}');
      }
    }
    final cadena = equipo ?? caja['serie_factura'] as String;
    final serie = '$cadena${rectificativa ? 'R' : cliente == null ? '' : 'F'}';
    final proveedor = proveedorPara(config['entorno'] as String);
    final desglose = Desglose.de(lineas);
    if (lineas.isEmpty || desglose.total == 0) throw StateError('No se puede facturar un importe de 0 €');
    final codigoRect = !rectificativa ? null : (original?['tipo'] == 'completa' ? 'R4' : 'R5');

    // Varios intentos por si otro equipo de la misma cadena emite a la vez: la base de datos
    // rechaza (23505) que dos facturas cuelguen de la misma anterior o repitan número.
    for (var intento = 0; intento < 5; intento++) {
      final ultimas = List<Map<String, dynamic>>.from(
          await supabase.rpc('tbai_ultima_factura', params: {'p_cadena': cadena}) as List);
      final previa = ultimas.isEmpty ? null : ultimas.first;
      final ultimaSerie = await supabase
          .from('facturas')
          .select('numero')
          .eq('serie', serie)
          .order('numero', ascending: false)
          .limit(1)
          .maybeSingle();
      final numero = ((ultimaSerie?['numero'] as int?) ?? 0) + 1;
      final fila = await prepararFactura(
        config: config,
        firmar: proveedor.firmar,
        cajaId: caja['id'] as String,
        cadena: cadena,
        serie: serie,
        numero: numero,
        previa: previa,
        lineas: lineas,
        pedidoId: original == null ? pedidoId : null,
        cliente: cliente,
        original: original,
        codigoRect: codigoRect,
        sustituyeSimplificada: sustituyeSimplificada,
      );

      try {
        final factura = await supabase
            .from('facturas')
            .insert({...fila, 'envio_intento': DateTime.now().toUtc().toIso8601String()}) // lo envía este equipo ahora
            .select()
            .single();
        if (equipo != null) await CadenaEquipo.registrar(factura);

        final envio = await proveedor.enviar(factura['xml'] as String);
        return await supabase
            .from('facturas')
            .update({'estado_envio': envio.estado, 'respuesta_envio': envio.respuesta})
            .eq('id', factura['id'])
            .select()
            .single();
      } on PostgrestException catch (e) {
        if (e.code == '23505' && intento < 4) continue; // otro equipo emitió a la vez
        rethrow;
      }
    }
    throw StateError('No se pudo numerar la factura');
  }

  /// Construye, firma y deja lista para guardar la fila de una factura (con o sin internet).
  /// [previa] es la última factura de la cadena ({id, serie, numero, fecha, firma}) o null.
  static Future<Map<String, dynamic>> prepararFactura({
    required Map<String, dynamic> config,
    required Future<FirmaResultado> Function(String xml) firmar,
    required String cajaId,
    required String cadena,
    required String serie,
    required int numero,
    required Map<String, dynamic>? previa,
    required List<LineaFactura> lineas,
    String? pedidoId,
    Map<String, dynamic>? cliente,
    Map<String, dynamic>? original,
    String? codigoRect,
    bool sustituyeSimplificada = false,
  }) async {
    final desglose = Desglose.de(lineas);
    final anterior = previa == null
        ? null
        : FacturaAnterior(previa['serie'] as String, previa['numero'] as int,
            DateTime.parse(previa['fecha'] as String).toLocal(), previa['firma'] as String);
    var fecha = DateTime.now();
    // Nunca anterior a la factura previa (reloj del equipo atrasado)
    if (anterior != null && fecha.isBefore(anterior.fecha)) fecha = anterior.fecha;
    final referencias = original == null
        ? const <({String serie, int numero, DateTime fecha})>[]
        : [
            (
              serie: original['serie'] as String,
              numero: original['numero'] as int,
              fecha: DateTime.parse(original['fecha'] as String).toLocal(),
            ),
          ];
    final rectificativa = codigoRect != null;

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
    final firma = await firmar(xml);
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
    return {
      'pedido_id': pedidoId,
      'caja_id': cajaId,
      'serie': serie,
      'numero': numero,
      'fecha': fecha.toUtc().toIso8601String(),
      'tipo': rectificativa ? 'rectificativa' : (cliente == null ? 'simplificada' : 'completa'),
      'cadena': cadena,
      'anterior_id': previa?['id'],
      'desglose_iva': desglose.tramos.map((t) => t.toMap()).toList(),
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
    };
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
    comprobarConfig(config);
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
      'envio_intento': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'factura_id').select().single();
    final envio = await proveedor.enviar(firma.xmlFirmado, baja: true);
    return await supabase
        .from('tbai_anulaciones')
        .update({'estado_envio': envio.estado, 'respuesta_envio': envio.respuesta})
        .eq('id', fila['id'])
        .select()
        .single();
  }

  /// Reenvía a Hacienda una factura o anulación que quedó pendiente. Si otro equipo la
  /// está enviando en este momento, no hace nada y devuelve la factura tal cual.
  Future<Map<String, dynamic>> reenviar(Map<String, dynamic> factura) async {
    final mia = await supabase.rpc('tbai_reclamar_envio', params: {'p_tabla': 'facturas', 'p_id': factura['id']});
    if (mia != true) return factura;
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
    final mia = await supabase.rpc('tbai_reclamar_envio', params: {'p_tabla': 'anulaciones', 'p_id': anulacion['id']});
    if (mia != true) return anulacion;
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
