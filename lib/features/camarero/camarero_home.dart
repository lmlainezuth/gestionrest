import 'package:flutter/material.dart';

import '../../core/avisos_listo.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../barra/barra_page.dart';
import 'mesas_view.dart';

/// Pantalla del camarero: mesas (sala) y barra (venta rápida).
class CamareroHome extends StatefulWidget {
  const CamareroHome({super.key, required this.perfil});
  final Perfil perfil;

  @override
  State<CamareroHome> createState() => _CamareroHomeState();
}

class _CamareroHomeState extends State<CamareroHome> {
  late int _vista = _vistas.indexWhere((v) => v.texto == 'Barra').clamp(0, _vistas.length);

  late final _vistas = [
    if (widget.perfil.puede('mesas'))
      (pagina: const MesasView() as Widget, icono: Icons.grid_view_rounded, texto: 'Mesas'),
    if (widget.perfil.puede('barra'))
      (pagina: const BarraPage() as Widget, icono: Icons.local_bar_outlined, texto: 'Barra'),
  ];

  @override
  Widget build(BuildContext context) {
    if (_vistas.isEmpty) return const Scaffold(body: Center(child: Text('Sin permisos asignados')));
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text('GestiónRest', style: titulo(20)),
            const SizedBox(width: 12),
            Text(widget.perfil.nombre, style: titulo(16, color: C.gris, peso: FontWeight.w500)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      body: AvisosListo(child: _vistas[_vista.clamp(0, _vistas.length - 1)].pagina),
      bottomNavigationBar: _vistas.length < 2
          ? null
          : NavigationBar(
              selectedIndex: _vista,
              backgroundColor: C.blanco,
              indicatorColor: C.verde,
              onDestinationSelected: (i) => setState(() => _vista = i),
              destinations: [
                for (final v in _vistas)
                  NavigationDestination(icon: Icon(v.icono), selectedIcon: Icon(v.icono, color: C.sobreAccion), label: v.texto),
              ],
            ),
    );
  }
}
