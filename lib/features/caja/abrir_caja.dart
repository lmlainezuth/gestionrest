import 'package:flutter/material.dart';

import '../../core/pedir_cantidad.dart';
import '../../core/hora_equipo.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../barra/venta_offline.dart';
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/modelos.dart' show euros;
import 'caja_service.dart';

/// Abre la caja en un paso desde cualquier pantalla (Barra, cobro de mesa...).
/// Propone como fondo el del último turno. Devuelve true si la caja queda abierta.
Future<bool> abrirCajaRapida(BuildContext context) async {
  final caja = await CajaService.caja();
  if (await CajaService.turnoAbierto(caja['id'] as String) != null) return true;
  // Lo que se dejó en el cajón al cerrar el último turno (si no consta, con lo que abrió). Lo da el
  // servidor: el camarero no ve los turnos cerrados (cuadre ciego)
  final ultimo = await supabase.rpc('fondo_sugerido', params: {'p_caja': caja['id']}) as Map?;
  final dejado = (ultimo?['dejado'] as num?)?.toDouble();
  final propuesto = dejado ?? ((ultimo?['inicial'] as num?) ?? 0).toDouble();
  if (!context.mounted) return false;

  // Los tickets llevan la hora del equipo: si el reloj va mal, se avisa antes de empezar a cobrar
  final desfase = await HoraEquipo.desfase(forzar: true);
  if (HoraEquipo.mal(desfase)) {
    if (!context.mounted) return false;
    final seguir = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.schedule, color: Color(0xFFB3261E)),
        title: const Text('La hora de este equipo no es correcta'),
        content: Text(
          'Va ${HoraEquipo.texto(desfase!)} respecto a la hora real, y los tickets salen con la hora del equipo.\n\n'
          'Corrígela antes de cobrar: Ajustes del equipo › Fecha y hora › activa "Fecha y hora automáticas".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Abrir igualmente')),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Voy a corregirla')),
        ],
      ),
    );
    if (seguir != true || !context.mounted) return false;
  }

  final ctrl = TextEditingController(text: propuesto.toStringAsFixed(2).replaceAll('.', ','));
  ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
  final fondo = await showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Abrir caja'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dejado != null
                  ? 'Al cerrar se dejaron ${euros(dejado)} en el cajón. Cuéntalo y, si está bien, pulsa Abrir caja.'
                  : propuesto > 0
                      ? 'Efectivo con el que empiezas. El último turno empezó con ${euros(propuesto)}.'
                      : 'Efectivo con el que empiezas el turno (fondo de caja).',
              style: const TextStyle(color: C.gris),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              readOnly: true,
              onTap: () => teclearEn(ctx, ctrl, titulo: 'Fondo de caja', decimal: true),
              decoration: const InputDecoration(labelText: 'Fondo de caja', suffixText: '€'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, leerImporte(ctrl.text.isEmpty ? '0' : ctrl.text)),
          icon: const Icon(Icons.lock_open),
          label: const Text('Abrir caja'),
        ),
      ],
    ),
  );
  if (fondo == null) return false;
  await supabase.from('turnos_caja').insert({
    'caja_id': caja['id'],
    'usuario_id': supabase.auth.currentUser!.id,
    'efectivo_inicial': fondo,
    // Si no coincide con lo que se dejó, queda anotado (el cajón se tocó entre turnos)
    if (dejado != null && (fondo - dejado).abs() >= 0.005)
      'nota': 'Abrió con ${euros(fondo)}; al cerrar se dejaron ${euros(dejado)}',
  });
  if (dejado != null && (fondo - dejado).abs() >= 0.005 && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Ojo: el fondo (${euros(fondo)}) no coincide con lo que se dejó (${euros(dejado)}). Queda anotado.'),
    ));
  }
  // Para que el cobro sin internet sepa que la caja está abierta
  VentaOffline.guardarContexto().catchError((_) {});
  return true;
}
