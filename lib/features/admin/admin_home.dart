import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../camarero/mesas_view.dart';
import '../barra/barra_page.dart';
import '../caja/caja_page.dart';
import '../carta/carta_page.dart';
import '../cocina/cocina_page.dart';
import '../informes/informes_page.dart';
import '../ticketbai/facturas_page.dart';
import '../usuarios/usuarios_page.dart';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.perfil});
  final Perfil perfil;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int _seccion = 0;

  static const _secciones = [
    (icono: Icons.grid_view_rounded, titulo: 'Mesas'),
    (icono: Icons.local_bar_outlined, titulo: 'Barra'),
    (icono: Icons.restaurant_menu, titulo: 'Carta'),
    (icono: Icons.point_of_sale, titulo: 'Caja'),
    (icono: Icons.receipt_long, titulo: 'Facturas'),
    (icono: Icons.bar_chart_rounded, titulo: 'Informes'),
    (icono: Icons.people_alt_outlined, titulo: 'Usuarios'),
    (icono: Icons.soup_kitchen_outlined, titulo: 'Cocina'),
  ];

  @override
  Widget build(BuildContext context) {
    final contenido = switch (_secciones[_seccion].titulo) {
      'Mesas' => const MesasView(),
      'Barra' => const BarraPage(),
      'Carta' => const CartaPage(),
      'Caja' => const CajaPage(),
      'Facturas' => const FacturasPage(),
      'Informes' => const InformesPage(),
      'Usuarios' => const UsuariosPage(),
      'Cocina' => const CocinaPage(),
      _ => _Proximamente(_secciones[_seccion].titulo),
    };

    return Scaffold(
      body: Row(
        children: [
          // Menú lateral oscuro
          Container(
            width: 96,
            color: C.panel,
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: C.naranja, borderRadius: BorderRadius.circular(14)),
                  alignment: Alignment.center,
                  child: Text('GR', style: titulo(18)),
                ),
                const SizedBox(height: 28),
                for (var i = 0; i < _secciones.length; i++)
                  _ItemMenu(
                    icono: _secciones[i].icono,
                    texto: _secciones[i].titulo,
                    activo: i == _seccion,
                    onTap: () => setState(() => _seccion = i),
                  ),
                const Spacer(),
                _ItemMenu(
                  icono: Icons.logout,
                  texto: 'Salir',
                  activo: false,
                  onTap: () => supabase.auth.signOut(),
                ),
              ],
            ),
          ),
          // Contenido
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 76,
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.borde))),
                  child: Row(
                    children: [
                      Text(_secciones[_seccion].titulo, style: titulo(28)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                        decoration: BoxDecoration(
                          color: C.blanco,
                          border: Border.all(color: C.borde),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: C.verde,
                              child: Text(
                                widget.perfil.nombre.isEmpty ? '?' : widget.perfil.nombre[0].toUpperCase(),
                                style: const TextStyle(color: C.sobreAccion, fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(widget.perfil.nombre,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                const Text('Administrador', style: TextStyle(fontSize: 11, color: C.gris)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: contenido),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemMenu extends StatelessWidget {
  const _ItemMenu({required this.icono, required this.texto, required this.activo, required this.onTap});
  final IconData icono;
  final String texto;
  final bool activo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = activo ? C.sobreAccion : C.gris;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: activo ? C.verde : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            width: 78,
            height: 66,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icono, color: color, size: 24),
                const SizedBox(height: 4),
                Text(texto, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Proximamente extends StatelessWidget {
  const _Proximamente(this.seccion);
  final String seccion;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.construction_rounded, size: 48, color: C.gris),
            const SizedBox(height: 12),
            Text('$seccion: en construcción', style: titulo(20, color: C.gris, peso: FontWeight.w500)),
          ],
        ),
      );
}
