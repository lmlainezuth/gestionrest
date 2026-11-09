import 'package:flutter/material.dart';

import '../../core/impresion.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../ajustes/clientes_tab.dart' show editarCliente;
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/facturacion_service.dart';
import '../ticketbai/modelos.dart';
import 'caja_service.dart';

typedef _Pago = ({String metodo, double importe, double? entregado});

const _nombreMetodo = {'efectivo': 'Efectivo', 'tarjeta': 'Tarjeta', 'bizum': 'Bizum'};

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

  late final List<LineaFactura> _lineas = [
    for (final d in ((widget.pedido['pedido_detalle'] as List?) ?? []).cast<Map<String, dynamic>>())
      if (d['estado_cocina'] != 'anulado')
        LineaFactura(d['descripcion'] as String, (d['cantidad'] as num).toDouble(), (d['precio_unitario'] as num).toDouble()),
  ];
  late final double _total = Desglose.de(_lineas, 10).total;

  double get _pagado => _pagos.fold(0.0, (s, p) => s + p.importe);
  double get _restante => ((_total - _pagado) * 100).roundToDouble() / 100;
  double get _importeActual => leerImporte(_importe.text) ?? 0;

  @override
  void initState() {
    super.initState();
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
      _ponerImporte(_restante);
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
      final turno = await CajaService.turnoAbierto(caja['id'] as String);
      if (turno == null) throw 'La caja está cerrada: ábrela en la sección Caja';

      // Si un intento anterior ya emitió la factura, se reutiliza
      final factura = await supabase.from('facturas').select().eq('pedido_id', widget.pedido['id']).maybeSingle() ??
          await FacturacionService().emitir(
            lineas: _lineas,
            pedidoId: widget.pedido['id'] as String,
            cajaId: caja['id'] as String,
            cliente: _conNif ? _cliente : null,
          );
      await supabase.from('pagos').insert([
        for (final p in _pagos)
          {
            'pedido_id': widget.pedido['id'],
            'turno_id': turno['id'],
            'metodo': p.metodo,
            'importe': p.importe,
            if (p.entregado != null) 'pago_con': p.entregado,
            if (p.entregado != null) 'vuelto': p.entregado! - p.importe,
          },
      ]);
      await supabase.from('pedidos').update({
        'estado': 'pagado',
        'pagado_en': DateTime.now().toUtc().toIso8601String(),
        'turno_id': turno['id'],
        if (_conNif) 'cliente_id': _cliente!['id'],
      }).eq('id', widget.pedido['id']);
      if (widget.mesaId != null) {
        await supabase.from('mesas').update({'disponibilidad': 'libre'}).eq('id', widget.mesaId!);
      }
      if (_pagos.any((p) => p.metodo == 'efectivo')) Impresion.abrirCajon().catchError((_) {});
      if (mounted) Navigator.pop(context, factura);
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

    return AlertDialog(
      title: const Text('Cobrar'),
      content: SizedBox(
        width: 480,
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
                      _ponerImporte(_restante);
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
                          onTap: () => setState(() => _metodo = m),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _importe,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(labelText: 'Importe con ${_nombreMetodo[_metodo]!.toLowerCase()}', suffixText: '€'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<int>(
                    tooltip: 'Dividir a partes iguales',
                    onSelected: (n) => setState(() => _ponerImporte((_total / n * 100).ceilToDouble() / 100 > _restante
                        ? _restante
                        : (_total / n * 100).ceilToDouble() / 100)),
                    itemBuilder: (_) => [for (final n in [2, 3, 4, 5, 6]) PopupMenuItem(value: n, child: Text('Entre $n'))],
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
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Entregado (opcional)', suffixText: '€'),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, children: [
                    for (final b in [5, 10, 20, 50, 100])
                      if (b >= _importeActual)
                        ActionChip(label: Text('$b €'), onPressed: () => setState(() => _entregado.text = '$b')),
                  ]),
                  if (cambio != null && cambio >= 0) ...[
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
      actions: [
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
