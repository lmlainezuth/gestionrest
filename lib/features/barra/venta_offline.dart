import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/certificado_equipo.dart';
import '../../core/red.dart';
import '../../core/software.dart';
import '../../main.dart';
import '../caja/caja_service.dart';
import '../ticketbai/cadena_equipo.dart';
import '../ticketbai/caducidad_certificados.dart';
import '../ticketbai/facturacion_service.dart';
import '../ticketbai/modelos.dart';
import '../ticketbai/tbai_proveedor.dart';

/// Venta en barra sin internet.
///
/// Requisitos: certificado instalado en este equipo (firma aquí), serie propia del equipo y
/// haber abierto la app con conexión al menos una vez con la caja abierta (se guarda la carta,
/// la caja, el turno y los datos fiscales). La venta se firma, se imprime y se guarda en una
/// cola local; al volver internet se sube en orden y se envía a Hacienda.
class VentaOffline {
  static const _kCarta = 'offline_carta', _kContexto = 'offline_contexto', _kCola = 'offline_cola';

  // Cola y cadena local se tocan de uno en uno (vender y sincronizar pueden coincidir)
  static Future<void> _cerrojo = Future.value();
  static Future<T> _exclusivo<T>(Future<T> Function() f) {
    final r = _cerrojo.then((_) => f());
    _cerrojo = r.then((_) {}, onError: (_) {});
    return r;
  }

  // ---------- Datos guardados con conexión ----------

