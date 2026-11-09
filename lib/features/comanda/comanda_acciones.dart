import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../caja/cobro_dialog.dart';
import '../ticketbai/modelos.dart' show euros;
import '../ticketbai/ticket_view.dart';

String _ahora() => DateTime.now().toUtc().toIso8601String();

void _avisar(BuildContext context, String t) {
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
}

/// Anula un plato ya enviado. Si cocina ya lo tenía, se le avisa en su pantalla.
Future<bool> anularLinea(BuildContext context, Map<String, dynamic> linea) async {
  final enCocina = linea['estado_cocina'] == 'preparando' || linea['estado_cocina'] == 'listo';
  final ctrl = TextEditingController();
  const motivos = ['Error al pedir', 'El cliente lo cancela', 'Se ha acabado', 'Invitación'];
  final motivo = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Anular ${linea['descripcion']}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (enCocina)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: const Color(0xFFFBE4DA), borderRadius: BorderRadius.circular(10)),
                child: const Text('Cocina ya lo está preparando: recibirá el aviso de anulación.',
                    style: TextStyle(color: Color(0xFF8A2E0C))),
              ),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final m in motivos) ActionChip(label: Text(m), onPressed: () => ctrl.text = m),
            ]),
            const SizedBox(height: 12),
            TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Motivo')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('No anular')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB3261E)),
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? 'Sin motivo' : ctrl.text.trim()),
          child: const Text('Anular'),
        ),
      ],
    ),
  );
  if (motivo == null) return false;
  try {
    await supabase.from('pedido_detalle').update({
      'estado_cocina': 'anulado',
      'anulado_en': _ahora(),
      'anulado_motivo': motivo,
      'en_espera': false,
    }).eq('id', linea['id']);
    return true;
  } catch (e) {
    if (context.mounted) _avisar(context, 'No se pudo anular: $e');
    return false;
  }
}

/// Mesas activas con su pedido abierto (si lo tienen).
Future<List<({Map<String, dynamic> mesa, Map<String, dynamic>? pedido})>> _mesasConEstado() async {
  final mesas = await supabase.from('mesas').select('id, nombre, salones(nombre)').eq('activo', true);
  final abiertos = await supabase
      .from('pedidos')
      .select('id, mesa_id, total')
      .eq('tipo', 'mesa')
      .inFilter('estado', ['abierto', 'precuenta']);
  final porMesa = {for (final p in abiertos) p['mesa_id']: p};
  final lista = [for (final m in mesas) (mesa: m, pedido: porMesa[m['id']])];
  lista.sort((a, b) => '${a.mesa['nombre']}'.compareTo('${b.mesa['nombre']}'));
  return lista;
}

Future<Map<String, dynamic>?> _elegirMesa(BuildContext context, String encabezado,
    List<({Map<String, dynamic> mesa, Map<String, dynamic>? pedido})> opciones) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(encabezado),
      content: SizedBox(
        width: 460,
        child: opciones.isEmpty
            ? const Text('No hay mesas disponibles.')
            : Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final o in opciones)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(96, 64)),
                      onPressed: () => Navigator.pop(ctx, o.mesa),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('${o.mesa['nombre']}', style: titulo(20)),
                        Text(o.pedido == null ? '${(o.mesa['salones'] as Map?)?['nombre'] ?? ''}' : euros(o.pedido!['total'] as num),
                            style: const TextStyle(fontSize: 12, color: C.gris)),
                      ]),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar'))],
    ),
  );
}

/// Pasa la cuenta a otra mesa libre.
Future<bool> cambiarMesa(BuildContext context, Map<String, dynamic> pedido, Map<String, dynamic> mesaActual) async {
  final libres = (await _mesasConEstado()).where((o) => o.pedido == null && o.mesa['id'] != mesaActual['id']).toList();
  if (!context.mounted) return false;
  final destino = await _elegirMesa(context, 'Cambiar a la mesa…', libres);
  if (destino == null) return false;
  await supabase.from('pedidos').update({'mesa_id': destino['id']}).eq('id', pedido['id']);
  await supabase.from('mesas').update({'disponibilidad': 'libre'}).eq('id', mesaActual['id']);
  await supabase.from('mesas').update({'disponibilidad': 'ocupada'}).eq('id', destino['id']);
  if (context.mounted) _avisar(context, 'Cuenta pasada a la mesa ${destino['nombre']}');
  return true;
}

/// Une la cuenta de otra mesa a esta (la otra queda libre).
Future<bool> unirMesa(BuildContext context, Map<String, dynamic> pedido, Map<String, dynamic> mesaActual) async {
  final ocupadas = (await _mesasConEstado()).where((o) => o.pedido != null && o.mesa['id'] != mesaActual['id']).toList();
  if (!context.mounted) return false;
  final otra = await _elegirMesa(context, 'Unir a esta cuenta la mesa…', ocupadas);
  if (otra == null) return false;
  final otroPedido = ocupadas.firstWhere((o) => o.mesa['id'] == otra['id']).pedido!;
  await supabase.from('pedido_detalle').update({'pedido_id': pedido['id']}).eq('pedido_id', otroPedido['id']);
  await supabase.from('pedidos').update({'estado': 'unido'}).eq('id', otroPedido['id']);
  await supabase.from('mesas').update({'disponibilidad': 'libre'}).eq('id', otra['id']);
  if (context.mounted) _avisar(context, 'Mesa ${otra['nombre']} unida a esta cuenta');
  return true;
}

