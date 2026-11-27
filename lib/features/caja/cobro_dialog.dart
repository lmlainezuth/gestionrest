import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../ajustes/clientes_tab.dart' show editarCliente;
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/facturacion_service.dart';
import '../ticketbai/modelos.dart';
import '../ticketbai/tbai_proveedor.dart' show precalentarFirma;
import '../ticketbai/ticket_view.dart' show InterruptorTicket;
import 'abrir_caja.dart';
import 'caja_service.dart';

typedef _Pago = ({String metodo, double importe, double? entregado});

const _nombreMetodo = {'efectivo': 'Efectivo', 'tarjeta': 'Tarjeta', 'bizum': 'Bizum'};

/// Última venta cobrada en este equipo, para tenerla a la vista (reclamaciones de cambio).
class UltimaVenta {
  static final ValueNotifier<({String hora, double total, String metodo, double? entregado, double? cambio})?> dato =
      ValueNotifier(null);

  /// [pagos]: {metodo, importe, entregado}.
  static void guardar(num total, List<Map<String, dynamic>> pagos) {
    final h = DateTime.now();
    final entregado = pagos.fold(0.0, (s, p) => s + ((p['entregado'] as num?) ?? 0));
    final enEfectivo = pagos.where((p) => p['entregado'] != null).fold(0.0, (s, p) => s + (p['importe'] as num));
    dato.value = (
      hora: '${h.hour.toString().padLeft(2, '0')}:${h.minute.toString().padLeft(2, '0')}',
      total: total.toDouble(),
      metodo: pagos.map((p) => _nombreMetodo[p['metodo']] ?? '${p['metodo']}').toSet().join(' + '),
      entregado: entregado > 0 ? entregado : null,
      cambio: entregado > 0 ? entregado - enEfectivo : null,
    );
  }
}

/// Cobra un pedido: admite varios pagos (mixto), ayuda a dividir a partes
/// iguales y factura con NIF. Emite la factura TicketBAI, cierra el pedido y
/// libera la mesa. Devuelve la factura emitida.
class CobroDialog extends StatefulWidget {
  const CobroDialog({super.key, required this.pedido, required this.mesaId});
  final Map<String, dynamic> pedido; // con pedido_detalle
  final String? mesaId;

  @override
  State<CobroDialog> createState() => _CobroDialogState();
}

class _CobroDialogState extends State<CobroDialog> {
  String _metodo = 'efectivo';
  final _importe = TextEditingController();
  final _entregado = TextEditingController();
  final List<_Pago> _pagos = [];
  Map<String, dynamic>? _cliente;
  bool _conNif = false;
  bool _cobrando = false;
  String? _error;

  // Teclado de números de la propia ventana: escribe en la casilla elegida
  late TextEditingController _destino = _entregado; // en efectivo, lo normal es marcar lo entregado
  bool _nuevo = true; // la primera tecla sustituye lo que hubiera en la casilla

  void _elegir(TextEditingController c) => setState(() {
        _destino = c;
        _nuevo = true;
      });

  void _pulsar(String d) {
    var t = _nuevo ? '' : _destino.text.replaceAll('.', ',');
    if (d == ',') {
      if (t.contains(',')) return;
      if (t.isEmpty) t = '0';
    } else {
      final i = t.indexOf(',');
      if (i >= 0 && t.length - i > 2) return; // dos decimales
      if (t == '0') t = '';
    }
    if (t.length >= 8) return;
    setState(() {
      _destino.text = t + d;
      _nuevo = false;
      _error = null;
    });
  }

  void _borrarTecla({bool todo = false}) {
    final t = _destino.text;
    setState(() {
      _destino.text = todo || t.isEmpty ? '' : t.substring(0, t.length - 1);
      _nuevo = false;
    });
  }

  late final List<LineaFactura> _lineas = [
    for (final d in ((widget.pedido['pedido_detalle'] as List?) ?? []).cast<Map<String, dynamic>>())
      if (d['estado_cocina'] != 'anulado')
        LineaFactura(d['descripcion'] as String, (d['cantidad'] as num).toDouble(), (d['precio_unitario'] as num).toDouble(),
            ((d['tipo_iva'] as num?) ?? 10).toDouble()),
  ];
  late final double _total = Desglose.de(_lineas).total;

  double get _pagado => _pagos.fold(0.0, (s, p) => s + p.importe);
  double get _restante => ((_total - _pagado) * 100).roundToDouble() / 100;
  double get _importeActual => leerImporte(_importe.text) ?? 0;

  /// Si se eligió «Entre N», cada pago propone su parte (el último, lo que falte).
  int? _entre;
  double get _propuesto {
    if (_entre == null) return _restante;
    final parte = (_total / _entre! * 100).ceilToDouble() / 100;
    return parte > _restante ? _restante : parte;
  }

