import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/impresion.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../carta/colores.dart' show leerImporte;
import 'cierre_ciego.dart';
import '../ticketbai/modelos.dart' show euros;
import 'abrir_caja.dart';
import 'caja_service.dart';

/// Turno de caja: apertura con fondo, ventas por forma de pago,
/// ingresos y gastos, y cierre con arqueo.
class CajaPage extends StatefulWidget {
  const CajaPage({super.key});

  @override
  State<CajaPage> createState() => _CajaPageState();
}

class _CajaPageState extends State<CajaPage> {
  bool _cargando = true;
  String? _error;
  Map<String, dynamic>? _caja;
  Map<String, dynamic>? _turno;
  Map<String, double> _ventas = {};
  List<Map<String, dynamic>> _movimientos = [];
  List<Map<String, dynamic>> _conceptos = [];
  int _tickets = 0;
  int _mesasAbiertas = 0; // todo lo que queda sin cobrar: mesas + cuentas de barra con nombre
  String? _sinCobrarDetalle;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      _caja = await CajaService.caja();
      _turno = await CajaService.turnoAbierto(_caja!['id'] as String);
      _conceptos = List<Map<String, dynamic>>.from(
          await supabase.from('conceptos_gasto').select().eq('activo', true).order('nombre'));
      if (_turno != null) {
        final pagos = await supabase.from('pagos').select('metodo, importe, pedido_id').eq('turno_id', _turno!['id']);
        _ventas = {};
        for (final p in pagos) {
          final m = p['metodo'] as String;
          _ventas[m] = (_ventas[m] ?? 0) + (p['importe'] as num).toDouble();
        }
        _tickets = pagos.map((p) => p['pedido_id']).toSet().length;
        _movimientos = List<Map<String, dynamic>>.from(await supabase
            .from('movimientos_caja')
            .select('*, conceptos_gasto(nombre)')
            .eq('turno_id', _turno!['id'])
            .order('creado_en', ascending: false));
        final abiertos =
            await supabase.from('pedidos').select('id, tipo, nombre_llevar').inFilter('estado', ['abierto', 'precuenta']);
        // Una venta rápida de barra sin nombre no es una cuenta: es un cobro que se quedó a medias
        final mesas = abiertos.where((p) => p['tipo'] == 'mesa').length;
        final barra = abiertos.where((p) => p['tipo'] == 'barra' && p['nombre_llevar'] != null).length;
        final llevar = abiertos.where((p) => p['tipo'] == 'llevar').length;
        _mesasAbiertas = mesas + barra + llevar;
        _sinCobrarDetalle = _mesasAbiertas == 0
            ? null
            : [
                if (mesas > 0) '$mesas de mesas',
                if (barra > 0) '$barra de barra',
                if (llevar > 0) '$llevar para llevar',
              ].join(' · ');
      }
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  double get _ingresos => _sumaMov('ingreso');
  double get _gastos => _sumaMov('gasto');
  double _sumaMov(String tipo) =>
      _movimientos.where((m) => m['tipo'] == tipo).fold(0.0, (s, m) => s + (m['importe'] as num).toDouble());
  double get _totalVentas => _ventas.values.fold(0.0, (s, v) => s + v);
  double get _efectivoEsperado =>
      (_turno!['efectivo_inicial'] as num).toDouble() + (_ventas['efectivo'] ?? 0) + _ingresos - _gastos;

  Future<void> _abrir() => _accion(() => abrirCajaRapida(context));

