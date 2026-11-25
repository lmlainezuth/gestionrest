import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../ajustes/clientes_tab.dart' show editarCliente;
import '../barra/venta_offline.dart';
import '../auth/perfil.dart';
import 'facturacion_service.dart';
import 'modelos.dart';
import 'ticket_view.dart';

/// Facturas emitidas: estado en Hacienda, reenvío, anulación, devolución y factura con NIF.
class FacturasPage extends StatefulWidget {
  const FacturasPage({super.key});

  @override
  State<FacturasPage> createState() => _FacturasPageState();
}

class _FacturasPageState extends State<FacturasPage> {
  late Future<List<Map<String, dynamic>>> _facturas = _cargar();
  bool _trabajando = false;
  bool get _admin => Perfil.cache?.esAdmin ?? false;

  // Por defecto solo hoy: con un año de facturas no se puede cargar todo
  DateTimeRange _rango = _dia(DateTime.now());
  String _filtro = 'hoy';
  final _buscar = TextEditingController();
  List<Map<String, dynamic>> _pendientes = [];
  List<Map<String, dynamic>> _anulPendientes = [];
  int _rechazadas = 0;

  static DateTimeRange _dia(DateTime d) {
    final ini = DateTime(d.year, d.month, d.day);
    return DateTimeRange(start: ini, end: ini.add(const Duration(days: 1)));
  }

  Future<List<Map<String, dynamic>>> _cargar() async {
    final texto = _buscar.text.trim().toUpperCase();
    final m = RegExp(r'^([A-Z0-9]+)-(\d+)$').firstMatch(texto);
    var q = supabase.from('facturas').select();
    if (m != null) {
      // Búsqueda por número (P2-10): en todas las fechas
      q = q.eq('serie', m.group(1)!).eq('numero', int.parse(m.group(2)!));
    } else {
      q = q
          .gte('fecha', _rango.start.toUtc().toIso8601String())
          .lt('fecha', _rango.end.toUtc().toIso8601String());
    }
    final r = await Future.wait<dynamic>([
      q.order('fecha', ascending: false).limit(1000),
      // Pendientes y rechazadas: siempre a la vista, sean del día que sean
      supabase.from('facturas').select().inFilter('estado_envio', ['pendiente', 'error']).order('fecha'),
      supabase.from('tbai_anulaciones').select().inFilter('estado_envio', ['pendiente', 'error']),
    ]);
    final facturas = List<Map<String, dynamic>>.from(r[0] as List);
    // Rechazadas por Hacienda (factura o su anulación): siempre a la vista, arriba, sean del día que sean
    final enLista = {for (final f in facturas) f['id']};
    final rechazadas = [
      for (final f in r[1] as List)
        if (f['estado_envio'] == 'error' && f['legado'] != true) Map<String, dynamic>.from(f as Map)
    ];
    final idsAnulRech = [
      for (final a in r[2] as List)
        if (a['estado_envio'] == 'error' && !enLista.contains(a['factura_id'])) a['factura_id']
    ];
    if (idsAnulRech.isNotEmpty) {
      rechazadas.addAll(List<Map<String, dynamic>>.from(
          await supabase.from('facturas').select().inFilter('id', idsAnulRech).eq('legado', false)));
    }
    final extra = <Map<String, dynamic>>[];
    for (final f in rechazadas) {
      if (enLista.add(f['id'])) extra.add(f..['_fueraRango'] = true); // no suma en el total de las fechas elegidas
    }
    facturas.insertAll(0, extra);
    _rechazadas = rechazadas.length;
    _pendientes = List<Map<String, dynamic>>.from(r[1] as List).where((f) => f['estado_envio'] == 'pendiente').toList();
    _anulPendientes = List<Map<String, dynamic>>.from(r[2] as List).where((a) => a['estado_envio'] == 'pendiente').toList();
    final ids = facturas.map((f) => f['id']).toList();
    final r2 = ids.isEmpty
        ? [const [], const []]
        : await Future.wait<dynamic>([
            supabase.from('tbai_anulaciones').select().inFilter('factura_id', ids),
            supabase.from('facturas').select('rectifica_id, tipo, sustituye_simplificada').inFilter('rectifica_id', ids),
          ]);
    final anul = {for (final a in r2[0] as List) a['factura_id'] as String: Map<String, dynamic>.from(a as Map)};
    final hijas = List<Map<String, dynamic>>.from(r2[1] as List);
    final sustituidas = {for (final f in hijas) if (f['sustituye_simplificada'] == true) f['rectifica_id']};
    final rectificadas = {for (final f in hijas) if (f['tipo'] == 'rectificativa') f['rectifica_id']};
    for (final f in facturas) {
      f['_anulacion'] = anul[f['id']];
      f['_sustituida'] = sustituidas.contains(f['id']);
      f['_rectificada'] = rectificadas.contains(f['id']);
    }
    return facturas;
  }