/// Cobra solo una parte de la cuenta (por productos y cantidades).
/// Devuelve true si se cobró algo.
Future<bool> dividirCuenta(BuildContext context, Map<String, dynamic> pedido) async {
  final lineas = ((pedido['pedido_detalle'] as List?) ?? [])
      .cast<Map<String, dynamic>>()
      .where((d) => d['estado_cocina'] != 'anulado')
      .toList();
  final elegidas = <String, double>{for (final l in lineas) l['id'] as String: 0};

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      final total = lineas.fold(0.0,
          (s, l) => s + elegidas[l['id']]! * (l['precio_unitario'] as num).toDouble());
      return AlertDialog(
        title: const Text('Dividir cuenta'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Elige lo que paga esta persona.', style: TextStyle(color: C.gris)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final l in lineas)
                  Row(children: [
                    Expanded(child: Text('${l['descripcion']}  (${(l['cantidad'] as num).toStringAsFixed(0)})')),
                    IconButton(
                      tooltip: 'Menos',
                      onPressed: elegidas[l['id']]! > 0 ? () => setD(() => elegidas[l['id'] as String] = elegidas[l['id']]! - 1) : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(elegidas[l['id']]!.toStringAsFixed(0), style: titulo(18)),
                    IconButton(
                      tooltip: 'Más',
                      onPressed: elegidas[l['id']]! < (l['cantidad'] as num)
                          ? () => setD(() => elegidas[l['id'] as String] = elegidas[l['id']]! + 1)
                          : null,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ]),
              ]),
            ),
            const Divider(),
            Row(children: [const Text('Paga ahora'), const Spacer(), Text(euros(total), style: titulo(26))]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: total > 0 ? () => Navigator.pop(ctx, true) : null, child: const Text('Cobrar esta parte')),
        ],
      );
    }),
  );
  if (ok != true) return false;

  // Se crea un pedido aparte con lo elegido
  final nuevo = await supabase
      .from('pedidos')
      .insert({
        'tipo': pedido['tipo'] ?? 'mesa',
        'mesa_id': pedido['mesa_id'],
        'nombre_llevar': pedido['nombre_llevar'],
        'camarero_id': supabase.auth.currentUser?.id,
        'num_personas': 1,
      })
      .select('id')
      .single();
  final movidas = <String>[]; // líneas pasadas enteras
  final partidas = <({String id, double k})>[]; // líneas partidas
  for (final l in lineas) {
    final k = elegidas[l['id']]!;
    if (k <= 0) continue;
    if (k == (l['cantidad'] as num).toDouble()) {
      movidas.add(l['id'] as String);
    } else {
      partidas.add((id: l['id'] as String, k: k));
      await supabase.from('pedido_detalle').update({'cantidad': (l['cantidad'] as num) - k}).eq('id', l['id']);
      await supabase.from('pedido_detalle').insert({
        'pedido_id': nuevo['id'],
        'producto_id': l['producto_id'],
        'area_id': l['area_id'],
        'descripcion': l['descripcion'],
        'cantidad': k,
        'precio_unitario': l['precio_unitario'],
        if (l['tipo_iva'] != null) 'tipo_iva': l['tipo_iva'],
        'nota': l['nota'],
        'curso': l['curso'] ?? '1',
        'estado_cocina': l['estado_cocina'],
      });
    }
  }
  if (movidas.isNotEmpty) {
    await supabase.from('pedido_detalle').update({'pedido_id': nuevo['id']}).inFilter('id', movidas);
  }

  final parte = await supabase
      .from('pedidos')
      .select('id, total, pedido_detalle(id, descripcion, cantidad, precio_unitario, tipo_iva, estado_cocina)')
      .eq('id', nuevo['id'])
      .single();
  if (!context.mounted) return false;
  final factura = await showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => CobroDialog(pedido: parte, mesaId: null),
  );

  if (factura == null) {
    // Cancelado: todo vuelve a la cuenta original
    if (movidas.isNotEmpty) {
      await supabase.from('pedido_detalle').update({'pedido_id': pedido['id']}).inFilter('id', movidas);
    }
    for (final p in partidas) {
      final l = lineas.firstWhere((x) => x['id'] == p.id);
      await supabase.from('pedido_detalle').update({'cantidad': l['cantidad']}).eq('id', p.id);
    }
    // El pedido temporal vuelve a la cuenta original ("unido"): no cuenta como anulación
    await supabase.from('pedidos').update({'estado': 'unido'}).eq('id', nuevo['id']);
    await supabase.from('pedido_detalle').delete().eq('pedido_id', nuevo['id']);
    return false;
  }
  if (context.mounted) {
    await mostrarTicket(context, factura);
  }
  // Si ya no queda nada por cobrar, la cuenta original se cierra
  final quedan = await supabase
      .from('pedido_detalle')
      .select('id')
      .eq('pedido_id', pedido['id'])
      .neq('estado_cocina', 'anulado');
  if (quedan.isEmpty) {
    await supabase.from('pedidos').update({'estado': 'unido'}).eq('id', pedido['id']);
    if (pedido['mesa_id'] != null) {
      await supabase.from('mesas').update({'disponibilidad': 'libre'}).eq('id', pedido['mesa_id']);
    }
  }
  return true;
}