  Future<void> _movimiento(String tipo) async {
    final ctrl = TextEditingController();
    final desc = TextEditingController();
    String? concepto = tipo == 'gasto' && _conceptos.isNotEmpty ? _conceptos.first['id'] as String : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tipo == 'gasto' ? 'Registrar gasto' : 'Registrar ingreso'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Importe', suffixText: '€'),
                ),
                const SizedBox(height: 12),
                if (tipo == 'gasto')
                  DropdownButtonFormField<String>(
                    initialValue: concepto,
                    decoration: const InputDecoration(labelText: 'Concepto'),
                    items: [
                      for (final c in _conceptos)
                        DropdownMenuItem(value: c['id'] as String, child: Text(c['nombre'] as String)),
                    ],
                    onChanged: (v) => setD(() => concepto = v),
                  ),
                if (tipo == 'gasto') const SizedBox(height: 12),
                TextField(controller: desc, decoration: const InputDecoration(labelText: 'Descripción (opcional)')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    final importe = leerImporte(ctrl.text);
    final texto = desc.text.trim();
    if (ok != true || importe == null || importe <= 0) return;
    await _accion(() => supabase.from('movimientos_caja').insert({
          'turno_id': _turno!['id'],
          'tipo': tipo,
          'concepto_id': concepto,
          'importe': importe,
          'descripcion': texto.isEmpty ? null : texto,
          'usuario_id': supabase.auth.currentUser!.id,
        }));
  }

