import 'package:flutter/material.dart';

import '../../main.dart';

/// Mesas agrupadas por salón, con color según disponibilidad.
class MesasView extends StatefulWidget {
  const MesasView({super.key});

  @override
  State<MesasView> createState() => _MesasViewState();
}

class _MesasViewState extends State<MesasView> {
  late Future<List<Map<String, dynamic>>> _salones = _cargar();

  Future<List<Map<String, dynamic>>> _cargar() async {
    final filas = await supabase
        .from('salones')
        .select('id, nombre, mesas(id, nombre, disponibilidad, activo)')
        .eq('activo', true)
        .order('orden');
    return List<Map<String, dynamic>>.from(filas);
  }

  Future<void> _recargar() async {
    setState(() {
      _salones = _cargar();
    });
    await _salones;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _salones,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error al cargar mesas:\n${snap.error}'));
        }
        final salones = snap.data!;
        if (salones.isEmpty) {
          return const Center(child: Text('No hay salones creados todavía.'));
        }
        return RefreshIndicator(
          onRefresh: _recargar,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final s in salones) ...[
                Text(s['nombre'] as String,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final m in (s['mesas'] as List)
                        .cast<Map<String, dynamic>>()
                        .where((m) => m['activo'] == true))
                      _MesaTile(mesa: m),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _MesaTile extends StatelessWidget {
  const _MesaTile({required this.mesa});
  final Map<String, dynamic> mesa;

  @override
  Widget build(BuildContext context) {
    final disp = mesa['disponibilidad'] as String;
    final color = switch (disp) {
      'ocupada' => Colors.red.shade400,
      'reservada' => Colors.orange.shade400,
      _ => Colors.green.shade400,
    };
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        // Siguiente paso: abrir la comanda de esta mesa.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Mesa ${mesa['nombre']} ($disp)')),
        );
      },
      child: Container(
        width: 110,
        height: 90,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.table_restaurant, color: color),
            const SizedBox(height: 4),
            Text(mesa['nombre'] as String,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(disp, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
