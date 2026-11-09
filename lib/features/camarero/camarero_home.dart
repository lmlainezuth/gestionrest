import 'package:flutter/material.dart';

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
  int _vista = 0;

  @override
  Widget build(BuildContext context) {
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
      body: _vista == 0 ? const MesasView() : const BarraPage(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _vista,
        backgroundColor: C.blanco,
        indicatorColor: C.verde,
        onDestinationSelected: (i) => setState(() => _vista = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.grid_view_rounded), selectedIcon: Icon(Icons.grid_view_rounded, color: C.sobreAccion), label: 'Mesas'),
          NavigationDestination(icon: Icon(Icons.local_bar_outlined), selectedIcon: Icon(Icons.local_bar, color: C.sobreAccion), label: 'Barra'),
        ],
      ),
    );
  }
}