  /// Cuadre ciego: se cuenta sin ver lo esperado; el servidor calcula y guarda la diferencia.
  Future<void> _cerrar() async {
    final datos = await contarCajaCiega(context,
        aviso: _mesasAbiertas > 0 ? 'Atención: hay $_mesasAbiertas cuentas sin cobrar ($_sinCobrarDetalle)' : null,
        fondo: (_turno!['efectivo_inicial'] as num).toDouble());
    if (datos == null) return;
    // Datos del turno antes de cerrarlo (al recargar desaparecen)
    final turno = Map<String, dynamic>.from(_turno!);
    final cajaNombre = _caja!['nombre'] as String;
    final ventas = Map<String, double>.from(_ventas);
    final tickets = _tickets;
    final ingresos = _ingresos, gastos = _gastos;
    Map<String, dynamic>? r;
    await _accion(() async {
      r = Map<String, dynamic>.from(await supabase.rpc('cerrar_caja_ciego', params: {
        'p_turno': _turno!['id'],
        'p_efectivo': datos['efectivo'],
        'p_conteo': datos['conteo'],
        'p_tarjeta': datos['tarjeta'],
        'p_nota': datos['nota'],
        'p_fondo': datos['fondo'],
      }) as Map);
    });
    if (!mounted || r == null) return;
    void imprimir() => imprimirCierreCaja(
          r: r!, datos: datos, turno: turno, cajaNombre: cajaNombre,
          ventas: ventas, tickets: tickets, ingresos: ingresos, gastos: gastos,
        ).catchError((e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo imprimir: $e')));
        });
    imprimir();
    // Sin ventana con el resultado: sale el papel y ya. Queda un aviso con «Reimprimir» por si
    // la impresora falló (el encargado también puede reimprimirlo desde Cierres y descuadres).
    final aviso = ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: const Text('Caja cerrada. Se ha impreso el cierre.'),
      action: SnackBarAction(label: 'Reimprimir', onPressed: imprimir),
    ));
    // Un aviso con botón no se quita solo en las versiones nuevas de Flutter: se cierra a mano
    var cerrado = false;
    aviso.closed.then((_) => cerrado = true);
    Future.delayed(const Duration(seconds: 10), () {
      if (!cerrado) aviso.close();
    });
  }

  Future<void> _accion(Future<dynamic> Function() f) async {
    try {
      await f();
      await _cargar();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AvisoSinConexion(textoError(_error), onReintentar: () {
        setState(() {
          _error = null;
          _cargando = true;
        });
        _cargar();
      });
    }

    if (_turno == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 56, color: C.gris),
            const SizedBox(height: 12),
            Text('${_caja!['nombre']} cerrada', style: titulo(26)),
            const SizedBox(height: 6),
            const Text('Abre la caja para empezar a cobrar.', style: TextStyle(color: C.gris)),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: _abrir, icon: const Icon(Icons.lock_open), label: const Text('Abrir caja')),
          ],
        ),
      );
    }

    final abierta = DateTime.parse(_turno!['abierto_en'] as String).toLocal();
    final hora = '${abierta.hour.toString().padLeft(2, '0')}:${abierta.minute.toString().padLeft(2, '0')}';

    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('${_caja!['nombre']} · abierta a las $hora · fondo ${euros(_turno!['efectivo_inicial'] as num)}',
                  style: const TextStyle(color: C.gris)),
            ),
            OutlinedButton.icon(
              onPressed: () => Impresion.abrirCajon().catchError((e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo abrir el cajón: $e')));
              }),
              icon: const Icon(Icons.point_of_sale),
              label: const Text('Abrir cajón'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: () => _movimiento('ingreso'), icon: const Icon(Icons.add), label: const Text('Ingreso')),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: () => _movimiento('gasto'), icon: const Icon(Icons.remove), label: const Text('Gasto')),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: C.tinta),
              onPressed: _cerrar,
              icon: const Icon(Icons.lock_outline),
              label: const Text('Cerrar caja'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: !(Perfil.cache?.esAdmin ?? false)
              ? [
                  // Cuadre ciego: el camarero no ve importes del turno
                  _Cifra('Tickets del turno', '$_tickets', 'Se cuenta a ciegas; el resultado sale en el cierre'),
                  _Cifra('Cuentas sin cobrar', '$_mesasAbiertas', _sinCobrarDetalle),
                ]
              : [
            _Cifra('Ventas del turno', euros(_totalVentas), '$_tickets tickets', destacada: true),
            _Cifra('Efectivo', euros(_ventas['efectivo'] ?? 0), null),
            _Cifra('Tarjeta', euros(_ventas['tarjeta'] ?? 0), null),
            _Cifra('Bizum', euros(_ventas['bizum'] ?? 0), null),
            _Cifra('Efectivo esperado en cajón', euros(_efectivoEsperado),
                'Fondo + efectivo + ingresos − gastos'),
            _Cifra('Cuentas sin cobrar', '$_mesasAbiertas', _sinCobrarDetalle),
          ],
        ),
        const SizedBox(height: 28),
        Text('Ingresos y gastos', style: titulo(20)),
        const SizedBox(height: 8),
        if (_movimientos.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Sin movimientos en este turno.', style: TextStyle(color: C.gris)),
          ),
        for (final m in _movimientos)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(m['tipo'] == 'gasto' ? Icons.arrow_upward : Icons.arrow_downward,
                color: m['tipo'] == 'gasto' ? C.naranja : C.verde),
            title: Text(((m['conceptos_gasto'] as Map?)?['nombre'] as String?) ??
                (m['tipo'] == 'gasto' ? 'Gasto' : 'Ingreso')),
            subtitle: m['descripcion'] == null ? null : Text(m['descripcion'] as String),
            trailing: Text('${m['tipo'] == 'gasto' ? '−' : '+'} ${euros(m['importe'] as num)}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }
}

class _Cifra extends StatelessWidget {
  const _Cifra(this.titulo_, this.valor, this.detalle, {this.destacada = false});
  final String titulo_;
  final String valor;
  final String? detalle;
  final bool destacada;

  @override
  Widget build(BuildContext context) {
    final fg = destacada ? C.sobreAccion : C.tinta;
    return Container(
      width: 250,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: destacada ? C.verde : C.blanco,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: destacada ? C.verde : C.borde),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo_, style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 13)),
          const SizedBox(height: 6),
          Text(valor, style: titulo(28, color: fg)),
          if (detalle != null) Text(detalle!, style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12)),
        ],
      ),
    );
  }
}

