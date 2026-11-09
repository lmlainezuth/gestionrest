import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../ticketbai/modelos.dart' show euros;

/// Modificadores activos de un producto (vienen en la consulta de productos).
List<Map<String, dynamic>> modificadoresDe(Map<String, dynamic> producto) => [
      for (final pm in ((producto['producto_modificadores'] as List?) ?? []))
        if ((pm['modificadores'] as Map?)?['activo'] == true) Map<String, dynamic>.from(pm['modificadores'] as Map),
    ];

/// Pregunta los extras si el producto tiene. Devuelve [] si no tiene o no se
/// elige ninguno, y null si se cancela.
Future<List<Map<String, dynamic>>?> elegirModificadores(BuildContext context, Map<String, dynamic> producto) async {
  final mods = modificadoresDe(producto);
  if (mods.isEmpty) return const [];
  final elegidos = <String>{};
  return showDialog<List<Map<String, dynamic>>>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      final extra = mods.where((m) => elegidos.contains(m['id'])).fold(0.0, (s, m) => s + (m['precio'] as num));
      return AlertDialog(
        title: Text('${producto['nombre']}'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Extras y cambios', style: TextStyle(color: C.gris)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in mods)
                FilterChip(
                  label: Text((m['precio'] as num) > 0 ? '${m['nombre']} +${euros(m['precio'] as num)}' : '${m['nombre']}'),
                  selected: elegidos.contains(m['id']),
                  onSelected: (s) => setD(() => s ? elegidos.add(m['id'] as String) : elegidos.remove(m['id'])),
                ),
            ]),
            const SizedBox(height: 16),
            Text('Precio: ${euros((producto['precio_venta'] as num) + extra)}', style: titulo(20)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, mods.where((m) => elegidos.contains(m['id'])).toList()),
            child: const Text('Añadir'),
          ),
        ],
      );
    }),
  );
}

/// "Hamburguesa (Extra queso, Sin cebolla)"
String nombreConModificadores(Map<String, dynamic> producto, List<Map<String, dynamic>> mods) =>
    mods.isEmpty ? producto['nombre'] as String : '${producto['nombre']} (${mods.map((m) => m['nombre']).join(', ')})';

double precioConModificadores(Map<String, dynamic> producto, List<Map<String, dynamic>> mods) =>
    (producto['precio_venta'] as num).toDouble() + mods.fold(0.0, (s, m) => s + (m['precio'] as num).toDouble());

String claveModificadores(List<Map<String, dynamic>> mods) => (mods.map((m) => m['id'] as String).toList()..sort()).join(',');
