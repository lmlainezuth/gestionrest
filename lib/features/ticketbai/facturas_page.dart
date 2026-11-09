import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../ajustes/clientes_tab.dart' show editarCliente;
import '../barra/venta_offline.dart';
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

  Future<List<Map<String, dynamic>>> _cargar() async {
    final r = await Future.wait([
      supabase.from('facturas').select().order('fecha', ascending: false).limit(200),
      supabase.from('tbai_anulaciones').select(),
    ]);
    final anul = {for (final a in r[1]) a['factura_id'] as String: Map<String, dynamic>.from(a)};
    final facturas = List<Map<String, dynamic>>.from(r[0]);
    final sustituidas = {for (final f in facturas) if (f['sustituye_simplificada'] == true) f['rectifica_id']};
    final rectificadas = {for (final f in facturas) if (f['tipo'] == 'rectificativa') f['rectifica_id']};
    for (final f in facturas) {
      f['_anulacion'] = anul[f['id']];
      f['_sustituida'] = sustituidas.contains(f['id']);
      f['_rectificada'] = rectificadas.contains(f['id']);
    }
    return facturas;
  }

  void _recargar() => setState(() => _facturas = _cargar());

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
      floatingActionButton: FloatingActionButton.extended(
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
          if (facturas.isEmpty) return const Center(child: Text('Todavía no hay facturas emitidas.'));
          // Las rechazadas no se reenvían tal cual: hay que corregirlas
          final pendientes = facturas.where((f) => f['estado_envio'] == 'pendiente').toList();
          final anulPendientes = [
            for (final f in facturas)
              if ((f['_anulacion'] as Map?)?['estado_envio'] == 'pendiente') Map<String, dynamic>.from(f['_anulacion'] as Map),
          ];
          final nPend = pendientes.length + anulPendientes.length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
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
          ? IconButton(
              tooltip: 'Reintentar el envío (cuando se haya corregido la causa del rechazo)',
              onPressed: () => _reenviarPendientes([f], const []),
              icon: const Icon(Icons.refresh, color: Color(0xFFB3261E)),
            )
          : !valida || _trabajando
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