  void _elegir(String filtro) async {
    final hoy = DateTime.now();
    DateTimeRange? r;
    switch (filtro) {
      case 'hoy':
        r = _dia(hoy);
      case 'ayer':
        r = _dia(hoy.subtract(const Duration(days: 1)));
      case 'semana':
        final lunes = DateTime(hoy.year, hoy.month, hoy.day).subtract(Duration(days: hoy.weekday - 1));
        r = DateTimeRange(start: lunes, end: _dia(hoy).end);
      case 'mes':
        r = DateTimeRange(start: DateTime(hoy.year, hoy.month), end: _dia(hoy).end);
      case 'fechas':
        final e = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2024),
          lastDate: hoy,
          initialDateRange: DateTimeRange(start: _rango.start, end: _rango.end.subtract(const Duration(days: 1))),
        );
        if (e == null) return;
        r = DateTimeRange(start: e.start, end: _dia(e.end).end);
    }
    _buscar.clear();
    setState(() {
      _filtro = filtro;
      _rango = r!;
      _facturas = _cargar();
    });
  }

  String _f(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Widget _barra(List<Map<String, dynamic>> facturas) {
    final validas = facturas.where((f) => f['_anulacion'] == null && f['_sustituida'] != true && f['_fueraRango'] != true);
    final total = validas.fold<double>(0, (s, f) => s + (f['importe_total'] as num).toDouble());
    final fin = _rango.end.subtract(const Duration(days: 1));
    final rotulo = _buscar.text.trim().isNotEmpty
        ? 'Búsqueda'
        : _rango.start == fin ? _f(fin) : '${_f(_rango.start)} – ${_f(fin)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final e in const {'hoy': 'Hoy', 'ayer': 'Ayer', 'semana': 'Esta semana', 'mes': 'Este mes', 'fechas': 'Elegir fechas…'}.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: _filtro == e.key && _buscar.text.trim().isEmpty,
              onSelected: (_) => _elegir(e.key),
            ),
          SizedBox(
            width: 220,
            child: TextField(
              controller: _buscar,
              decoration: const InputDecoration(isDense: true, hintText: 'Buscar nº (ej. P2-10)', prefixIcon: Icon(Icons.search)),
              onSubmitted: (_) => _recargar(),
            ),
          ),
          // Los zips de Drive con los ficheros firmados (lo que se entrega si Hacienda los pide)
          if (_admin)
            OutlinedButton.icon(
              onPressed: _copiasDrive,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Copias en Drive'),
            ),
        ]),
        const SizedBox(height: 8),
        Text('$rotulo · ${facturas.length} documentos · ${euros(total)}', style: const TextStyle(color: C.gris)),
      ]),
    );
  }

  void _recargar() => setState(() => _facturas = _cargar());

  static String _nombreMes(String mes) {
    const nombres = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre',
      'Octubre', 'Noviembre', 'Diciembre'];
    final p = mes.split('-');
    final m = int.tryParse(p.length == 2 ? p[1] : '') ?? 0;
    return m >= 1 && m <= 12 ? '${nombres[m - 1]} ${p[0]}' : mes;
  }

  /// La copia más reciente de cada mes en Google Drive, con su enlace.
  Future<void> _copiasDrive() async {
    List<Map<String, dynamic>> copias;
    try {
      copias = List<Map<String, dynamic>>.from(await supabase
          .from('copias_seguridad')
          .select('mes, enlace, detalle, creado_en')
          .eq('estado', 'ok')
          .order('creado_en', ascending: false)
          .limit(300));
    } catch (e) {
      _avisar(textoError(e));
      return;
    }
    final porMes = <String, Map<String, dynamic>>{};
    for (final c in copias) {
      porMes.putIfAbsent(c['mes'] as String, () => c);
    }
    final meses = porMes.values.toList()..sort((a, b) => (b['mes'] as String).compareTo(a['mes'] as String));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copias en Google Drive'),
        content: SizedBox(
          width: 480,
          child: meses.isEmpty
              ? const Text('Todavía no hay ninguna copia. Se hace sola cada noche.')
              : ListView(shrinkWrap: true, children: [
                  const Text(
                    'Un zip por mes con todos los ficheros TicketBAI firmados y la respuesta de Hacienda. '
                    'Es lo que se entrega si Hacienda pide los ficheros.',
                    style: TextStyle(color: C.gris, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  for (final c in meses)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_zip_outlined),
                      title: Text(_nombreMes(c['mes'] as String)),
                      subtitle: Text('${c['detalle'] ?? ''} · copia del ${_f(DateTime.parse(c['creado_en'] as String).toLocal())}'),
                      trailing: c['enlace'] == null
                          ? null
                          : Wrap(spacing: 4, children: [
                              IconButton(
                                tooltip: 'Copiar enlace',
                                icon: const Icon(Icons.copy),
                                onPressed: () async {
                                  await Clipboard.setData(ClipboardData(text: c['enlace'] as String));
                                  _avisar('Enlace copiado');
                                },
                              ),
                              IconButton(
                                tooltip: 'Abrir en Drive',
                                icon: const Icon(Icons.open_in_new),
                                onPressed: () async {
                                  final ok = await launchUrl(Uri.parse(c['enlace'] as String),
                                      mode: LaunchMode.externalApplication);
                                  if (!ok) _avisar('No se pudo abrir: copia el enlace');
                                },
                              ),
                            ]),
                    ),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
      ),
    );
  }

  void _avisar(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _ejecutar(Future<Map<String, dynamic>> Function() accion, String ok) async {
    setState(() => _trabajando = true);
    try {
      final r = await accion();
      _avisar(r['estado_envio'] == 'error' ? 'Hacienda lo ha rechazado: mira el detalle' : ok);
    } catch (e) {
      _avisar('No se pudo: $e');
    }
    if (!mounted) return;
    setState(() => _trabajando = false);
    _recargar();
  }

  Future<void> _emitirPrueba() => _ejecutar(
        () => FacturacionService().emitir(lineas: const [
          LineaFactura('Txakoli Getariako', 2, 3.20),
          LineaFactura('Ensalada de bonito', 1, 11.50),
          LineaFactura('Carrilleras al vino', 1, 16.90),
          LineaFactura('Café con leche', 2, 1.80),
        ]),
        'Factura emitida',
      );

  Future<void> _reenviarPendientes(List<Map<String, dynamic>> facturas, List<Map<String, dynamic>> anulaciones) async {
    setState(() => _trabajando = true);
    var ok = 0;
    // De la más antigua a la más reciente: Hacienda espera recibir la cadena en orden
    final orden = [...facturas]..sort((a, b) => (a['fecha'] as String).compareTo(b['fecha'] as String));
    for (final f in orden) {
      try {
        if ((await FacturacionService().reenviar(f))['estado_envio'] == 'enviada') ok++;
      } catch (_) {}
    }
    for (final a in anulaciones) {
      try {
        if ((await FacturacionService().reenviarAnulacion(a))['estado_envio'] == 'enviada') ok++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _trabajando = false);
    _recargar();
    _avisar('Enviadas $ok de ${facturas.length + anulaciones.length}');
  }

  // ---------- Acciones sobre una factura ----------

  Future<void> _anular(Map<String, dynamic> f) async {
    final motivo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Anular ${f['serie']}-${f['numero']}'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Se comunica a Hacienda que esta factura no es válida (por ejemplo, se emitió por error). '
                'La factura no se borra: queda marcada como anulada.\n\n'
                'Si el cliente devuelve algo o hay que cambiar importes, usa «Devolución» en su lugar.'),
            const SizedBox(height: 12),
            TextField(controller: motivo, decoration: const InputDecoration(labelText: 'Motivo (opcional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB3261E)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Anular factura'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _ejecutar(() => FacturacionService().anular(f, motivo: motivo.text.trim().isEmpty ? null : motivo.text.trim()),
          'Anulación enviada');
    }
  }

  Future<void> _devolver(Map<String, dynamic> f) async {
    final lineas = (f['lineas'] as List).map((m) => LineaFactura.fromMap(Map<String, dynamic>.from(m as Map))).toList();
    final cantidades = [for (final _ in lineas) 0.0]; // se sube lo que se devuelve
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final total = [for (var i = 0; i < lineas.length; i++) cantidades[i] * lineas[i].precioUnitario].fold(0.0, (a, b) => a + b);
        return AlertDialog(
          title: Text('Devolución de ${f['serie']}-${f['numero']}'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Sube la cantidad de lo que el cliente devuelve. Se emite una factura rectificativa '
                  'con esos importes en negativo.'),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setD(() {
                    for (var i = 0; i < lineas.length; i++) {
                      cantidades[i] = lineas[i].cantidad;
                    }
                  }),
                  child: const Text('Devolver todo'),
                ),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < lineas.length; i++)
                Row(children: [
                  Expanded(child: Text(lineas[i].descripcion)),
                  IconButton(
                    onPressed: cantidades[i] <= 0 ? null : () => setD(() => cantidades[i] -= 1),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  SizedBox(width: 44, child: Text('${cantidades[i].toStringAsFixed(0)} / ${lineas[i].cantidad.toStringAsFixed(0)}')),
                  IconButton(
                    onPressed: cantidades[i] >= lineas[i].cantidad ? null : () => setD(() => cantidades[i] += 1),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ]),
              const Divider(),
              Text('Se devuelve: ${euros(total)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: total <= 0 ? null : () => Navigator.pop(ctx, true), child: const Text('Emitir rectificativa')),
          ],
        );
      }),
    );
    if (ok != true) return;
    final devueltas = [
      for (var i = 0; i < lineas.length; i++)
        if (cantidades[i] > 0) LineaFactura(lineas[i].descripcion, cantidades[i], lineas[i].precioUnitario),
    ];
    await _ejecutar(() => FacturacionService().rectificar(f, devueltas), 'Rectificativa emitida');
  }

  Future<void> _conNif(Map<String, dynamic> f) async {
    final clientes = List<Map<String, dynamic>>.from(await supabase.from('clientes').select().eq('activo', true).order('nombre'));
    if (!mounted) return;
    final cliente = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Factura con NIF'),
        content: SizedBox(
          width: 440,
          height: 380,
          child: Column(children: [
            const Text('El cliente pide factura de este ticket. Se emite una factura completa con sus datos '
                'que sustituye al ticket.'),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(children: [
                for (final c in clientes)
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: Text(c['nombre'] as String),
                    subtitle: Text('${c['documento'] ?? ''}'),
                    onTap: () => Navigator.pop(ctx, c),
                  ),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton.icon(
            onPressed: () async {
              final nuevo = await editarCliente(ctx);
              if (nuevo != null && ctx.mounted) Navigator.pop(ctx, nuevo);
            },
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Nuevo cliente'),
          ),
        ],
      ),
    );
    if (cliente == null) return;
    await _ejecutar(() => FacturacionService().facturaConNif(f, cliente), 'Factura con NIF emitida');
  }

  /// Factura rechazada por Hacienda: se envían sus datos, corregidos, por el servicio Zuzendu.
  Future<void> _subsanar(Map<String, dynamic> f) async {
    final r = _respuesta(f['respuesta_envio'] as String?);
    final motivo = [
      if (r['descripcion'] != null) '${r['descripcion']}',
      for (final a in (r['avisos'] as List?) ?? const []) '${a['codigo']}: ${a['descripcion']}',
    ].join(' · ');
    final conCliente = f['cliente_nif'] != null;
    final razon = TextEditingController(text: f['razon_social_emisor'] as String?);
    final nif = TextEditingController(text: f['cliente_nif'] as String?);
    final nombre = TextEditingController(text: f['cliente_nombre'] as String?);
    final direccion = TextEditingController(text: f['cliente_direccion'] as String?);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Subsanar ${f['serie']}-${f['numero']}'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (motivo.isNotEmpty) Text('Hacienda la rechazó: $motivo', style: const TextStyle(color: Color(0xFFB3261E))),
              const SizedBox(height: 8),
              const Text(
                  'Corrige el dato equivocado y envía. La factura y su fichero original no cambian: '
                  'a Hacienda le llegan los datos corregidos (servicio Zuzendu). Si el fallo era del programa, '
                  'basta con enviar tal cual desde la versión corregida.',
                  style: TextStyle(color: C.gris, fontSize: 13)),
              const SizedBox(height: 12),
              TextField(controller: razon, decoration: const InputDecoration(labelText: 'Razón social del emisor')),
              if (conCliente) ...[
                const SizedBox(height: 10),
                TextField(controller: nif, decoration: const InputDecoration(labelText: 'NIF del cliente')),
                const SizedBox(height: 10),
                TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre del cliente')),
                const SizedBox(height: 10),
                TextField(controller: direccion, decoration: const InputDecoration(labelText: 'Dirección del cliente')),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enviar subsanación')),
        ],
      ),
    );
    if (ok != true) return;
    await _ejecutar(
      () => FacturacionService().subsanar(
        f,
        razonSocial: razon.text.trim(),
        cliente: !conCliente
            ? null
            : {'documento': nif.text.trim().toUpperCase(), 'nombre': nombre.text.trim(), 'direccion': direccion.text.trim()},
      ),
      'Subsanación recibida por Hacienda',
    );
  }

  // ---------- Vista ----------

  static Map<String, dynamic> _respuesta(String? texto) {
    try {
      return Map<String, dynamic>.from(jsonDecode(texto ?? '{}') as Map);
    } catch (_) {
      return {'descripcion': texto};
    }
  }

  static (String, Color) _estado(String? e) => switch (e) {
        'enviada' => ('Recibida por Hacienda', const Color(0xFF0F5C4D)),
        'error' => ('Rechazada', const Color(0xFFB3261E)),
        'pendiente' => ('Pendiente de envío', const Color(0xFFB45309)),
        _ => ('Simulada', Colors.grey),
      };

  static String _tipo(Map<String, dynamic> f) => switch (f['tipo']) {
        'rectificativa' => 'Rectificativa ${f['rectificativa_codigo'] ?? ''}',
        'completa' => f['sustituye_simplificada'] == true ? 'Factura con NIF (sustituye ticket)' : 'Factura con NIF',
        _ => 'Ticket',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Emitir, anular y devolver: solo el administrador (Gestión solo consulta)
      floatingActionButton: !_admin ? null : FloatingActionButton.extended(
        onPressed: _trabajando ? null : _emitirPrueba,
        icon: const Icon(Icons.receipt_long),
        label: Text(_trabajando ? 'Trabajando…' : 'Emitir factura de prueba'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _facturas,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(esErrorDeRed(snap.error!) ? Icons.wifi_off : Icons.error_outline, size: 40, color: C.gris),
                  const SizedBox(height: 12),
                  Text(
                    esErrorDeRed(snap.error!)
                        ? 'Sin internet: la lista se verá al volver la conexión.\n'
                            'Los tickets cobrados sin internet están guardados en este equipo y se envían solos.'
                        : 'Error: ${snap.error}',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _recargar, child: const Text('Reintentar')),
                  // Tickets cobrados sin internet en este equipo, aún sin subir
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: VentaOffline.cola(),
                    builder: (context, c) {
                      final cola = c.data ?? const [];
                      if (cola.isEmpty) return const SizedBox();
                      return Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('Guardados en este equipo (${cola.length})', style: titulo(16)),
                          for (final v in cola)
                            () {
                              final f = Map<String, dynamic>.from(v['factura'] as Map);
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.cloud_off, color: Color(0xFFB45309)),
                                title: Text('${f['serie']}-${f['numero']} · ${euros(f['importe_total'] as num)}'),
                                subtitle: const Text('Se sube y se envía a Hacienda al volver internet'),
                                onTap: () => mostrarTicket(context, f, imprimirAuto: false),
                              );
                            }(),
                        ]),
                      );
                    },
                  ),
                ]),
              ),
            );
          }
          final facturas = snap.data!;
          // Las rechazadas no se reenvían tal cual: hay que corregirlas
          final pendientes = _pendientes;
          final anulPendientes = _anulPendientes;
          final nPend = pendientes.length + anulPendientes.length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              _barra(facturas),
              if (facturas.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No hay facturas en estas fechas.', style: TextStyle(color: C.gris))),
                ),
              if (_rechazadas > 0)
                Card(
                  color: const Color(0xFFFBE4E2),
                  elevation: 0,
                  child: ListTile(
                    leading: const Icon(Icons.error_outline, color: Color(0xFFB3261E)),
                    title: Text('$_rechazadas ${_rechazadas == 1 ? 'rechazada' : 'rechazadas'} por Hacienda'),
                    subtitle: const Text('Salen arriba aunque sean de otro día. Mira el motivo en cada una y corrígela.'),
                  ),
                ),
              if (nPend > 0)
                Card(
                  color: const Color(0xFFFDF0DC),
                  elevation: 0,
                  child: ListTile(
                    leading: const Icon(Icons.cloud_upload_outlined, color: Color(0xFFB45309)),
                    title: Text('$nPend ${nPend == 1 ? 'envío pendiente' : 'envíos pendientes'} a Hacienda'),
                    subtitle: const Text('Se quedan guardados; envíalos cuando haya conexión.'),
                    trailing: FilledButton(
                      onPressed: _trabajando ? null : () => _reenviarPendientes(pendientes, anulPendientes),
                      child: const Text('Enviar ahora'),
                    ),
                  ),
                ),
              for (final f in facturas) _fila(f),
            ],
          );
        },
      ),
    );
  }

  Widget _fila(Map<String, dynamic> f) {
    final (texto, color) = _estado(f['estado_envio'] as String?);
    final r = _respuesta(f['respuesta_envio'] as String?);
    final avisos = (r['avisos'] as List?) ?? const [];
    final anul = f['_anulacion'] as Map?;
    final ra = anul == null ? null : _respuesta(anul['respuesta_envio'] as String?);
    final anulada = anul != null && (anul['estado_envio'] == 'enviada' || anul['estado_envio'] == 'simulada');
    final valida = !anulada && (f['estado_envio'] == 'enviada' || f['estado_envio'] == 'simulada');
    return ListTile(
      leading: Icon(anulada ? Icons.block : Icons.receipt, color: anulada ? Colors.grey : color),
      title: Text(
        '${f['serie']}-${f['numero']} · ${euros(f['importe_total'] as num)} · ${_tipo(f)}',
        style: TextStyle(decoration: anulada ? TextDecoration.lineThrough : null),
      ),
      subtitle: Text([
        '${f['tbai_id']}',
        texto + (r['csv'] != null ? ' · CSV ${r['csv']}' : ''),
        if (f['estado_envio'] != 'enviada' && r['descripcion'] != null) '${r['descripcion']}',
        for (final a in avisos) '${a['codigo']}: ${a['descripcion']}',
        if (r['subsanada'] == true) 'Subsanada (servicio Zuzendu)',
        if (f['_sustituida'] == true) 'Sustituida por una factura con NIF',
        if (f['_rectificada'] == true) 'Tiene devoluciones (rectificativa)',
        if (anul != null)
          'ANULACIÓN: ${_estado(anul['estado_envio'] as String?).$1}'
              '${ra?['csv'] != null ? ' · CSV ${ra!['csv']}' : ''}'
              '${anul['estado_envio'] != 'enviada' && ra?['descripcion'] != null ? ' · ${ra!['descripcion']}' : ''}'
              '${((ra?['avisos'] as List?) ?? const []).map((a) => ' · ${a['codigo']}: ${a['descripcion']}').join()}',
      ].join('\n')),
      isThreeLine: true,
      onTap: () => mostrarTicket(context, f, imprimirAuto: false),
      trailing: f['estado_envio'] == 'error' && !_trabajando
          ? PopupMenuButton<String>(
              tooltip: 'Factura rechazada: qué hacer',
              icon: const Icon(Icons.error_outline, color: Color(0xFFB3261E)),
              onSelected: (v) => v == 'subsanar' ? _subsanar(f) : _reenviarPendientes([f], const []),
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'reenviar',
                    child: ListTile(
                        leading: Icon(Icons.refresh),
                        title: Text('Reintentar el envío'),
                        subtitle: Text('Fallo del certificado o del servicio de Hacienda'))),
                if (_admin)
                  const PopupMenuItem(
                      value: 'subsanar',
                      child: ListTile(
                          leading: Icon(Icons.build_outlined),
                          title: Text('Subsanar (Zuzendu)'),
                          subtitle: Text('Hacienda rechazó los datos del fichero'))),
              ],
            )
          : !valida || _trabajando || !_admin
          ? null
          : PopupMenuButton<String>(
              tooltip: 'Acciones',
              onSelected: (v) => switch (v) {
                'nif' => _conNif(f),
                'devolver' => _devolver(f),
                _ => _anular(f),
              },
              itemBuilder: (_) => [
                if (f['tipo'] == 'simplificada' && f['_sustituida'] != true)
                  const PopupMenuItem(value: 'nif', child: ListTile(leading: Icon(Icons.badge_outlined), title: Text('Factura con NIF'))),
                if (f['tipo'] != 'rectificativa')
                  const PopupMenuItem(value: 'devolver', child: ListTile(leading: Icon(Icons.undo), title: Text('Devolución (rectificativa)'))),
                const PopupMenuItem(value: 'anular', child: ListTile(leading: Icon(Icons.block, color: Color(0xFFB3261E)), title: Text('Anular'))),
              ],
            ),
    );
  }
}
