import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/modelos.dart' show euros;
import 'comun.dart';

/// Caja de cada día: lo vendido en efectivo y con tarjeta.
class CajaDiariaPage extends StatefulWidget {
  const CajaDiariaPage({super.key});

  @override
  State<CajaDiariaPage> createState() => _CajaDiariaPageState();
}

class _CajaDiariaPageState extends State<CajaDiariaPage> {
  DateTime _mes = DateTime.now();
  List<Map<String, dynamic>> _cajas = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final (desde, hasta) = rangoMes(_mes);
    _cajas = List<Map<String, dynamic>>.from(await supabase
        .from('cajas_diarias')
        .select()
        .gte('fecha', desde)
        .lte('fecha', hasta)
        .order('fecha', ascending: false));
    if (mounted) setState(() => _cargando = false);
  }

  /// Suma lo cobrado en el TPV ese día por forma de pago.
  Future<(double, double)> _ventasTpv(DateTime dia) async {
    final ini = DateTime(dia.year, dia.month, dia.day).toUtc().toIso8601String();
    final fin = DateTime(dia.year, dia.month, dia.day + 1).toUtc().toIso8601String();
    final pagos = await supabase.from('pagos').select('metodo, importe').gte('creado_en', ini).lt('creado_en', fin);
    var efectivo = 0.0, tarjeta = 0.0;
    for (final p in pagos) {
      final v = (p['importe'] as num).toDouble();
      p['metodo'] == 'efectivo' ? efectivo += v : tarjeta += v; // Bizum y tarjeta van juntos
    }
    return (efectivo, tarjeta);
  }

  Future<void> _editar([Map<String, dynamic>? c]) async {
    var fecha = c == null ? DateTime.now() : DateTime.parse(c['fecha'] as String);
    String f(num? v) => v == null ? '' : v.toStringAsFixed(2).replaceAll('.', ',');
    final efectivo = TextEditingController(text: f(c?['efectivo'] as num?));
    final tarjeta = TextEditingController(text: f(c?['tarjeta'] as num?));
    final notas = TextEditingController(text: c?['notas'] as String?);
    var estado = (c?['estado'] as String?) ?? 'cerrada';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final total = (leerImporte(efectivo.text) ?? 0) + (leerImporte(tarjeta.text) ?? 0);
        return AlertDialog(
          title: Text(c == null ? 'Caja del día' : 'Caja del ${fechaCorta(c['fecha'] as String)}'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              OutlinedButton.icon(
                onPressed: c != null
                    ? null
                    : () async {
                        final d = await showDatePicker(
                            context: ctx, initialDate: fecha, firstDate: DateTime(2023), lastDate: DateTime.now());
                        if (d != null) setD(() => fecha = d);
                      },
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text('${fecha.day}/${fecha.month}/${fecha.year}'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  final (e, t) = await _ventasTpv(fecha);
                  setD(() {
                    efectivo.text = f(e);
                    tarjeta.text = f(t);
                  });
                },
                icon: const Icon(Icons.point_of_sale),
                label: const Text('Traer lo cobrado en el TPV ese día'),
              ),
              TextField(controller: efectivo, onChanged: (_) => setD(() {}), decoration: const InputDecoration(labelText: 'Efectivo', suffixText: '€')),
              const SizedBox(height: 12),
              TextField(controller: tarjeta, onChanged: (_) => setD(() {}), decoration: const InputDecoration(labelText: 'Tarjeta y Bizum', suffixText: '€')),
              const SizedBox(height: 12),
              Row(children: [const Text('Total'), const Spacer(), Text(euros(total), style: titulo(26))]),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'cerrada', label: Text('Cerrada')),
                  ButtonSegment(value: 'pendiente', label: Text('Pendiente de revisar')),
                ],
                selected: {estado},
                onSelectionChanged: (s) => setD(() => estado = s.first),
              ),
              const SizedBox(height: 12),
              TextField(controller: notas, decoration: const InputDecoration(labelText: 'Notas (descuadre, incidencias…)')),
            ]),
          ),
          actions: [
            if (c != null)
              TextButton(
                onPressed: () async {
                  await supabase.from('cajas_diarias').delete().eq('id', c['id']);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const Text('Borrar'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        );
      }),
    );
    if (ok != true) {
      return;
    }
    final e = leerImporte(efectivo.text), t = leerImporte(tarjeta.text);
    if (e != null || t != null) {
      await supabase.from('cajas_diarias').upsert({
        'fecha': iso(fecha),
        'efectivo': e,
        'tarjeta': t,
        'total': (e ?? 0) + (t ?? 0),
        'estado': estado,
        'notas': notas.text.trim().isEmpty ? null : notas.text.trim(),
      }, onConflict: 'empresa_id,fecha');
    }
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final total = _cajas.fold(0.0, (s, c) => s + (c['total'] as num).toDouble());
    final efectivo = _cajas.fold(0.0, (s, c) => s + ((c['efectivo'] as num?) ?? 0).toDouble());
    final tarjeta = _cajas.fold(0.0, (s, c) => s + ((c['tarjeta'] as num?) ?? 0).toDouble());
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SelectorMes(mes: _mes, onCambio: (m) {
            _mes = m;
            _cargar();
          }),
          FilledButton.icon(onPressed: () => _editar(), icon: const Icon(Icons.add), label: const Text('Caja de hoy')),
        ]),
        const SizedBox(height: 20),
        Wrap(spacing: 14, runSpacing: 14, children: [
          Cifra('Ventas del mes', euros(total), detalle: '${_cajas.length} días', destacada: true),
          Cifra('Efectivo', euros(efectivo)),
          Cifra('Tarjeta y Bizum', euros(tarjeta)),
          Cifra('Media por día', euros(_cajas.isEmpty ? 0 : total / _cajas.length)),
        ]),
        const SizedBox(height: 24),
        if (_cargando) const Center(child: CircularProgressIndicator()),
        if (!_cargando && _cajas.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('No hay cajas registradas este mes.', style: TextStyle(color: C.gris))),
        for (final c in _cajas)
          Card(
            elevation: 0,
            color: C.blanco,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: C.borde)),
            child: ListTile(
              onTap: () => _editar(c),
              leading: Icon(c['estado'] == 'cerrada' ? Icons.lock_outline : Icons.pending_outlined,
                  color: c['estado'] == 'cerrada' ? C.verde : C.naranja),
              title: Text(fechaCorta(c['fecha'] as String), style: titulo(18)),
              subtitle: Text('Efectivo ${euros((c['efectivo'] as num?) ?? 0)} · Tarjeta ${euros((c['tarjeta'] as num?) ?? 0)}'
                  '${c['notas'] != null ? '\n${c['notas']}' : ''}'),
              trailing: Text(euros(c['total'] as num), style: titulo(20)),
            ),
          ),
      ],
    );
  }
}