/// Ticket de cierre, uno solo e igual para todos (también se reimprime desde Cierres y descuadres):
/// recuento, ventas, esperado, diferencia y lo quitado antes de cobrar. Se cuenta a ciegas, pero el
/// resultado se imprime porque el recuento ya está guardado y no se puede cambiar (migración 0034).
/// Con un servidor sin la 0034, al camarero le sale solo el recuento.
Future<void> imprimirCierreCaja({
  required Map<String, dynamic> r,
  required Map<String, dynamic> datos,
  required Map<String, dynamic> turno,
  required String cajaNombre,
  required Map<String, double> ventas,
  required int tickets,
  required double ingresos,
  required double gastos,
  String? cierra, // quién cerró y cuándo: al reimprimir un cierre antiguo desde Cierres
  DateTime? cerradoEn,
}) async {
  String f(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  String etiqueta(double v) => v >= 1 ? '${v.toStringAsFixed(0)} EUR' : '${(v * 100).round()} cts';
  final l = <(String, String?)>[];
  final conteo = (datos['conteo'] as Map?)?.map((k, v) => MapEntry(double.parse('$k'), (v as num).toInt()));
  if (conteo != null && conteo.isNotEmpty) {
    final monedas = conteo.keys.where((v) => v < 5).toList()..sort((a, b) => b.compareTo(a));
    final billetes = conteo.keys.where((v) => v >= 5).toList()..sort((a, b) => b.compareTo(a));
    if (monedas.isNotEmpty) {
      l.add(('MONEDAS', null));
      for (final v in monedas) {
        l.add(('${conteo[v]} x ${etiqueta(v)}', euros(conteo[v]! * v)));
      }
    }
    if (billetes.isNotEmpty) {
      l.add(('BILLETES', null));
      for (final v in billetes) {
        l.add(('${conteo[v]} x ${etiqueta(v)}', euros(conteo[v]! * v)));
      }
    }
    l.add(('-', ''));
  }
  l.add(('!Efectivo contado', euros(datos['efectivo'] as num)));
  if (datos['tarjeta'] != null) l.add(('Datáfono (cierre banco)', euros(datos['tarjeta'] as num)));
  final fondo = (datos['fondo'] as num?) ?? 0;
  l
    ..add(('Fondo que queda en cajón', euros(fondo)))
    ..add(('!RETIRAR', euros(((datos['efectivo'] as num) - fondo).clamp(0, double.infinity))));

  if (r['esperado'] != null) {
    final total = ventas.values.fold(0.0, (s, v) => s + v);
    l
      ..add(('-', ''))
      ..add(('VENTAS ($tickets tickets)', null))
      ..add(('Efectivo', euros(ventas['efectivo'] ?? 0)))
      ..add(('Tarjeta', euros(ventas['tarjeta'] ?? 0)));
    if ((ventas['bizum'] ?? 0) > 0) l.add(('Bizum', euros(ventas['bizum']!)));
    l
      ..add(('!Total ventas', euros(total)))
      ..add(('-', ''))
      ..add(('EFECTIVO', null))
      ..add(('Fondo inicial', euros(turno['efectivo_inicial'] as num)))
      ..add(('+ Ventas en efectivo', euros(ventas['efectivo'] ?? 0)));
    final ing = (r['ingresos'] as num?)?.toDouble() ?? ingresos;
    final gas = (r['gastos'] as num?)?.toDouble() ?? gastos;
    if (ing > 0) l.add(('+ Ingresos', euros(ing)));
    if (gas > 0) l.add(('- Gastos / pagos', euros(gas)));
    final dif = (r['contado'] as num) - (r['esperado'] as num);
    l
      ..add(('Esperado', euros(r['esperado'] as num)))
      ..add(('Contado', euros(r['contado'] as num)))
      ..add((dif.abs() < 0.005 ? '!CUADRA' : (dif > 0 ? '!SOBRAN' : '!FALTAN'), euros(dif.abs())));
    if (r['tarjeta_contado'] != null && r['tarjeta_esperado'] != null) {
      final dt = (r['tarjeta_contado'] as num) - (r['tarjeta_esperado'] as num);
      l
        ..add(('-', ''))
        ..add(('DATÁFONO', null))
        ..add(('Esperado', euros(r['tarjeta_esperado'] as num)))
        ..add(('Contado', euros(r['tarjeta_contado'] as num)))
        ..add((dt.abs() < 0.005 ? '!CUADRA' : (dt > 0 ? '!SOBRAN' : '!FALTAN'), euros(dt.abs())));
    }
    // Control del turno: anulaciones y devoluciones (las haga quien las haga) y lo eliminado en Barra
    // antes de cobrar. Al cerrar lo da el servidor (0034 y 0035); al reimprimir un cierre antiguo
    // se consulta (solo encargado).
    try {
      double uds, imp;
      var anul = <({String tipo, int n, double importe})>[];
      if (r['quitados_uds'] != null) {
        uds = (r['quitados_uds'] as num).toDouble();
        imp = (r['quitados_importe'] as num).toDouble();
        anul = [
          for (final a in (r['anulaciones'] as List?) ?? const [])
            (tipo: a['tipo'] as String, n: (a['n'] as num).toInt(), importe: (a['importe'] as num).toDouble()),
        ];
      } else {
        final filas = await supabase
            .from('registro_anulaciones')
            .select('tipo, cantidad, importe')
            .gte('momento', turno['abierto_en'] as String)
            .lte('momento', (cerradoEn ?? DateTime.now()).toUtc().toIso8601String());
        final quitados = filas.where((f) => f['tipo'] == 'quitado_antes_cobrar');
        uds = quitados.fold(0.0, (s, q) => s + ((q['cantidad'] as num?) ?? 0));
        imp = quitados.fold(0.0, (s, q) => s + ((q['importe'] as num?) ?? 0));
        final porTipo = <String, (int, double)>{};
        for (final f in filas) {
          if (f['tipo'] == 'quitado_antes_cobrar') continue;
          final p = porTipo[f['tipo']] ?? (0, 0.0);
          porTipo[f['tipo'] as String] = (p.$1 + 1, p.$2 + ((f['importe'] as num?) ?? 0));
        }
        anul = [for (final e in porTipo.entries) (tipo: e.key, n: e.value.$1, importe: e.value.$2)];
      }
      const nombres = {
        'factura_anulada': 'facturas anuladas',
        'devolucion': 'devoluciones',
        'venta_anulada': 'ventas cobradas anuladas',
        'pedido_anulado': 'cuentas anuladas',
        'linea_anulada': 'productos anulados',
        'linea_borrada': 'productos borrados',
      };
      l
        ..add(('-', ''))
        ..add(('ANULACIONES Y DEVOLUCIONES', null));
      if (anul.isEmpty) l.add(('Ninguna', euros(0)));
      for (final a in anul) {
        l.add(('${a.n} ${nombres[a.tipo] ?? a.tipo}', euros(a.importe)));
      }
      l
        ..add(('-', ''))
        ..add(('PRODUCTOS ELIMINADOS', null))
        ..add(('${uds.toStringAsFixed(0)} antes de cobrar', euros(imp)))
        ..add(('Queda registrado quién hizo cada cosa.', ''));
    } catch (_) {
      // sin internet o sin la migración 0033: el cierre sale igual, sin estos apartados
    }
  } else {
    l..add(('-', ''))..add(('El resultado lo revisa el encargado', ''));
  }
  final nota = (datos['nota'] as String?) ?? '';
  if (nota.isNotEmpty) l..add(('-', ''))..add(('NOTA', null))..add((nota, ''));
  l..add(('-', ''))..add(('Firma:', ''))..add(('', ''))..add(('', ''));

  await Impresion.imprimirInforme('CIERRE DE CAJA', [
    cajaNombre,
    'Apertura ${f(DateTime.parse(turno['abierto_en'] as String).toLocal())}',
    'Cierre   ${f(cerradoEn ?? DateTime.now())}',
    'Cierra: ${cierra ?? Perfil.cache?.nombre ?? ''}',
  ], l);
}
