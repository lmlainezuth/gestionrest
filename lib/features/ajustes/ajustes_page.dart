import 'package:flutter/material.dart';

import '../../core/pestanas.dart';
import '../usuarios/usuarios_page.dart';
import 'clientes_tab.dart';
import 'copias_tab.dart';
import 'empresa_tab.dart';
import 'impresoras_tab.dart';
import 'plataforma_tab.dart';
import 'programa_tab.dart';
import 'salones_tab.dart';

/// Configuración del negocio.
class AjustesPage extends StatelessWidget {
  const AjustesPage({super.key});

  @override
  Widget build(BuildContext context) => Pestanas(pestanas: [
        (texto: 'Empresa', icono: Icons.storefront_outlined, permiso: 'ajustes', pagina: () => const EmpresaTab()),
        (texto: 'Usuarios', icono: Icons.people_alt_outlined, permiso: 'usuarios', pagina: () => const UsuariosPage()),
        (texto: 'Salones y mesas', icono: Icons.table_restaurant_outlined, permiso: 'ajustes', pagina: () => const SalonesTab()),
        (texto: 'Clientes', icono: Icons.badge_outlined, permiso: 'ajustes', pagina: () => const ClientesTab()),
        (texto: 'Impresoras', icono: Icons.print_outlined, permiso: 'ajustes', pagina: () => const ImpresorasTab()),
        (texto: 'Copias', icono: Icons.backup_outlined, permiso: 'ajustes', pagina: () => const CopiasTab()),
        // Solo el programador (migración 0030): licencias y datos del desarrollador, para todos los bares
        (texto: 'Programa', icono: Icons.code, permiso: 'programa', pagina: () => const ProgramaTab()),
        // Solo el programador (migración 0046): seguridad de todos los bares
        (texto: 'Plataforma', icono: Icons.admin_panel_settings_outlined, permiso: 'programa', pagina: () => const PlataformaTab()),
      ]);
}
