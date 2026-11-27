import 'dart:convert';

import '../../core/software.dart';

import '../../main.dart';
import '../barra/venta_offline.dart';
import 'cadena_equipo.dart';
import 'envios_pendientes.dart';
import 'modelos.dart';
import 'tbai_codigos.dart';
import 'tbai_proveedor.dart';
import 'tbai_xml.dart';

/// Emite facturas TicketBAI: numera, encadena y monta el fichero; el servidor lo comprueba, lo
/// firma (o comprueba la firma del equipo) y lo guarda (migración 0050), y después se envía lo
/// guardado. También anula, rectifica y convierte un ticket en factura con NIF.
class FacturacionService {
  // Licencia y NIF del desarrollador: si la empresa no los tiene escritos, los del programa
  Future<Map<String, dynamic>> _config() async =>
      Software.completar(await supabase.from('tbai_config').select().limit(1).single());

  /// En producción no se emite nada con datos de prueba o sin licencia.
  static void comprobarConfig(Map<String, dynamic> configEmpresa) {
    final config = Software.completar(configEmpresa);
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
    bool enviarEnSegundoPlano = false, // cobro: no esperar a Hacienda (se envía detrás)
  }) async {
    // En paralelo: cada consulta es un viaje al servidor
    final r0 = await Future.wait([
      _config(),
      cajaId == null
          ? supabase.from('cajas').select('id, serie_factura').limit(1).single()
          : supabase.from('cajas').select('id, serie_factura').eq('id', cajaId).single(),
    ]);
    final config = r0[0];
    comprobarConfig(config);
    final caja = r0[1];
    // Cada punto de emisión tiene su cadena (serie base). Cada tipo en su serie:
    // tickets T1, con NIF T1F, rectificativas T1R; las tres en la MISMA cadena.
    // Un equipo con serie propia (el que cobra sin internet) usa siempre su cadena
    final equipo = await CadenaEquipo.serie();
    if (equipo != null) {
      // Antes, las ventas hechas sin internet: van primero en la cadena y en la numeración
      await VentaOffline.sincronizar();
      if (await VentaOffline.hayEnEspera()) {
        throw StateError('Este equipo tiene una venta sin internet en espera: cobra desde Barra (modo sin '
            'internet) o pide al administrador que la envíe desde Facturas › Ventas en espera');
      }
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
      final r1 = await Future.wait<dynamic>([
        supabase.rpc('tbai_ultima_factura', params: {'p_cadena': cadena}),
        // El servidor mira todas las facturas de la serie (el camarero no las ve todas)
        supabase.rpc('tbai_ultimo_numero', params: {'p_serie': serie}),
      ]);
      final ultimas = List<Map<String, dynamic>>.from(r1[0] as List);
      final previa = ultimas.isEmpty ? null : ultimas.first;
      final numero = ((r1[1] as num?)?.toInt() ?? 0) + 1;
      final fila = await prepararFactura(
        config: config,
        // Simulado: firma de prueba. Gipuzkoa: firma el equipo si tiene el certificado; si no,
        // el fichero va sin firmar y lo firma el servidor al guardarlo
        firmar: proveedor is ProveedorSimulado ? proveedor.firmar : firmarEnEquipo,
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
        final factura = await registrar(fila);
        if (equipo != null) await CadenaEquipo.registrar(factura);
        // Simulado: el servidor ya la deja como "simulada"
        if (proveedor is ProveedorSimulado) return factura;

        if (enviarEnSegundoPlano) {
          // La factura ya está firmada y guardada (vale para imprimir); el envío va detrás.
          // Si falla, queda pendiente y EnviosPendientes la reintenta sola.
          _enviarDetras(proveedor, factura);
          return factura;
        }
        await proveedor.enviar('facturas', factura['id'] as String);
        return await _leer('facturas', factura);
      } on CadenaOcupada {
        if (intento < 4) continue; // otro equipo emitió a la vez
        rethrow;
      }
    }
    throw StateError('No se pudo numerar la factura');
  }

  /// Guarda en el servidor una factura montada (y firmada o no) por [prepararFactura]. El servidor
  /// comprueba fichero, cadena, numeración y pedido, la firma si hace falta y devuelve la fila.
  /// Lanza [CadenaOcupada] si otro equipo de la misma cadena acaba de guardar una.
  static Future<Map<String, dynamic>> registrar(Map<String, dynamic> fila) =>
      llamarTicketbai({'accion': 'registrar', 'fila': fila, 'firmada': fila['firma'] != null});

  /// Deja en espera en el servidor una venta sin internet que no se aceptó (migración 0052).
  static Future<void> apartar(Map<String, dynamic> venta, String motivo) =>
      llamarTicketbai({'accion': 'apartar', 'venta': venta, 'motivo': motivo});

  /// Solo el administrador: guarda tal cual una venta en espera (con motivo) y la envía a Hacienda.
  /// Devuelve la factura con el estado del envío.
  Future<Map<String, dynamic>> forzar(String id, String motivo) async {
    final factura = await llamarTicketbai({'accion': 'forzar', 'id': id, 'motivo': motivo});
    final config = await supabase.from('tbai_config').select('entorno').limit(1).single();
    final envio = await proveedorPara(config['entorno'] as String).enviar('facturas', factura['id'] as String);
    if (envio.estado == 'ocupada') return factura;
    return _leer('facturas', factura);
  }

  /// Vuelve a leer la fila (el estado del envío lo apunta el servidor). Si no se puede, la de antes.
  static Future<Map<String, dynamic>> _leer(String tabla, Map<String, dynamic> fila) async {
    const nombres = {'facturas': 'facturas', 'anulaciones': 'tbai_anulaciones', 'subsanaciones': 'tbai_subsanaciones'};
    try {
      return await supabase.from(nombres[tabla]!).select().eq('id', fila['id'] as Object).single();
    } catch (_) {
      return fila;
    }
  }

  static void _enviarDetras(TicketBaiProveedor proveedor, Map<String, dynamic> factura) {
    Future(() => proveedor.enviar('facturas', factura['id'] as String))
        .catchError((_) => const EnvioResultado('pendiente', ''))
        .whenComplete(EnviosPendientes.revisar);
  }

  /// Construye y deja lista para guardar la fila de una factura (con o sin internet). Si [firmar]
  /// devuelve null, el fichero va sin firmar (lo firma el servidor) y faltan firma, id TBAI y QR.
  /// [previa] es la última factura de la cadena ({id, serie, numero, fecha, firma}) o null.
  static Future<Map<String, dynamic>> prepararFactura({
    required Map<String, dynamic> config,
    required Future<FirmaResultado?> Function(String xml) firmar,
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
      nifDesarrollador: (config['nif_desarrollador'] as String?) ?? Software.nifDesarrollador,
      nombreSoftware: Software.nombre,
      versionSoftware: Software.version,
      cliente: cliente,
      sustituyeSimplificada: sustituyeSimplificada,
      codigoRectificativa: codigoRect,
      referencias: referencias,
    );
    final firma = await firmar(xml);
    final id = firma == null
        ? null
        : TbaiCodigos.identificador(
            nif: config['nif'] as String,
            fecha: fecha,
            signatureValue: firma.signatureValue,
          );
    final qr = id == null
        ? null
        : TbaiCodigos.urlQr(
            identificador: id,
            serie: serie,
            numero: numero,
            importeTotal: desglose.total,
            base: TbaiCodigos.baseQr(config['entorno'] as String?),
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
      'firma': firma?.signatureValue,
      'tbai_id': id,
      'qr_url': qr,
      'xml': firma?.xmlFirmado ?? xml,
      'creado_por': supabase.auth.currentUser?.id,
      'rectifica_id': original?['id'],
      'rectificativa_codigo': codigoRect,
      'sustituye_simplificada': sustituyeSimplificada,
    };
  }

  /// Devolución o corrección: rectificativa por diferencias con las líneas devueltas en negativo.
  Future<Map<String, dynamic>> rectificar(Map<String, dynamic> original, List<LineaFactura> devueltas) async {
    final cliente = original['cliente_nif'] == null
        ? null
        : {'documento': original['cliente_nif'], 'nombre': original['cliente_nombre'], 'direccion': original['cliente_direccion']};
    final r = await emitir(
      lineas: [for (final l in devueltas) LineaFactura(l.descripcion, -l.cantidad.abs(), l.precioUnitario)],
      cajaId: original['caja_id'] as String?,
      cliente: cliente,
      original: original,
      rectificativa: true,
    );
    await _devolverCobro(original, 'DEV ${r['serie']}-${r['numero']}', importe: (r['importe_total'] as num).abs());
    return r;
  }

  /// Aviso para la pantalla si la última anulación o devolución no se pudo descontar de la caja.
  static String? avisoCaja;

  /// El dinero devuelto sale de la caja: pago en negativo en el turno abierto (migración 0031).
  /// No interrumpe la anulación ni la rectificativa si falla: deja el aviso en [avisoCaja].
  Future<void> _devolverCobro(Map<String, dynamic> original, String referencia, {num? importe}) async {
    avisoCaja = null;
    try {
      final r = Map<String, dynamic>.from(await supabase.rpc('devolver_cobro', params: {
        'p_factura': original['id'],
        'p_importe': importe,
        'p_referencia': referencia,
      }) as Map);
      if (r['motivo'] == 'sin_turno') {
        avisoCaja = 'No hay caja abierta: la devolución no se ha descontado de la caja';
      }
    } catch (e) {
      avisoCaja = 'No se pudo descontar de la caja: $e';
    }
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
      nifDesarrollador: (config['nif_desarrollador'] as String?) ?? Software.nifDesarrollador,
      nombreSoftware: Software.nombre,
      versionSoftware: Software.version,
    );
    final firma = await proveedor.firmar(xml);
    // El estado del envío lo pone el servidor (empieza "pendiente")
    final fila = await supabase.from('tbai_anulaciones').upsert({
      'factura_id': factura['id'],
      'motivo': motivo,
      'xml': firma.xmlFirmado,
      'firma': firma.signatureValue,
    }, onConflict: 'factura_id').select().single();
    await proveedor.enviar('anulaciones', fila['id'] as String);
    final r = await _leer('anulaciones', fila);
    // Si Hacienda la rechaza, la factura sigue valiendo y el cobro no se toca
    avisoCaja = null;
    if (r['estado_envio'] != 'error') await _devolverCobro(factura, 'ANUL ${factura['serie']}-${factura['numero']}');
    return r;
  }

  /// Subsana en Hacienda una factura RECHAZADA (servicio Zuzendu-alta, OF 16/2022): envía sus
  /// datos, corregidos si hace falta, con la huella del fichero original. La factura y su fichero
  /// rechazado no cambian; el fichero de subsanación queda guardado en tbai_subsanaciones.
  /// [razonSocial] y [cliente] (documento, nombre, direccion): solo si hay que corregirlos.
  Future<Map<String, dynamic>> subsanar(Map<String, dynamic> factura, {String? razonSocial, Map<String, dynamic>? cliente}) async {
    if (factura['estado_envio'] != 'error') throw StateError('Solo se subsana una factura que Hacienda ha rechazado');
    final config = await _config();
    final proveedor = proveedorPara(config['entorno'] as String);
    if (proveedor is! ProveedorGipuzkoa) throw StateError('En modo simulado no hay nada que subsanar');
    final lineas = (factura['lineas'] as List).map((m) => LineaFactura.fromMap(Map<String, dynamic>.from(m as Map))).toList();
    // Rectificativa o factura que sustituye a un ticket: referencia a la factura original
    final origen = factura['rectifica_id'] == null
        ? null
        : await supabase.from('facturas').select('serie, numero, fecha').eq('id', factura['rectifica_id'] as Object).single();
    final corregido = TbaiXml.construir(
      nifEmisor: factura['nif_emisor'] as String,
      razonSocial: (razonSocial == null || razonSocial.isEmpty) ? factura['razon_social_emisor'] as String : razonSocial,
      serie: factura['serie'] as String,
      numero: factura['numero'] as int,
      fecha: DateTime.parse(factura['fecha'] as String).toLocal(),
      lineas: lineas,
      desglose: Desglose.de(lineas),
      anterior: null, // la huella va tal cual la del fichero original
      licenciaTbai: (config['licencia_tbai'] as String?) ?? 'SIN-LICENCIA',
      nifDesarrollador: (config['nif_desarrollador'] as String?) ?? Software.nifDesarrollador,
      nombreSoftware: Software.nombre,
      versionSoftware: Software.version,
      cliente: factura['cliente_nif'] == null
          ? null
          : cliente ??
              {'documento': factura['cliente_nif'], 'nombre': factura['cliente_nombre'], 'direccion': factura['cliente_direccion']},
      sustituyeSimplificada: factura['sustituye_simplificada'] == true,
      codigoRectificativa: factura['rectificativa_codigo'] as String?,
      referencias: origen == null
          ? const []
          : [
              (
                serie: origen['serie'] as String,
                numero: origen['numero'] as int,
                fecha: DateTime.parse(origen['fecha'] as String).toLocal(),
              ),
            ],
    );
    final xml = TbaiXml.zuzenduAlta(
      xmlCorregido: corregido,
      xmlOriginal: factura['xml'] as String,
      firmaOriginal: factura['firma'] as String,
    );
    final fila = await supabase
        .from('tbai_subsanaciones')
        .insert({'factura_id': factura['id'], 'accion': 'SUBSANAR', 'xml': xml})
        .select()
        .single();
    // El servidor apunta el resultado en la subsanación y en la factura (recibida y subsanada, o
    // sigue rechazada con la respuesta nueva)
    final envio = await proveedor.enviar('subsanaciones', fila['id'] as String);
    if (envio.estado == 'pendiente' || envio.estado == 'ocupada') {
      final d = envio.respuesta.isEmpty ? null : (jsonDecode(envio.respuesta) as Map)['descripcion'];
      throw StateError('no se pudo enviar la subsanación${d == null ? '' : ' ($d)'}. Vuelve a intentarlo');
    }
    return _leer('facturas', factura);
  }

  /// Reenvía a Hacienda una factura o anulación que quedó pendiente. Si otro equipo la
  /// está enviando en este momento, no hace nada y devuelve la factura tal cual.
  Future<Map<String, dynamic>> reenviar(Map<String, dynamic> factura) async {
    final config = await supabase.from('tbai_config').select('entorno').limit(1).single();
    final envio = await proveedorPara(config['entorno'] as String).enviar('facturas', factura['id'] as String);
    if (envio.estado == 'ocupada') return factura;
    return _leer('facturas', factura);
  }

  Future<Map<String, dynamic>> reenviarAnulacion(Map<String, dynamic> anulacion) async {
    final config = await supabase.from('tbai_config').select('entorno').limit(1).single();
    final envio = await proveedorPara(config['entorno'] as String).enviar('anulaciones', anulacion['id'] as String);
    if (envio.estado == 'ocupada') return anulacion;
    final r = await _leer('anulaciones', anulacion);
    // Por si al anular no hubo conexión y el cobro quedó sin descontar (si ya estaba, no repite)
    if (r['estado_envio'] != 'error') {
      final f = await supabase.from('facturas').select('id, serie, numero').eq('id', anulacion['factura_id'] as Object).single();
      await _devolverCobro(f, 'ANUL ${f['serie']}-${f['numero']}');
    }
    return r;
  }
}
