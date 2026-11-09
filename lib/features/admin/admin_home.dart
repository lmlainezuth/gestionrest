import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/avisos_listo.dart';
import '../../core/empresa_dispositivo.dart';
import '../../core/pestanas.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../camarero/mesas_view.dart';
import '../ajustes/ajustes_page.dart';
import '../barra/barra_page.dart';
import '../caja/caja_page.dart';
import '../carta/carta_page.dart';
import '../cocina/cocina_page.dart';
import '../gestion/caja_diaria_page.dart';
import '../gestion/gastos_page.dart';
import '../gestion/proveedores_page.dart';
import '../gestion/resumen_page.dart';
import '../informes/informes_page.dart';
import '../ticketbai/facturas_page.dart';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.perfil});
  final Perfil perfil;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  // Al abrir, la Barra (venta rápida) si este usuario la tiene
  late int _seccion = _visibles.indexWhere((s) => s.titulo == 'Barra').clamp(0, _visibles.length);

  /// Secciones, en orden de uso. Se ve si el usuario tiene alguno de sus permisos.
  static const _secciones = [
    (icono: Icons.local_bar_outlined, titulo: 'Barra', permisos: ['barra']),
    (icono: Icons.grid_view_rounded, titulo: 'Mesas', permisos: ['mesas']),
    (icono: Icons.soup_kitchen_outlined, titulo: 'Cocina', permisos: ['cocina']),
    (icono: Icons.point_of_sale, titulo: 'Caja', permisos: ['caja', 'caja_diaria']),
    (icono: Icons.receipt_outlined, titulo: 'Gastos', permisos: ['gastos', 'proveedores']),
    (icono: Icons.insights_outlined, titulo: 'Números', permisos: ['resumen', 'informes', 'facturas']),
    (icono: Icons.restaurant_menu, titulo: 'Carta', permisos: ['carta']),
    (icono: Icons.settings_outlined, titulo: 'Ajustes', permisos: ['ajustes', 'usuarios']),
  ];

  late final _visibles = [
    for (final s in _secciones)
      if (s.permisos.any(widget.perfil.puede)) s,
  ];

  Future<void> _empresas() async {
    final empresas = List<Map<String, dynamic>>.from(await supabase.rpc('mis_empresas'));
    if (!mounted) return;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Empresas'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final e in empresas)
              ListTile(
                leading: Icon(e['id'] == widget.perfil.empresaId ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: C.verde),
                title: Text(e['nombre'] as String),
                subtitle: Text(e['rol'] == 'admin' ? 'Administrador' : '${e['rol']}'),
                onTap: () => Navigator.pop(ctx, e['id'] as String),
              ),
          ]),
        ),
        actions: [
          if (widget.perfil.esAdmin)
            TextButton.icon(onPressed: () => Navigator.pop(ctx, '+'), icon: const Icon(Icons.add), label: const Text('Nueva empresa')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
    if (r == null || r == widget.perfil.empresaId) return;
    var id = r;
    if (r == '+') {
      final ctrl = TextEditingController();
      if (!mounted) return;
      final nombre = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Nueva empresa'),
          content: SizedBox(
            width: 360,
            child: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre del negocio')),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Crear')),
          ],
        ),
      );
      if (nombre == null || nombre.isEmpty) return;
      id = await supabase.rpc('crear_empresa', params: {'p_nombre': nombre}) as String;
    }
    await supabase.rpc('usar_empresa', params: {'p_empresa': id});
    await EmpresaDispositivo.guardar(id);
    recargaApp.value++;
  }

  @override
  Widget build(BuildContext context) {
    final contenido = switch (_visibles[_seccion].titulo) {
      'Barra' => const BarraPage(),
      'Mesas' => const MesasView(),
      'Cocina' => const CocinaPage(),
      'Caja' => Pestanas(pestanas: [
          (texto: 'Turno de hoy', icono: Icons.point_of_sale, permiso: 'caja', pagina: () => const CajaPage()),
          (texto: 'Caja por días', icono: Icons.calendar_month_outlined, permiso: 'caja_diaria', pagina: () => const CajaDiariaPage()),
        ]),
      'Gastos' => Pestanas(pestanas: [
          (texto: 'Facturas de gastos', icono: Icons.receipt_outlined, permiso: 'gastos', pagina: () => const GastosPage()),
          (texto: 'Proveedores', icono: Icons.local_shipping_outlined, permiso: 'proveedores', pagina: () => const ProveedoresPage()),
        ]),
      'Números' => Pestanas(pestanas: [
          (texto: 'Resumen', icono: Icons.insights_outlined, permiso: 'resumen', pagina: () => const ResumenPage()),
          (texto: 'Ventas en detalle', icono: Icons.bar_chart_rounded, permiso: 'informes', pagina: () => const InformesPage()),
          (texto: 'Facturas emitidas', icono: Icons.receipt_long, permiso: 'facturas', pagina: () => const FacturasPage()),
        ]),
      'Carta' => const CartaPage(),
      'Ajustes' => const AjustesPage(),
      _ => _Proximamente(_visibles[_seccion].titulo),
    };

    if (_visibles.isEmpty) return const Scaffold(body: Center(child: Text('Sin permisos asignados')));
    return LayoutBuilder(builder: (context, c) {
      // TPV pequeño, tablet en vertical o móvil: el menú pasa a un cajón (botón ☰).
      final estrecho = c.maxWidth < 760;
      final menu = Container(
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
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (var i = 0; i < _visibles.length; i++)
                          _ItemMenu(
                            icono: _visibles[i].icono,
                            texto: _visibles[i].titulo,
                            activo: i == _seccion,
                            onTap: () {
                              setState(() => _seccion = i);
                              if (estrecho) Navigator.of(context).pop();
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _ItemMenu(
                  icono: Icons.logout,
                  texto: 'Salir',
                  activo: false,
                  onTap: () => cerrarSesion(context),
                ),
              ],
            ),
          );
      return Scaffold(
        drawer: estrecho ? Drawer(width: 110, backgroundColor: C.panel, child: SafeArea(child: menu)) : null,
        body: SafeArea(
          child: AvisosListo(
            child: Row(children: [
              if (!estrecho) menu,
              Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 76,
                  padding: EdgeInsets.symmetric(horizontal: estrecho ? 8 : 28),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.borde))),
                  child: Row(
                    children: [
                      if (estrecho)
                        Builder(
                          builder: (ctx) => IconButton(
                            tooltip: 'Menú',
                            icon: const Icon(Icons.menu),
                            onPressed: () => Scaffold.of(ctx).openDrawer(),
                          ),
                        ),
                      Flexible(
                        child: Text(_visibles[_seccion].titulo,
                            style: titulo(estrecho ? 22 : 28), overflow: TextOverflow.ellipsis),
                      ),
                      const Spacer(),
                      if (estrecho)
                        IconButton(
                          tooltip: widget.perfil.empresaNombre ?? 'Empresa',
                          onPressed: _empresas,
                          icon: const Icon(Icons.storefront_outlined),
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: _empresas,
                          icon: const Icon(Icons.storefront_outlined),
                          label: Text(widget.perfil.empresaNombre ?? 'Empresa'),
                        ),
                      if (!estrecho) const SizedBox(width: 12),
                      if (!estrecho) Container(
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
                                Text(widget.perfil.empresaNombre ?? '', style: const TextStyle(fontSize: 11, color: C.gris)),
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
            ]),
          ),
        ),
      );
    });
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
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: activo ? C.verde : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            width: 78,
            height: 58,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icono, color: color, size: 24),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(texto, maxLines: 1, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
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
