import 'package:flutter/material.dart';

import '../../main.dart';
import '../auth/perfil.dart';
import '../camarero/mesas_view.dart';
import '../ticketbai/facturas_page.dart';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.perfil});
  final Perfil perfil;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int _seccion = 0;

  static const _secciones = [
    (icono: Icons.table_restaurant, titulo: 'Mesas'),
    (icono: Icons.restaurant_menu, titulo: 'Carta'),
    (icono: Icons.point_of_sale, titulo: 'Caja'),
    (icono: Icons.receipt_long, titulo: 'Facturas'),
    (icono: Icons.bar_chart, titulo: 'Informes'),
    (icono: Icons.people, titulo: 'Usuarios'),
  ];

  @override
  Widget build(BuildContext context) {
    final contenido = switch (_seccion) {
      0 => const MesasView(),
      3 => const FacturasPage(),
      _ => Center(child: Text('${_secciones[_seccion].titulo}: próximamente')),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text('Administración · ${widget.perfil.nombre}'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _seccion,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() => _seccion = i),
            destinations: [
              for (final s in _secciones)
                NavigationRailDestination(
                  icon: Icon(s.icono),
                  label: Text(s.titulo),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: contenido),
        ],
      ),
    );
  }
}