  /// ¿Se pagó de verdad a partes iguales? N pagos, todos de la parte (el último, lo que faltaba).
  bool get _aPartesIguales {
    final n = _entre;
    if (n == null || _pagos.length != n) return false;
    final parte = (_total / n * 100).ceilToDouble() / 100;
    for (var i = 0; i < n - 1; i++) {
      if ((_pagos[i].importe - parte).abs() > 0.005) return false;
    }
    return _pagos.last.importe <= parte + 0.005;
  }

  @override
  void initState() {
    super.initState();
    precalentarFirma(); // por si se cobra desde mesas sin haber pasado por Barra
    _ponerImporte(_restante);
  }

  void _ponerImporte(double v) => _importe.text = v.toStringAsFixed(2).replaceAll('.', ',');

  double? get _cambio {
    final e = leerImporte(_entregado.text);
    return e == null ? null : e - _importeActual;
  }

  /// Añade el pago en curso. Devuelve false si no es válido.
  bool _anadirPago() {
    final imp = _importeActual;
    if (imp <= 0) {
      setState(() => _error = 'Importe no válido');
      return false;
    }
    if (imp > _restante + 0.001 && _metodo != 'efectivo') {
      setState(() => _error = 'Con $_metodo no se puede cobrar más de lo que falta');
      return false;
    }
    final entregado = leerImporte(_entregado.text);
    if (_metodo == 'efectivo' && entregado != null && entregado < imp) {
      setState(() => _error = 'Lo entregado no cubre el importe');
      return false;
    }
    final real = imp > _restante ? _restante : imp; // en efectivo el exceso es cambio
    setState(() {
      _pagos.add((metodo: _metodo, importe: real, entregado: _metodo == 'efectivo' ? (entregado ?? imp) : null));
      _error = null;
      _entregado.clear();
      _ponerImporte(_propuesto);
      _nuevo = true;
    });
    return true;
  }

  Future<void> _boton() async {
    if (_restante > 0.001) {
      final completa = _importeActual >= _restante - 0.001;
      if (!_anadirPago() || !completa) return;
    }
    await _cobrar();
  }

