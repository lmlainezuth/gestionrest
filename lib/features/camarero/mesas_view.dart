import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';

/// Plano de mesas por salón (zona), con el estilo de la propuesta de diseño.
class MesasView extends StatefulWidget {
  const MesasView({super.key});

  @override
  State<MesasView> createState() => _MesasViewState();
}

class _MesasViewState extends State<MesasView> {
  late Future<List<Map<String, dynamic>>> _salones = _cargar();
  String? _salonId;

  Future<List<Map<String, dynamic>>> _cargar() async {
    final filas = await supabase
        .from('salones')
        .select('id, nombre, mesas(id, nombre, capacidad, disponibilidad, activo)')
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
          return const Center(child: Text('No hay zonas creadas todavía.'));
        }
        final salon = salones.firstWhere((s) => s['id'] == _salonId, orElse: () => salones.first);
        final mesas = (salon['mesas'] as List)
            .cast<Map<String, dynamic>>()
            .where((m) => m['activo'] == true)
            .toList()
          ..sort((a, b) => _orden(a['nombre'] as String).compareTo(_orden(b['nombre'] as String)));

        return RefreshIndicator(
          onRefresh: _recargar,
          child: ListView(
            padding: const EdgeInsets.all(28),
            children: [
              // Zonas
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final s in salones)
                    _ChipZona(
                      nombre: s['nombre'] as String,
                      detalle: _ocupacion(s),
                      activa: s['id'] == salon['id'],
                      onTap: () => setState(() => _salonId = s['id'] as String),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              // Leyenda
              const Wrap(
                spacing: 20,
                runSpacing: 8,
                children: [
                  _Leyenda('Libre', C.blanco, borde: C.bordeFuerte),
                  _Leyenda('Ocupada', C.ocupada),
                  _Leyenda('Pide la cuenta', C.tinta),
                  _Leyenda('Reservada', C.blanco, borde: C.reserva),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [for (final m in mesas) _MesaTile(mesa: m)],
              ),
            ],
          ),
        );
      },
    );
  }

  static String _ocupacion(Map<String, dynamic> s) {
    final mesas = (s['mesas'] as List).where((m) => m['activo'] == true).toList();
    final ocupadas = mesas.where((m) => m['disponibilidad'] != 'libre').length;
    return '$ocupadas/${mesas.length}';
  }

  /// "M10" después de "M9"
  static String _orden(String nombre) {
    final n = RegExp(r'\d+').firstMatch(nombre)?.group(0);
    return n == null ? nombre : nombre.replaceFirst(n, n.padLeft(4, '0'));
  }
}

class _ChipZona extends StatelessWidget {
  const _ChipZona({required this.nombre, required this.detalle, required this.activa, required this.onTap});
  final String nombre;
  final String detalle;
  final bool activa;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = activa ? C.blanco : C.tinta;
    return Material(
      color: activa ? C.tinta : C.blanco,
      shape: StadiumBorder(side: BorderSide(color: activa ? C.tinta : C.bordeFuerte)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(nombre, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(width: 8),
              Text(detalle, style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Leyenda extends StatelessWidget {
  const _Leyenda(this.texto, this.color, {this.borde});
  final String texto;
  final Color color;
  final Color? borde;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
              border: borde == null ? null : Border.all(color: borde!, width: 1.5),
            ),
          ),
          const SizedBox(width: 8),
          Text(texto, style: const TextStyle(color: C.gris, fontSize: 13)),
        ],
      );
}

class _MesaTile extends StatelessWidget {
  const _MesaTile({required this.mesa});
  final Map<String, dynamic> mesa;

  @override
  Widget build(BuildContext context) {
    final disp = mesa['disponibilidad'] as String;
    final (fondo, texto, borde, etiqueta) = switch (disp) {
      'ocupada' => (C.ocupada, C.tinta, C.ocupada, 'Ocupada'),
      'precuenta' => (C.tinta, C.blanco, C.tinta, 'Pide la cuenta'),
      'reservada' => (C.blanco, C.tinta, C.reserva, 'Reservada'),
      _ => (C.blanco, C.tinta, C.bordeFuerte, 'Libre'),
    };
    final capacidad = mesa['capacidad'];

    return Material(
      color: fondo,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borde, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          // Siguiente paso: abrir la comanda de esta mesa.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Mesa ${mesa['nombre']} · $etiqueta')),
          );
        },
        child: SizedBox(
          width: 150,
          height: 118,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mesa['nombre'] as String, style: titulo(30, color: texto)),
                const Spacer(),
                Row(
                  children: [
                    Icon(Icons.person_outline, size: 16, color: texto.withValues(alpha: 0.7)),
                    const SizedBox(width: 4),
                    Text(capacidad == null ? '—' : '$capacidad pax',
                        style: TextStyle(fontSize: 13, color: texto.withValues(alpha: 0.8))),
                    const Spacer(),
                    Text(etiqueta,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: texto)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
