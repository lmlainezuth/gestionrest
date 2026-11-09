import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/facturacion_service.dart';
import '../ticketbai/modelos.dart';
import 'caja_service.dart';

/// Cobra un pedido: registra el pago, emite la factura TicketBAI,
/// cierra el pedido y libera la mesa. Devuelve la factura emitida.
class CobroDialog extends StatefulWidget {
  const CobroDialog({super.key, required this.pedido, required this.mesaId});
  final Map<String, dynamic> pedido; // con pedido_detalle
  final String? mesaId;

  @override
  State<CobroDialog> createState() => _CobroDialogState();
}

class _CobroDialogState extends State<CobroDialog> {
  String _metodo = 'efectivo';
  final _entregado = TextEditingController();
  bool _cobrando = false;
  String? _error;

  late final List<LineaFactura> _lineas = [
    for (final d in ((widget.pedido['pedido_detalle'] as List?) ?? []).cast<Map<String, dynamic>>())
      if (d['estado_cocina'] != 'anulado')
        LineaFactura(
          d['descripcion'] as String,
          (d['cantidad'] as num).toDouble(),
          (d['precio_unitario'] as num).toDouble(),
        ),
  ];
  late final double _total = Desglose.de(_lineas, 10).total;

  double? get _cambio {
    final e = leerImporte(_entregado.text);
    return e == null ? null : e - _total;
  }

  Future<void> _cobrar() async {
    if (_metodo == 'efectivo' && _entregado.text.isNotEmpty && (_cambio ?? -1) < 0) {
      setState(() => _error = 'El importe entregado no cubre el total');
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
      final factura = await supabase
              .from('facturas')
              .select()
              .eq('pedido_id', widget.pedido['id'])
              .maybeSingle() ??
          await FacturacionService().emitir(
            lineas: _lineas,
            pedidoId: widget.pedido['id'] as String,
            cajaId: caja['id'] as String,
          );
      final entregado = leerImporte(_entregado.text);
      await supabase.from('pagos').insert({
        'pedido_id': widget.pedido['id'],
        'turno_id': turno['id'],
        'metodo': _metodo,
        'importe': _total,
        if (_metodo == 'efectivo' && entregado != null) 'pago_con': entregado,
        if (_metodo == 'efectivo' && entregado != null) 'vuelto': entregado - _total,
      });
      await supabase.from('pedidos').update({
        'estado': 'pagado',
        'pagado_en': DateTime.now().toUtc().toIso8601String(),
        'turno_id': turno['id'],
      }).eq('id', widget.pedido['id']);
      if (widget.mesaId != null) {
        await supabase.from('mesas').update({'disponibilidad': 'libre'}).eq('id', widget.mesaId!);
      }
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
    _entregado.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cambio = _cambio;
    return AlertDialog(
      title: const Text('Cobrar'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: C.crema, borderRadius: BorderRadius.circular(14)),
              child: Row(
                children: [
                  Text('${_lineas.length} líneas · IVA 10 % incl.', style: const TextStyle(color: C.gris)),
                  const Spacer(),
                  Text(euros(_total), style: titulo(34)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final (m, texto, icono) in [
                  ('efectivo', 'Efectivo', Icons.payments_outlined),
                  ('tarjeta', 'Tarjeta', Icons.credit_card),
                  ('bizum', 'Bizum', Icons.smartphone),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _BotonMetodo(
                        texto: texto,
                        icono: icono,
                        activo: _metodo == m,
                        onTap: () => setState(() => _metodo = m),
                      ),
                    ),
                  ),
              ],
            ),
            if (_metodo == 'efectivo') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _entregado,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Entregado', suffixText: '€'),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final b in [5, 10, 20, 50, 100])
                    if (b >= _total)
                      ActionChip(
                        label: Text('$b €'),
                        onPressed: () => setState(() => _entregado.text = '$b'),
                      ),
                  ActionChip(
                    label: const Text('Justo'),
                    onPressed: () => setState(() => _entregado.text = _total.toStringAsFixed(2).replaceAll('.', ',')),
                  ),
                ],
              ),
              if (cambio != null && cambio >= 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Cambio', style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text(euros(cambio), style: titulo(26, color: C.verde)),
                  ],
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _cobrando ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _cobrando || _lineas.isEmpty ? null : _cobrar,
          child: Text(_cobrando ? 'Cobrando…' : 'Cobrar y emitir ticket'),
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
            height: 72,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icono, color: activo ? C.sobreAccion : C.tinta),
                const SizedBox(height: 4),
                Text(texto,
                    style: TextStyle(fontWeight: FontWeight.w700, color: activo ? C.sobreAccion : C.tinta)),
              ],
            ),
          ),
        ),
      );
}