  Future<void> _elegirCliente() async {
    final clientes = List<Map<String, dynamic>>.from(
        await supabase.from('clientes').select().eq('activo', true).neq('documento', '').order('nombre'));
    if (!mounted) return;
    final elegido = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        var buscar = '';
        return StatefulBuilder(builder: (ctx, setD) {
          final lista = clientes
              .where((c) => '${c['nombre']} ${c['documento']}'.toLowerCase().contains(buscar.toLowerCase()))
              .toList();
          return AlertDialog(
            title: const Text('Cliente de la factura'),
            content: SizedBox(
              width: 440,
              height: 380,
              child: Column(children: [
                TextField(
                  autofocus: true,
                  onChanged: (v) => setD(() => buscar = v),
                  decoration: const InputDecoration(hintText: 'Buscar por nombre o NIF', prefixIcon: Icon(Icons.search)),
                ),
                Expanded(
                  child: ListView(children: [
                    for (final c in lista)
                      ListTile(
                        title: Text(c['nombre'] as String),
                        subtitle: Text(c['documento'] as String? ?? ''),
                        onTap: () => Navigator.pop(ctx, c),
                      ),
                  ]),
                ),
              ]),
            ),
            actions: [
              TextButton.icon(
                onPressed: () async {
                  final nuevo = await editarCliente(ctx);
                  if (nuevo != null && ctx.mounted) Navigator.pop(ctx, nuevo);
                },
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Nuevo cliente'),
              ),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            ],
          );
        });
      },
    );
    if (elegido != null) setState(() => _cliente = elegido);
  }

  Future<void> _cobrar() async {
    if (_conNif && (_cliente == null || ((_cliente!['documento'] as String?) ?? '').isEmpty)) {
      setState(() => _error = 'Elige un cliente con NIF');
      return;
    }
    setState(() {
      _cobrando = true;
      _error = null;
    });
    try {
      final caja = await CajaService.caja();
      var turno = await CajaService.turnoAbierto(caja['id'] as String);
      if (turno == null) {
        // Caja cerrada: se abre aquí mismo y se sigue cobrando
        if (!mounted || !await abrirCajaRapida(context)) throw 'Para cobrar hay que abrir la caja';
        turno = await CajaService.turnoAbierto(caja['id'] as String);
        if (turno == null) throw 'No se pudo abrir la caja';
      }

      // Si un intento anterior ya emitió la factura, se reutiliza
      final factura = await supabase.from('facturas').select().eq('pedido_id', widget.pedido['id']).maybeSingle() ??
          await FacturacionService().emitir(
            lineas: _lineas,
            pedidoId: widget.pedido['id'] as String,
            cajaId: caja['id'] as String,
            cliente: _conNif ? _cliente : null,
            enviarEnSegundoPlano: true,
          );
      // Pagos, pedido pagado y mesa libre en una sola transacción (migración 0036): si falla,
      // no queda nada a medias; si se reintenta y ya estaba cobrado, no repite los pagos
      await supabase.rpc('cobrar_pedido', params: {
        'p_pedido': widget.pedido['id'],
        'p_turno': turno['id'],
        'p_pagos': [
          for (final p in _pagos)
            {
              'metodo': p.metodo,
              'importe': p.importe,
              if (p.entregado != null) 'pago_con': p.entregado,
              if (p.entregado != null) 'vuelto': p.entregado! - p.importe,
            },
        ],
        if (_conNif) 'p_cliente': _cliente!['id'],
        if (widget.mesaId != null) 'p_mesa': widget.mesaId,
      });
      // Para el ticket: forma de pago y, en venta rápida, que es de barra
      final paraTicket = {
        ...factura,
        'pagos': [
          for (final p in _pagos) {'metodo': p.metodo, 'importe': p.importe, 'entregado': p.entregado},
        ],
        if (widget.mesaId == null) 'origen': 'Barra',
        if (_aPartesIguales) 'entre': _entre, // sale impreso en el ticket
      };
      UltimaVenta.guardar(_total, List<Map<String, dynamic>>.from(paraTicket['pagos'] as List));
      if (mounted) Navigator.pop(context, paraTicket);
    } catch (e) {
      setState(() {
        _cobrando = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _importe.dispose();
    _entregado.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cambio = _cambio;
    final terminado = _restante <= 0.001;
    final textoBoton = _cobrando
        ? 'Cobrando…'
        : terminado || _importeActual >= _restante - 0.001
            ? 'Cobrar y emitir ticket'
            : 'Añadir pago · faltarán ${euros(_restante - _importeActual)}';
    // Pantalla ancha (TPV): teclado de números y cambio al lado. En el móvil, el teclado normal.
    final conTeclado = MediaQuery.sizeOf(context).width >= 860;
    final tipoTeclado = conTeclado ? TextInputType.none : const TextInputType.numberWithOptions(decimal: true);
    const marcada = Color(0xFFE3F1EC); // casilla en la que escribe el teclado

    return AlertDialog(
      title: const Text('Cobrar'),
      content: SizedBox(
        width: conTeclado && !terminado ? 760 : 480,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: C.crema, borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  Text('${_lineas.length} líneas · IVA incl.', style: const TextStyle(color: C.gris)),
                  const Spacer(),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(euros(_total), style: titulo(32)),
                    if (_pagos.isNotEmpty) Text('Falta ${euros(_restante)}', style: titulo(16, color: C.naranja)),
                  ]),
                ]),
              ),
              for (final p in _pagos)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.check_circle, color: C.verde),
                  title: Text('${_nombreMetodo[p.metodo]} · ${euros(p.importe)}'),
                  subtitle: p.entregado != null && p.entregado! > p.importe
                      ? Text('Entregado ${euros(p.entregado!)} · cambio ${euros(p.entregado! - p.importe)}')
                      : null,
                  trailing: IconButton(
                    tooltip: 'Quitar pago',
                    onPressed: _cobrando ? null : () => setState(() {
                      _pagos.remove(p);
                      _ponerImporte(_propuesto);
                    }),
                    icon: const Icon(Icons.close),
                  ),
                ),
              if (!terminado) ...[
                const SizedBox(height: 12),
                Row(children: [
                  for (final (m, icono) in [
                    ('efectivo', Icons.payments_outlined),
                    ('tarjeta', Icons.credit_card),
                    ('bizum', Icons.smartphone),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _BotonMetodo(
                          texto: _nombreMetodo[m]!,
                          icono: icono,
                          activo: _metodo == m,
                          onTap: () => setState(() {
                            _metodo = m;
                            _destino = m == 'efectivo' ? _entregado : _importe;
                            _nuevo = true;
                          }),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _importe,
                      keyboardType: tipoTeclado,
                      onTap: () => _elegir(_importe),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Importe con ${_nombreMetodo[_metodo]!.toLowerCase()}',
                        suffixText: '€',
                        filled: conTeclado && _destino == _importe,
                        fillColor: marcada,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<int>(
                    tooltip: 'Dividir a partes iguales',
                    onSelected: (n) => setState(() {
                      _entre = n == 0 ? null : n; // 0 = sin dividir
                      _ponerImporte(_propuesto);
                    }),
                    itemBuilder: (_) => [
                      for (final n in [2, 3, 4, 5, 6]) PopupMenuItem(value: n, child: Text('Entre $n')),
                      if (_entre != null) const PopupMenuItem(value: 0, child: Text('Sin dividir')),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Row(children: [Icon(Icons.groups_outlined), SizedBox(width: 4), Text('Entre…')]),
                    ),
                  ),
                ]),
                if (_metodo == 'efectivo') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _entregado,
                    keyboardType: tipoTeclado,
                    onTap: () => _elegir(_entregado),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Entregado (opcional)',
                      suffixText: '€',
                      filled: conTeclado && _destino == _entregado,
                      fillColor: marcada,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, children: [
                    for (final b in [5, 10, 20, 50, 100])
                      if (b >= _importeActual)
                        ActionChip(
                          label: Text('$b €'),
                          onPressed: () => setState(() {
                            _entregado.text = '$b';
                            _destino = _entregado;
                            _nuevo = true;
                          }),
                        ),
                  ]),
                  if (!conTeclado && cambio != null && cambio >= 0) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      const Text('Cambio', style: TextStyle(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(euros(cambio), style: titulo(26, color: C.verde)),
                    ]),
                  ],
                ],
              ],
              const Divider(height: 28),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Factura con NIF'),
                subtitle: Text(_conNif
                    ? (_cliente == null ? 'Elige el cliente' : '${_cliente!['nombre']} · ${_cliente!['documento']}')
                    : 'Por defecto: factura simplificada (ticket)'),
                value: _conNif,
                onChanged: (v) async {
                  setState(() => _conNif = v);
                  if (v && _cliente == null) await _elegirCliente();
                },
              ),
              if (_conNif)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _elegirCliente,
                    icon: const Icon(Icons.badge_outlined),
                    label: Text(_cliente == null ? 'Elegir cliente' : 'Cambiar cliente'),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
        ),
        if (conTeclado && !terminado) ...[
          const SizedBox(width: 16),
          SizedBox(
            width: 250,
            child: _TecladoCobro(
              cambio: _metodo == 'efectivo' ? cambio : null,
              alPulsar: _pulsar,
              alBorrar: _borrarTecla,
              alLimpiar: () => _borrarTecla(todo: true),
            ),
          ),
        ],
        ]),
      ),
      actions: [
        const InterruptorTicket(),
        TextButton(onPressed: _cobrando ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _cobrando || _lineas.isEmpty ? null : _boton,
          child: Text(textoBoton),
        ),
      ],
    );
  }
}