  static Future<void> guardarCarta(List grupos, List productos, Map<String, String> areas) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCarta, jsonEncode({'grupos': grupos, 'productos': productos, 'areas': areas}));
  }

  static Future<({List<Map<String, dynamic>> grupos, List<Map<String, dynamic>> productos, Map<String, String> areas})?>
      leerCarta() async {
    final s = (await SharedPreferences.getInstance()).getString(_kCarta);
    if (s == null) return null;
    final m = jsonDecode(s) as Map;
    return (
      grupos: List<Map<String, dynamic>>.from((m['grupos'] as List).map((e) => Map<String, dynamic>.from(e as Map))),
      productos: List<Map<String, dynamic>>.from((m['productos'] as List).map((e) => Map<String, dynamic>.from(e as Map))),
      areas: Map<String, String>.from(m['areas'] as Map),
    );
  }

  /// Guarda caja, turno abierto y datos fiscales; y pone al día la cadena local con la base de datos.
  static Future<void> guardarContexto() async {
    final caja = await supabase.from('cajas').select('id, serie_factura').eq('activo', true).limit(1).single();
    final turno = await CajaService.turnoAbierto(caja['id'] as String);
    final config = await supabase.from('tbai_config').select().limit(1).single();
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kContexto,
        jsonEncode({
          'caja_id': caja['id'],
          'turno_id': turno?['id'],
          'config': config,
          'usuario': supabase.auth.currentUser?.id,
          'guardado': DateTime.now().toIso8601String(),
        }));
    // Apunta cuándo caduca el certificado de este equipo (el panel avisa 30 días antes)
    await CaducidadCertificados.registrarEquipo();
    var serie = await CadenaEquipo.serie();
    // En producción solo vale una serie asignada a este bar y titular (p. ej. tras pasar a producción
    // o cambiar el NIF, las anteriores dejan de valer): sin ella, este equipo no cobra sin internet
    if (serie != null && (await cola()).isEmpty &&
        await supabase.rpc('tbai_serie_valida', params: {'p_serie': serie}) == false) {
      await CadenaEquipo.guardarSerie(null);
      serie = null;
    }
    if (serie != null && (await cola()).isEmpty) {
      final ultimas = List<Map<String, dynamic>>.from(
          await supabase.rpc('tbai_ultima_factura', params: {'p_cadena': serie}) as List);
      final numeros = <String, int>{};
      for (final s in [serie, '${serie}F', '${serie}R']) {
        // El servidor mira todas las facturas de la serie (el camarero no las ve todas)
        final u = await supabase.rpc('tbai_ultimo_numero', params: {'p_serie': s}) as num?;
        if (u != null) numeros[s] = u.toInt();
      }
      await CadenaEquipo.sincronizarCon(ultimas.isEmpty ? null : ultimas.first, numeros);
    }
  }

  /// ¿Puede este equipo cobrar sin internet? Devuelve el motivo si no puede.
  static Future<String?> motivoNoDisponible() async {
    if (await CertificadoEquipo.leer() == null) return 'este equipo no tiene el certificado instalado';
    if (await CadenaEquipo.serie() == null) return 'este equipo no tiene serie propia (Ajustes → Empresa)';
    final s = (await SharedPreferences.getInstance()).getString(_kContexto);
    if (s == null) return 'abre la Barra una vez con internet';
    final c = jsonDecode(s) as Map;
    if (c['turno_id'] == null) return 'la caja estaba cerrada la última vez que hubo internet';
    final entorno = (c['config'] as Map)['entorno'];
    if (entorno != 'pruebas' && entorno != 'produccion') return 'TicketBAI está en modo simulado';
    return null;
  }

  // ---------- Mesas y cuentas sin internet ----------

  static const _kSalones = 'offline_salones', _kAbiertas = 'offline_abiertas', _kCuentas = 'offline_cuentas';

  static Future<void> guardarSalones(List salones) async =>
      (await SharedPreferences.getInstance()).setString(_kSalones, jsonEncode(salones));

  static Future<List<Map<String, dynamic>>?> leerSalones() async {
    final s = (await SharedPreferences.getInstance()).getString(_kSalones);
    if (s == null) return null;
    return [for (final e in jsonDecode(s) as List) Map<String, dynamic>.from(e as Map)];
  }

  static Future<Map<String, dynamic>> _mapa(String clave) async {
    final s = (await SharedPreferences.getInstance()).getString(clave);
    return s == null ? {} : Map<String, dynamic>.from(jsonDecode(s) as Map);
  }

  static Future<void> _guardarMapa(String clave, Map<String, dynamic> m) async =>
      (await SharedPreferences.getInstance()).setString(clave, jsonEncode(m));

  /// Copia de los pedidos abiertos (con sus líneas) tomada con conexión.
  /// [barra]: true = cuentas con nombre de la barra; false = mesas y para llevar.
  static Future<void> guardarAbiertas(List pedidos, {required bool barra}) => _exclusivo(() async {
        // Con ventas o mesas del equipo aún sin subir, la copia no se toca (si no, volverían a
        // aparecer abiertas cuentas que ya se cobraron sin internet)
        if ((await cola()).isNotEmpty || (await _mapa(_kCuentas)).isNotEmpty) return;
        final m = await _mapa(_kAbiertas);
        m.removeWhere((_, v) => ((v as Map)['tipo'] == 'barra') == barra);
        for (final p in pedidos) {
          final pm = Map<String, dynamic>.from(p as Map);
          if ((pm['tipo'] == 'barra') == barra) m[pm['id'] as String] = pm;
        }
        await _guardarMapa(_kAbiertas, m);
      });

  static double _totalLineas(List lineas) => lineas.fold(0.0, (s, d) {
        final l = d as Map;
        if (l['estado_cocina'] == 'anulado') return s;
        return s + (l['cantidad'] as num).toDouble() * (l['precio_unitario'] as num).toDouble();
      });

  /// Pedidos abiertos tal como se ven sin internet: la copia + lo añadido en este equipo.
  /// Las líneas añadidas sin internet llevan '_local': true.
  static Future<List<Map<String, dynamic>>> abiertas() async {
    final copia = await _mapa(_kAbiertas);
    final locales = await _mapa(_kCuentas);
    final r = <String, Map<String, dynamic>>{
      for (final e in copia.entries) e.key: Map<String, dynamic>.from(e.value as Map),
    };
    for (final e in locales.entries) {
      final c = Map<String, dynamic>.from(e.value as Map);
      final nuevas = [for (final l in c['nuevas'] as List) {...Map<String, dynamic>.from(l as Map), '_local': true}];
      final base = r[e.key] ?? {...Map<String, dynamic>.from(c['pedido'] as Map), 'pedido_detalle': []};
      base['pedido_detalle'] = [...(base['pedido_detalle'] as List? ?? []), ...nuevas];
      r[e.key] = base;
    }
    for (final p in r.values) {
      p['total'] = (_totalLineas(p['pedido_detalle'] as List? ?? []) * 100).roundToDouble() / 100;
    }
    return r.values.toList();
  }

  /// Con conexión: copia de mesas y de todos los pedidos abiertos con sus líneas, para poder
  /// seguir atendiendo y cobrando si se va internet.
  static Future<void> refrescarCopia() async {
    final r = await Future.wait([
      supabase
          .from('salones')
          .select('id, nombre, mesas(id, nombre, capacidad, disponibilidad, activo)')
          .eq('activo', true)
          .order('orden'),
      supabase
          .from('pedidos')
          .select('id, tipo, nombre_llevar, mesa_id, total, creado_en, num_personas, estado, '
              'pedido_detalle(id, producto_id, area_id, descripcion, cantidad, precio_unitario, tipo_iva, estado_cocina)')
          .inFilter('estado', ['abierto', 'precuenta']),
    ]);
    await guardarSalones(r[0]);
    await guardarAbiertas(r[1], barra: false);
    await guardarAbiertas(r[1], barra: true);
  }

  /// Pedido nuevo creado sin internet (mesa o cuenta con nombre de la barra).
  static Map<String, dynamic> nuevoPedido({String? mesaId, String? nombre}) => {
        'id': _uuid(),
        'tipo': mesaId != null ? 'mesa' : 'barra',
        'mesa_id': mesaId,
        'nombre_llevar': nombre,
        'camarero_id': supabase.auth.currentUser?.id,
        'creado_en': DateTime.now().toUtc().toIso8601String(),
        'estado': 'abierto',
        'pedido_detalle': <Map<String, dynamic>>[],
        'total': 0,
      };

  static Map<String, dynamic> _base(Map<String, dynamic> p) => {
        for (final k in ['id', 'tipo', 'mesa_id', 'nombre_llevar', 'camarero_id', 'creado_en'])
          if (p[k] != null) k: p[k],
      };

  /// Deja unas líneas apuntadas en un pedido (mesa o cuenta) sin cobrar.
  static Future<void> anadirACuenta(Map<String, dynamic> pedido, List<Map<String, dynamic>> lineas) =>
      _exclusivo(() async {
        final m = await _mapa(_kCuentas);
        final c = Map<String, dynamic>.from((m[pedido['id']] as Map?) ?? {'pedido': _base(pedido), 'nuevas': []});
        c['empresa_id'] ??= await _empresaContexto();
        c['nuevas'] = [
          ...c['nuevas'] as List,
          for (final l in lineas) {...l, 'id': _uuid(), 'pedido_id': pedido['id'], 'curso': 'ya'},
        ];
        m[pedido['id'] as String] = c;
        await _guardarMapa(_kCuentas, m);
      });

  /// Bar al que pertenece lo que se apunta sin internet (el del último contexto guardado).
  static Future<String?> _empresaContexto() async {
    final s = (await SharedPreferences.getInstance()).getString(_kContexto);
    if (s == null) return null;
    return ((jsonDecode(s) as Map)['config'] as Map?)?['empresa_id'] as String?;
  }

  // ---------- Venta ----------

  /// Firma y guarda una venta pagada. Devuelve la factura para imprimirla.
  /// [pedido]: el pedido que se cobra (de la copia, nuevo sin internet o null = venta rápida).
  /// [detalleNuevo]: lo que se acaba de pedir y se cobra ya (aún no está en ningún sitio).
  static Future<Map<String, dynamic>> vender({
    Map<String, dynamic>? pedido,
    required List<Map<String, dynamic>> detalleNuevo, // {producto_id, area_id, descripcion, cantidad, precio_unitario, tipo_iva, estado_cocina}
    required String metodo,
    double? entregado,
  }) async {
    final motivo = await motivoNoDisponible();
    if (motivo != null) throw StateError('Sin internet no se puede cobrar: $motivo');
    return _exclusivo(() => _vender(pedido, detalleNuevo, metodo, entregado));
  }

  /// [pedidoIn]['pedido_detalle'] son las líneas que se ven en pantalla: la factura cobra
  /// exactamente eso más lo de ahora (aunque mientras tanto se haya subido algo).
  static Future<Map<String, dynamic>> _vender(
      Map<String, dynamic>? pedidoIn, List<Map<String, dynamic>> detalleNuevo, String metodo, double? entregado) async {
    final p = await SharedPreferences.getInstance();
    final ctx = Map<String, dynamic>.from(jsonDecode(p.getString(_kContexto)!) as Map);
    final config = Software.completar(Map<String, dynamic>.from(ctx['config'] as Map));
    FacturacionService.comprobarConfig(config);
    final cadena = (await CadenaEquipo.serie())!;

    final pedido = pedidoIn ?? nuevoPedido();
    final pedidoId = pedido['id'] as String;
    final cuentas = await _mapa(_kCuentas);
    final copia = await _mapa(_kAbiertas);
    // Líneas que ya están en el servidor (de la copia) + apuntadas sin internet + las de ahora
    final enServidor = [
      for (final d in ((copia[pedidoId] as Map?)?['pedido_detalle'] as List?) ?? const [])
        Map<String, dynamic>.from(d as Map),
    ];
    final apuntadas = [
      for (final d in ((cuentas[pedidoId] as Map?)?['nuevas'] as List?) ?? const []) Map<String, dynamic>.from(d as Map),
    ];
    final ahora = DateTime.now().toUtc().toIso8601String();
    final nuevas = [
      ...apuntadas,
      for (final d in detalleNuevo) {...d, 'id': _uuid(), 'pedido_id': pedidoId, 'curso': 'ya'},
    ];
    final visibles = pedidoIn?['pedido_detalle'] as List?;
    final ahoraLineas = nuevas.skip(apuntadas.length);
    final todas = [
      ...(visibles != null ? [for (final d in visibles) Map<String, dynamic>.from(d as Map)] : [...enServidor, ...apuntadas]),
      ...ahoraLineas,
    ].where((d) => d['estado_cocina'] != 'anulado');
    final lineas = [
      for (final d in todas)
        LineaFactura(d['descripcion'] as String, (d['cantidad'] as num).toDouble(),
            (d['precio_unitario'] as num).toDouble(), ((d['tipo_iva'] as num?) ?? 10).toDouble()),
    ];
    final total = Desglose.de(lineas).total;
    if (total <= 0) throw StateError('No se puede cobrar 0 €');

    final fila = await FacturacionService.prepararFactura(
      config: config,
      firmar: (xml) async {
        final f = await firmarEnEquipo(xml);
        if (f == null) throw StateError('No se pudo firmar en este equipo');
        return f;
      },
      cajaId: ctx['caja_id'] as String,
      cadena: cadena,
      serie: cadena, // sin internet solo tickets (sin NIF)
      numero: ((await CadenaEquipo.ultimoNumero(cadena)) ?? 0) + 1,
      previa: await CadenaEquipo.ultima(),
      lineas: lineas,
      pedidoId: pedidoId,
    );
    final factura = {
      ...fila,
      'id': _uuid(),
      // Para el servidor: ya va firmada en el equipo; si el importe no cuadra con el pedido, la
      // guarda igual y lo deja apuntado en Seguridad (migración 0050)
      'sin_conexion': true,
      'estado_envio': 'pendiente',
      'respuesta_envio': jsonEncode({'descripcion': 'Emitida sin internet: se envía sola al volver la conexión'}),
    };
    final venta = {
      'pedido': _base(pedido),
      'detalle': [for (final d in nuevas) {...d}..remove('_local')],
      'pagos': [
        {
          'id': _uuid(),
          'pedido_id': pedidoId,
          'turno_id': ctx['turno_id'],
          'metodo': metodo,
          'importe': total,
          'pago_con': ?entregado,
          if (entregado != null) 'vuelto': entregado - total,
        },
      ],
      'cierre': {'estado': 'pagado', 'pagado_en': ahora, 'turno_id': ctx['turno_id']},
      'mesa_id': pedido['mesa_id'],
      'factura': factura,
      'empresa_id': config['empresa_id'], // al subir se comprueba que la sesión es de este bar
    };
    // Primero se guarda (cola y cadena) y después se imprime: nunca un ticket sin rastro
    final lista = await cola();
    lista.add(venta);
    await p.setString(_kCola, jsonEncode(lista));
    await CadenaEquipo.registrar(factura);
    // El pedido ya no está abierto en este equipo
    cuentas.remove(pedidoId);
    copia.remove(pedidoId);
    await _guardarMapa(_kCuentas, cuentas);
    await _guardarMapa(_kAbiertas, copia);
    return factura;
  }

  // ---------- Sincronización ----------

  static Future<List<Map<String, dynamic>>> cola() async {
    final s = (await SharedPreferences.getInstance()).getString(_kCola);
    if (s == null) return [];
    return List<Map<String, dynamic>>.from((jsonDecode(s) as List).map((e) => Map<String, dynamic>.from(e as Map)));
  }

  /// Cuántas ventas sin internet hay en este equipo sin subir y la fecha de la más antigua.
  static Future<({int n, DateTime? desde})> resumenCola() async {
    final lista = await cola();
    DateTime? desde;
    for (final v in lista) {
      final f = DateTime.tryParse('${(v['factura'] as Map?)?['fecha']}')?.toLocal();
      if (f != null && (desde == null || f.isBefore(desde))) desde = f;
    }
    return (n: lista.length, desde: desde);
  }

  static bool _sincronizando = false;
  static String? ultimoError;

  /// Sube en orden las ventas hechas sin internet y las envía a Hacienda. Idempotente: si se
  /// corta a medias, la siguiente vez continúa sin duplicar (todo lleva su id).
  static Future<int> sincronizar() async {
    if (_sincronizando || supabase.auth.currentSession == null) return 0;
    _sincronizando = true;
    var subidas = 0;
    ultimoError = null;
    try {
      final p = await SharedPreferences.getInstance();
      // 1 · Mesas y cuentas apuntadas sin internet (sin cobrar todavía)
      final cuentas = await _mapa(_kCuentas);
      // Lo apuntado sin internet solo sube con la sesión de SU bar: si en este equipo se ha
      // cambiado de bar, no se sube nada (caería en el bar equivocado)
      final deBares = {
        for (final c in cuentas.values) (c as Map)['empresa_id'],
        for (final v in await cola()) v['empresa_id'],
      }..remove(null);
      if (deBares.isNotEmpty) {
        final actual = (await supabase.from('tbai_config').select('empresa_id').limit(1).single())['empresa_id'];
        if (deBares.any((b) => b != actual)) {
          ultimoError = 'Este equipo tiene ventas sin internet de otro bar: entra en ese bar para que suban';
          return 0;
        }
      }
      for (final e in cuentas.entries) {
        final c = Map<String, dynamic>.from(e.value as Map);
        final ped = Map<String, dynamic>.from(c['pedido'] as Map);
        await supabase.from('pedidos').upsert(ped, onConflict: 'id', ignoreDuplicates: true);
        await supabase.from('pedido_detalle').upsert(
            [for (final l in c['nuevas'] as List) Map<String, dynamic>.from(l as Map)..remove('_local')],
            onConflict: 'id',
            ignoreDuplicates: true);
        if (ped['mesa_id'] != null) {
          await supabase.from('mesas').update({'disponibilidad': 'ocupada'}).eq('id', ped['mesa_id']);
        }
        await _exclusivo(() async {
          final actual = await _mapa(_kCuentas);
          final a = actual[e.key] as Map?;
          // Si mientras tanto se apuntó algo más, se queda solo lo nuevo
          if (a != null) {
            final subidas = {for (final l in c['nuevas'] as List) (l as Map)['id']};
            final quedan = [for (final l in a['nuevas'] as List) if (!subidas.contains((l as Map)['id'])) l];
            if (quedan.isEmpty) {
              actual.remove(e.key);
            } else {
              actual[e.key] = {...Map<String, dynamic>.from(a), 'nuevas': quedan};
            }
            await _guardarMapa(_kCuentas, actual);
          }
        });
      }
      // 2 · Ventas cobradas sin internet, en orden
      var lista = await cola();
      while (lista.isNotEmpty) {
        final v = lista.first;
        final pedido = Map<String, dynamic>.from(v['pedido'] as Map);
        final factura = Map<String, dynamic>.from(v['factura'] as Map);
        await supabase.from('pedidos').upsert(pedido, onConflict: 'id', ignoreDuplicates: true);
        await supabase.from('pedido_detalle').upsert(List<Map<String, dynamic>>.from(v['detalle'] as List),
            onConflict: 'id', ignoreDuplicates: true);
        await supabase.from('pagos').upsert(List<Map<String, dynamic>>.from(v['pagos'] as List),
            onConflict: 'id', ignoreDuplicates: true);
        await supabase.from('pedidos').update(Map<String, dynamic>.from(v['cierre'] as Map)).eq('id', pedido['id']);
        if (v['mesa_id'] != null) {
          await supabase.from('mesas').update({'disponibilidad': 'libre'}).eq('id', v['mesa_id']);
        }
        try {
          // La guarda el servidor, que comprueba la firma del equipo, la cadena y el pedido. Si ya
          // estaba guardada (se cortó a medias), la devuelve tal cual
          await FacturacionService.registrar(factura);
        } on CadenaOcupada {
          // Otra factura ya cuelga de la misma anterior: la serie del equipo la usa otro equipo
          ultimoError = 'La venta ${factura['serie']}-${factura['numero']} no encaja en la cadena. '
              'Revisa que ningún otro equipo use la serie ${factura['cadena']}';
          rethrow;
        } on StateError catch (e) {
          ultimoError = 'El servidor no acepta la venta ${factura['serie']}-${factura['numero']}: ${e.message}';
          rethrow;
        }
        // Se quita de la cola por su id (mientras tanto pudo entrar otra venta)
        await _exclusivo(() async {
          final actual = await cola();
          actual.removeWhere((x) => (x['factura'] as Map)['id'] == factura['id']);
          await p.setString(_kCola, jsonEncode(actual));
        });
        subidas++;
        try {
          await FacturacionService().reenviar(factura);
        } catch (_) {
          // Queda "pendiente" en la base de datos: lo reenvía el proceso automático
        }
        lista = await cola();
      }
    } catch (e) {
      // Sin conexión todavía: no es un error, se reintenta en la próxima vuelta
      if (esErrorDeRed(e)) {
        ultimoError = null;
      } else {
        ultimoError ??= '$e';
      }
    } finally {
      _sincronizando = false;
    }
    return subidas;
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
