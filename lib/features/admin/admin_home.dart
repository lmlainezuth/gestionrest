import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/avisos_listo.dart';
import '../../core/empresa_dispositivo.dart';
import '../../core/impresion.dart';
import '../../core/pestanas.dart';
import '../../core/software.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../camarero/mesas_view.dart';
import '../ajustes/ajustes_page.dart';
import '../barra/barra_page.dart';
import '../caja/caja_page.dart';
import '../carta/carta_page.dart';
import '../control/anulaciones_page.dart';
import '../control/iva_page.dart';
import '../control/margenes_page.dart';
import '../control/panel_hoy_page.dart';
import '../control/seguridad_page.dart';
import '../cocina/cocina_page.dart';
import '../caja/cierres_page.dart';
import '../gestion/gastos_page.dart';
import '../gestion/proveedores_page.dart';
import '../gestion/resumen_page.dart';
import '../fichajes/cuadrante_page.dart';
import '../fichajes/fichajes_page.dart';
import '../informes/informes_page.dart';
import '../stock/movimientos_stock_page.dart';
import '../stock/pedidos_proveedor_page.dart';
import '../stock/stock_page.dart';
import '../reservas/reservas_page.dart';
import '../ticketbai/facturas_page.dart';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.perfil});
  final Perfil perfil;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  // Al abrir, la Barra (venta rápida) si este usuario la tiene
  // En el TPV abre en la Barra; en el móvil (web) el dueño abre en "Hoy"
  late String _titulo = kIsWeb && widget.perfil.puede('panel') ? 'Hoy' : 'Barra';

  /// Sección abierta. Si deja de verse (por ejemplo Cocina al apagarla), la primera.
  int get _seccion {
    final i = _visibles.indexWhere((s) => s.titulo == _titulo);
    return i < 0 ? 0 : i;
  }

  /// Secciones, en orden de uso. Se ve si el usuario tiene alguno de sus permisos.
  static const _secciones = [
    (icono: Icons.speed, titulo: 'Hoy', permisos: ['panel']),
    (icono: Icons.local_bar_outlined, titulo: 'Barra', permisos: ['barra']),
    (icono: Icons.grid_view_rounded, titulo: 'Mesas', permisos: ['mesas']),
    (icono: Icons.soup_kitchen_outlined, titulo: 'Cocina', permisos: ['cocina']),
    (icono: Icons.point_of_sale, titulo: 'Caja', permisos: ['caja', 'cierres']),
    (icono: Icons.shopping_basket_outlined, titulo: 'Compras', permisos: ['gastos', 'proveedores', 'stock']),
    (icono: Icons.badge_outlined, titulo: 'Equipo', permisos: ['fichajes']),
    (icono: Icons.insights_outlined, titulo: 'Números', permisos: ['resumen', 'informes', 'facturas', 'anulaciones']),
    (icono: Icons.restaurant_menu, titulo: 'Carta', permisos: ['carta']),
    (icono: Icons.settings_outlined, titulo: 'Ajustes', permisos: ['ajustes', 'usuarios']),
  ];

  // Con el perfil de ahora: tras guardar Ajustes › Empresa la app recarga el perfil sin rehacer esta pantalla
  List<({IconData icono, List<String> permisos, String titulo})> get _visibles => [
        for (final s in _secciones)
          if (s.permisos.any(widget.perfil.puede)) s,
      ];

  /// Botones de la cabecera: misma altura y forma que la pastilla del usuario.
  static final _estiloCabecera = OutlinedButton.styleFrom(
    minimumSize: const Size(160, 48),
    maximumSize: const Size(220, 48),
    backgroundColor: C.blanco,
    foregroundColor: C.tinta,
    side: const BorderSide(color: C.borde),
    shape: const StadiumBorder(),
    textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
  );

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
          if (widget.perfil.esAdmin && Software.esProgramador) // dar de alta bares: solo el programador
            TextButton.icon(onPressed: () => Navigator.pop(ctx, '+'), icon: const Icon(Icons.add), label: const Text('Nueva empresa')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
    if (r == null || r == widget.perfil.empresaId) return;
    var id = r;
    if (r == '+') {
      if (!mounted) return;
      final datos = await _pedirNuevaEmpresa();
      if (datos == null) return;
      id = await supabase.rpc('crear_empresa',
          params: {'p_nombre': datos.nombre, 'p_nif': datos.nif, 'p_razon': datos.titular}) as String;
    }
    await supabase.rpc('usar_empresa', params: {'p_empresa': id});
    await EmpresaDispositivo.guardar(id);
    recargaApp.value++;
  }

  /// Nombre del bar y titular (quien factura): así la empresa nace con su NIF y su serie.
  Future<({String nombre, String titular, String nif})?> _pedirNuevaEmpresa() {
    final form = GlobalKey<FormState>();
    final nombre = TextEditingController(), titular = TextEditingController(), nif = TextEditingController();
    return showDialog<({String nombre, String titular, String nif})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva empresa'),
        content: SizedBox(
          width: 400,
          child: Form(
            key: form,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: nombre,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nombre del bar', helperText: 'El que sale arriba en el ticket'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Obligatorio' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: titular,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    labelText: 'Titular (quien factura)', helperText: 'Nombre y apellidos del autónomo, o la razón social'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Obligatorio' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: nif,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'NIF del titular'),
                validator: (v) => (v ?? '').trim().length == 9 ? null : 'El NIF tiene 9 caracteres',
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              if (!form.currentState!.validate()) return;
              Navigator.pop(ctx, (
                nombre: nombre.text.trim(),
                titular: titular.text.trim().toUpperCase(),
                nif: nif.text.trim().toUpperCase(),
              ));
            },
            child: const Text('Crear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contenido = switch (_visibles[_seccion].titulo) {
      'Hoy' => const PanelHoyPage(),
      'Barra' => const BarraPage(),
      'Mesas' => Pestanas(pestanas: [
          (texto: 'Plano', icono: Icons.grid_view_rounded, permiso: 'mesas', pagina: () => const MesasView()),
          (texto: 'Reservas', icono: Icons.event_outlined, permiso: 'mesas', pagina: () => const ReservasPage()),
        ]),
      'Cocina' => const CocinaPage(),
      'Caja' => Pestanas(pestanas: [
          (texto: 'Turno de hoy', icono: Icons.point_of_sale, permiso: 'caja', pagina: () => const CajaPage()),
          (texto: 'Cierres y descuadres', icono: Icons.rule, permiso: 'cierres', pagina: () => const CierresPage()),
        ]),
      // Todo lo que entra al bar: facturas de proveedores y mercancía
      'Compras' => Pestanas(pestanas: [
          (texto: 'Facturas de gastos', icono: Icons.receipt_outlined, permiso: 'gastos', pagina: () => const GastosPage()),
          (texto: 'Proveedores', icono: Icons.local_shipping_outlined, permiso: 'proveedores', pagina: () => const ProveedoresPage()),
          (texto: 'Stock', icono: Icons.inventory_2_outlined, permiso: 'stock', pagina: () => const StockPage()),
          (texto: 'Pedidos', icono: Icons.local_shipping_outlined, permiso: 'stock', pagina: () => const PedidosProveedorPage()),
          (texto: 'Movimientos de stock', icono: Icons.swap_vert, permiso: 'stock', pagina: () => const MovimientosStockPage()),
        ]),
      'Equipo' => Pestanas(pestanas: [
          (texto: 'Fichajes', icono: Icons.badge_outlined, permiso: 'fichajes', pagina: () => const FichajesPage()),
          (texto: 'Cuadrante', icono: Icons.calendar_view_week, permiso: 'fichajes', pagina: () => const CuadrantePage()),
        ]),
      'Números' => Pestanas(pestanas: [
          (texto: 'Resumen', icono: Icons.insights_outlined, permiso: 'resumen', pagina: () => const ResumenPage()),
          (texto: 'Ventas en detalle', icono: Icons.bar_chart_rounded, permiso: 'informes', pagina: () => const InformesPage()),
          (texto: 'Facturas emitidas', icono: Icons.receipt_long, permiso: 'facturas', pagina: () => const FacturasPage()),
          (texto: 'Anulaciones', icono: Icons.remove_circle_outline, permiso: 'anulaciones', pagina: () => const AnulacionesPage()),
          (texto: 'Seguridad', icono: Icons.shield_outlined, permiso: 'anulaciones', pagina: () => const SeguridadPage()),
          (texto: 'Márgenes', icono: Icons.percent, permiso: 'informes', pagina: () => const MargenesPage()),
          (texto: 'IVA trimestral', icono: Icons.account_balance_outlined, permiso: 'informes', pagina: () => const IvaPage()),
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
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              children: [
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
                              setState(() => _titulo = _visibles[i].titulo);
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
                      else ...[
                        // Los tres de arriba, del mismo tamaño: empresa, quién está y abrir cajón
                        OutlinedButton.icon(
                          style: _estiloCabecera,
                          onPressed: _empresas,
                          icon: const Icon(Icons.storefront_outlined),
                          label: Text(widget.perfil.empresaNombre ?? 'Empresa', overflow: TextOverflow.ellipsis),
                        ),
                      ],
                      if (!estrecho) const SizedBox(width: 12),
                      if (!estrecho) Container(
                        height: 48,
                        constraints: const BoxConstraints(minWidth: 160),
                        padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
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
                            // Solo el nombre: la empresa ya se ve en el botón de al lado
                            Text(widget.perfil.nombre, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          ],
                        ),
                      ),
                      // A la derecha del todo, junto al usuario
                      if (!estrecho && widget.perfil.puede('cobrar')) ...[
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          style: _estiloCabecera,
                          onPressed: () => Impresion.abrirCajon().catchError((e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo abrir el cajón: $e')));
                            }
                          }),
                          icon: const Icon(Icons.point_of_sale),
                          label: const Text('Abrir cajón'),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(child: contenido),
              ],
            ),
          ),
              if (!estrecho) menu, // el menú de secciones va a la derecha
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
    // Sin seleccionar: texto claro y un fondo suave, para que se lean con mucha luz en la sala
    final color = activo ? C.sobreAccion : const Color(0xFFE6E1D6);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: activo ? C.verde : const Color(0xFF34322E),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            width: 78,
            height: 50,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icono, color: color, size: 22),
                const SizedBox(height: 3),
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