class _BotonMetodo extends StatelessWidget {
  const _BotonMetodo({required this.texto, required this.icono, required this.activo, required this.onTap});
  final String texto;
  final IconData icono;
  final bool activo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: activo ? C.verde : C.blanco,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: activo ? C.verde : C.bordeFuerte),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            height: 68,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icono, color: activo ? C.sobreAccion : C.tinta),
              const SizedBox(height: 4),
              Text(texto, style: TextStyle(fontWeight: FontWeight.w700, color: activo ? C.sobreAccion : C.tinta)),
            ]),
          ),
        ),
      );
}

/// Cajita de números de la ventana de cobro, con el cambio bien a la vista antes de cobrar.
class _TecladoCobro extends StatelessWidget {
  const _TecladoCobro({required this.cambio, required this.alPulsar, required this.alBorrar, required this.alLimpiar});
  final double? cambio; // null: aún no se ha marcado lo entregado (o no es efectivo)
  final ValueChanged<String> alPulsar;
  final VoidCallback alBorrar, alLimpiar;

  Widget _tecla(Widget hijo, VoidCallback alTocar, {VoidCallback? alMantener}) => Expanded(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: C.blanco,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: C.bordeFuerte)),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              canRequestFocus: false,
              onTap: alTocar,
              onLongPress: alMantener,
              child: SizedBox(height: 58, child: Center(child: hijo)),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = cambio;
    final falta = c != null && c < -0.004;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        margin: const EdgeInsets.fromLTRB(3, 0, 3, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: c == null ? C.crema : (falta ? const Color(0xFFFBE9E7) : const Color(0xFFE3F1EC)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(falta ? 'Faltan' : 'Cambio', style: const TextStyle(color: C.gris, fontWeight: FontWeight.w600)),
          Text(c == null ? '—' : euros(c.abs()),
              style: titulo(32, color: c == null ? C.gris : (falta ? const Color(0xFFB3261E) : C.verde))),
        ]),
      ),
      for (final fila in const [['7', '8', '9'], ['4', '5', '6'], ['1', '2', '3']])
        Row(children: [for (final d in fila) _tecla(Text(d, style: titulo(24)), () => alPulsar(d))]),
      Row(children: [
        _tecla(Text(',', style: titulo(24)), () => alPulsar(',')),
        _tecla(Text('0', style: titulo(24)), () => alPulsar('0')),
        _tecla(const Icon(Icons.backspace_outlined), alBorrar, alMantener: alLimpiar), // mantener: borra todo
      ]),
    ]);
  }
}
