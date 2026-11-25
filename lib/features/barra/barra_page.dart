import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../../core/impresion.dart';
import '../auth/perfil.dart';
import '../caja/abrir_caja.dart';
import '../caja/caja_service.dart';
import '../caja/cobro_dialog.dart';
import '../carta/colores.dart';
import '../comanda/comanda_page.dart' show BotonProducto, ChipGrupo;
import '../comanda/modificadores_picker.dart';
import '../ticketbai/modelos.dart' show euros;
import '../ticketbai/ticket_view.dart';
import '../ticketbai/ventas_hoy.dart';
import '../ticketbai/tbai_proveedor.dart' show precalentarFirma;
import '../ticketbai/envios_pendientes.dart';
import 'venta_offline.dart';

class _Linea {
  _Linea(this.producto, [this.mods = const []]);
  final Map<String, dynamic> producto;
  final List<Map<String, dynamic>> mods;
  double cantidad = 1;
  String get nombre => nombreConModificadores(producto, mods);
  double get precio => precioConModificadores(producto, mods);
  double get total => cantidad * precio;
}

/// Venta rápida en barra: sin mesas. Se cobra al momento o se deja
/// en una cuenta con nombre para los habituales.
class BarraPage extends StatefulWidget {
  const BarraPage({super.key, this.mesa, this.zona});

  /// Sin internet, las mesas se atienden con esta misma pantalla ("modo mesa").
  final Map<String, dynamic>? mesa;
  final String? zona;

  @override
  State<BarraPage> createState() => _BarraPageState();
}

class _BarraPageState extends State<BarraPage> {
  bool _cargando = true;
  String? _error;
  bool _ocupado = false;
  bool _sinConexion = false; // carta cargada de la copia del equipo

  List<Map<String, dynamic>> _grupos = [];
  List<Map<String, dynamic>> _productos = [];
  Map<String, String> _areas = {};
  String? _grupoId;

  List<Map<String, dynamic>> _cuentas = [];
  Map<String, dynamic>? _cuenta; // cuenta abierta seleccionada
  final List<_Linea> _ronda = [];
  bool _cajaAbierta = true; // se comprueba al cargar (con internet)

  @override
  void initState() {
    super.initState();
    Conexion.enLinea.addListener(_alCambiarConexion);
    precalentarFirma();
    _cargar();
  }

  @override
  void dispose() {
    Conexion.enLinea.removeListener(_alCambiarConexion);
    super.dispose();
  }

  /// Se va internet: se cobra en el equipo al momento. Vuelve: se recarga todo solo.
  void _alCambiarConexion() {
    if (!mounted) return;
    if (Conexion.enLinea.value) {
      if (_sinConexion && !_ocupado) _cargar();
    } else if (!_sinConexion) {
      setState(() => _sinConexion = true);
    }
  }

  Future<void> _cargar() async {
    try {
      // En modo mesa (solo se abre sin internet) se trabaja con la copia del equipo
      if (_modoMesa) throw http.ClientException('Modo mesa sin conexión (SocketException)');
      exigirConexion();
      final r = await Future.wait([
        supabase.from('grupos_productos').select('id, nombre, color').eq('activo', true).order('orden').order('nombre'),
        supabase.from('productos').select('id, grupo_id, area_id, nombre, precio_venta, tipo_iva, alergenos, imagen_url, producto_modificadores(modificadores(id, nombre, precio, activo))').eq('activo', true).order('nombre'),
        supabase.from('areas_preparacion').select('id, nombre'),
      ]);
      _grupos = List<Map<String, dynamic>>.from(r[0]);
      _productos = List<Map<String, dynamic>>.from(r[1]);
      _areas = {for (final a in r[2]) a['id'] as String: a['nombre'] as String};
      _grupoId ??= _grupos.isEmpty ? null : _grupos.first['id'] as String;
      await _cargarCuentas();
      if (!_modoMesa) await _comprobarCaja();
      _error = null;
      _sinConexion = false;
      // Copia para poder vender si se cae internet
      VentaOffline.guardarCarta(_grupos, _productos, _areas).ignore();
      VentaOffline.guardarContexto().catchError((_) {});
    } catch (e) {
      final copia = esErrorDeRed(e) ? await VentaOffline.leerCarta() : null;
      if (copia != null) {
        _grupos = copia.grupos;
        _productos = copia.productos;
        _areas = copia.areas;
        _grupoId ??= _grupos.isEmpty ? null : _grupos.first['id'] as String;
        _sinConexion = true;
        await _cargarCuentas();
        _error = null;
      } else {
        _error = '$e';
      }
    }
    if (mounted) setState(() => _cargando = false);
  }

  bool get _modoMesa => widget.mesa != null;

  Future<void> _comprobarCaja() async {
    try {
      final caja = await CajaService.caja();
      _cajaAbierta = await CajaService.turnoAbierto(caja['id'] as String) != null;
    } catch (_) {
      _cajaAbierta = true; // si no se puede comprobar, no se molesta
    }
  }

  Future<void> _abrirCaja() async {
    try {
      if (await abrirCajaRapida(context)) setState(() => _cajaAbierta = true);
    } catch (e) {
      _avisar('No se pudo abrir la caja: $e');
    }
  }

  Future<void> _cargarCuentas() async {
    if (_modoMesa) {
      // La mesa: su pedido abierto (copia + lo apuntado en este equipo) o uno nuevo
      final abiertas = await VentaOffline.abiertas();
      _cuenta = abiertas.where((p) => p['mesa_id'] == widget.mesa!['id']).firstOrNull ??
          (_cuenta?['mesa_id'] == widget.mesa!['id'] ? _cuenta : null) ??
          VentaOffline.nuevoPedido(mesaId: widget.mesa!['id'] as String);
      _cuentas = [];
      return;
    }
    if (_sinConexion || !Conexion.enLinea.value) {
      _cuentas = [
        for (final p in await VentaOffline.abiertas())
          if (p['tipo'] == 'barra' && p['nombre_llevar'] != null) p,
      ];
      if (_cuenta != null) _cuenta = _cuentas.where((c) => c['id'] == _cuenta!['id']).firstOrNull;
      return;
    }
    _cuentas = List<Map<String, dynamic>>.from(await supabase
        .from('pedidos')
        .select('id, nombre_llevar, total, creado_en, estado, '
            'pedido_detalle(id, descripcion, cantidad, precio_unitario, tipo_iva, estado_cocina)')
        .eq('tipo', 'barra')
        .inFilter('estado', ['abierto', 'precuenta'])
        .not('nombre_llevar', 'is', null)
        .order('creado_en'));
    VentaOffline.guardarAbiertas([for (final c in _cuentas) {...c, 'tipo': 'barra'}], barra: true).ignore();
    if (_cuenta != null) {
      _cuenta = _cuentas.where((c) => c['id'] == _cuenta!['id']).firstOrNull;
    }
  }

  Future<void> _anadir(Map<String, dynamic> p) async {
    final mods = await elegirModificadores(context, p);
    if (mods == null || !mounted) return;
    final clave = claveModificadores(mods);
    setState(() {
      final l = _ronda.where((l) => l.producto['id'] == p['id'] && claveModificadores(l.mods) == clave).firstOrNull;
      if (l != null) {
        l.cantidad++;
      } else {
        _ronda.add(_Linea(p, mods));
      }
    });
  }

  double get _totalRonda => _ronda.fold(0.0, (s, l) => s + l.total);
  double get _totalCuenta => (_cuenta?['total'] as num?)?.toDouble() ?? 0;

  /// Crea el pedido si hace falta y le añade la ronda. Devuelve su id.
  Future<String> _guardarRonda({String? nombre}) async {
    var id = _cuenta?['id'] as String?;
    if (id == null) {
      final p = await supabase
          .from('pedidos')
          .insert({
            'tipo': 'barra',
            'nombre_llevar': nombre,
            'camarero_id': supabase.auth.currentUser?.id,
          })
          .select('id')
          .single();
      id = p['id'] as String;
    }
    if (_ronda.isNotEmpty) {
      await supabase.from('pedido_detalle').insert([
        for (final l in _ronda)
          {
            'pedido_id': id,
            'producto_id': l.producto['id'],
            'area_id': l.producto['area_id'],
            'descripcion': l.nombre,
            'cantidad': l.cantidad,
            'precio_unitario': l.precio,
            // Lo de cocina va a la pantalla; lo de barra se sirve al momento
            'estado_cocina': _areas[l.producto['area_id']] == 'Cocina' ? 'pendiente' : 'servido',
            'curso': 'ya',
          },
      ]);
      Impresion.imprimirComanda(
        'Cocina',
        _cuenta?['nombre_llevar'] as String? ?? nombre ?? 'Barra',
        [
          for (final l in _ronda)
            if (_areas[l.producto['area_id']] == 'Cocina')
              {'cantidad': l.cantidad.toStringAsFixed(0), 'descripcion': l.nombre, 'curso': 'ya'},
        ],
      ).ignore();
    }
    return id;
  }

  Future<void> _cobrar() async {
    if (_ronda.isEmpty && _cuenta == null) return;
    if (_sinConexion || !Conexion.enLinea.value) return _cobrarSinConexion();
    setState(() => _ocupado = true);
    final eraNueva = _cuenta == null;
    try {
      final String id;
      try {
        id = await _guardarRonda();
      } catch (e) {
        // Se ha caído internet: venta rápida firmada en el equipo
        if (esErrorDeRed(e)) {
          setState(() {
            _ocupado = false;
            _sinConexion = true;
          });
          return await _cobrarSinConexion();
        }
        rethrow;
      }
      final pedido = await supabase
          .from('pedidos')
          .select('id, total, pedido_detalle(id, descripcion, cantidad, precio_unitario, tipo_iva, estado_cocina)')
          .eq('id', id)
          .single();
      if (!mounted) return;
      final factura = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CobroDialog(pedido: pedido, mesaId: null),
      );
      if (factura == null) {
        // Cobro cancelado: una venta rápida sin nombre no se queda abierta
        if (eraNueva) await supabase.from('pedidos').update({'estado': 'anulado'}).eq('id', id);
      } else if (mounted) {
        await ticketCobrado(context, factura);
      }
      _ronda.clear();
      _cuenta = null;
      await _cargarCuentas();
      await _comprobarCaja(); // por si se abrió desde el cobro
    } catch (e) {
      _avisar('No se pudo cobrar: $e');
    }
    if (mounted) setState(() => _ocupado = false);
  }

  /// Venta rápida sin internet: un solo pago, solo ticket (sin NIF). Se firma en el equipo,
  /// se imprime y se guarda; al volver la conexión se sube y se envía a Hacienda sola.
  Future<void> _cobrarSinConexion() async {
    if (_ronda.isEmpty && _totalCuenta <= 0) return;
    final motivo = await VentaOffline.motivoNoDisponible();
    if (motivo != null) {
      _avisar('Sin internet no se puede cobrar: $motivo');
      return;
    }
    if (!mounted) return;
    final total = ((_totalCuenta + _totalRonda) * 100).roundToDouble() / 100;
    final pago = await showDialog<({String metodo, double? entregado})>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CobroSinConexion(total: total),
    );
    if (pago == null || !mounted) return;
    setState(() => _ocupado = true);
    try {
      final factura = await VentaOffline.vender(
        pedido: _cuenta,
        detalleNuevo: _detalleRonda(),
        metodo: pago.metodo,
        entregado: pago.entregado,
      );
      final cocina = [
        for (final l in _ronda)
          if (_areas[l.producto['area_id']] == 'Cocina')
            {'cantidad': l.cantidad.toStringAsFixed(0), 'descripcion': l.nombre, 'curso': 'ya'},
      ];
      if (cocina.isNotEmpty) Impresion.imprimirComanda('Cocina', _titulo, cocina).ignore();
      _ronda.clear();
      _cuenta = null;
      await _cargarCuentas();
      EnviosPendientes.revisar(); // actualiza el aviso de ventas guardadas
      if (mounted) {
        await ticketCobrado(context, {
          ...factura,
          'pagos': [
            {'metodo': pago.metodo, 'importe': total, 'entregado': pago.entregado},
          ],
          'origen': 'Barra',
        });
      }
      if (_modoMesa && mounted) {
        Navigator.pop(context, true); // mesa cobrada: vuelve al plano
        return;
      }
    } catch (e) {
      _avisar('No se pudo cobrar: $e');
    }
    if (mounted) setState(() => _ocupado = false);
    // Por si ha vuelto internet
    _reintentarConexion();
  }

  String get _titulo => _modoMesa
      ? 'Mesa ${widget.mesa!['nombre']}'
      : (_cuenta?['nombre_llevar'] as String?) ?? 'Barra';

  List<Map<String, dynamic>> _detalleRonda() => [
        for (final l in _ronda)
          {
            'producto_id': l.producto['id'],
            'area_id': l.producto['area_id'],
            'descripcion': l.nombre,
            'cantidad': l.cantidad,
            'precio_unitario': l.precio,
            'tipo_iva': ((l.producto['tipo_iva'] as num?) ?? 10).toDouble(),
            'estado_cocina': _areas[l.producto['area_id']] == 'Cocina' ? 'pendiente' : 'servido',
          },
      ];

  /// Sin internet: deja la ronda apuntada en la mesa o en la cuenta (se sube sola después).
  Future<void> _apuntarSinConexion(String? nombre) async {
    setState(() => _ocupado = true);
    try {
      final pedido = _cuenta ?? VentaOffline.nuevoPedido(nombre: nombre);
      await VentaOffline.anadirACuenta(pedido, _detalleRonda());
      final cocina = [
        for (final l in _ronda)
          if (_areas[l.producto['area_id']] == 'Cocina')
            {'cantidad': l.cantidad.toStringAsFixed(0), 'descripcion': l.nombre, 'curso': 'ya'},
      ];
      if (cocina.isNotEmpty) {
        Impresion.imprimirComanda('Cocina', _modoMesa ? _titulo : (nombre ?? _titulo), cocina).ignore();
      }
      _ronda.clear();
      if (_modoMesa) {
        if (mounted) Navigator.pop(context, true);
        return;
      }
      _avisar(_cuenta == null ? 'Cuenta de $nombre abierta (sin internet)' : 'Añadido a la cuenta (sin internet)');
      _cuenta = null;
      await _cargarCuentas();
    } catch (e) {
      _avisar('No se pudo guardar: $e');
    }
    if (mounted) setState(() => _ocupado = false);
  }

  Future<void> _reintentarConexion() async {
    if (!_sinConexion) return;
    // Si hay conexión, el aviso de Conexion recarga la barra
    final antes = Conexion.enLinea.value; // si cambia, ya recarga _alCambiarConexion
    if (await Conexion.comprobar() && antes && mounted && _sinConexion) await _cargar();
  }

  Future<void> _aCuenta() async {
    if (_ronda.isEmpty) return;
    final sinRed = _sinConexion || !Conexion.enLinea.value;
    if (sinRed && (_cuenta != null || _modoMesa)) return _apuntarSinConexion(null);
    String? nombre;
    if (_cuenta == null) {
      final ctrl = TextEditingController();
      nombre = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Abrir cuenta'),
          content: SizedBox(
            width: 340,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre (Iñaki, la cuadrilla…)'),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Abrir')),
          ],
        ),
      );
      if (nombre == null || nombre.isEmpty) return;
    }
    if (sinRed) return _apuntarSinConexion(nombre);
    setState(() => _ocupado = true);
    try {
      try {
        await _guardarRonda(nombre: nombre);
      } catch (e) {
        if (!esErrorDeRed(e)) rethrow;
        // Se ha ido internet justo ahora: se apunta en el equipo
        setState(() {
          _ocupado = false;
          _sinConexion = true;
        });
        return await _apuntarSinConexion(nombre);
      }
      _avisar(_cuenta == null ? 'Cuenta de $nombre abierta' : 'Añadido a la cuenta de ${_cuenta!['nombre_llevar']}');
      _ronda.clear();
      _cuenta = null;
      await _cargarCuentas();
    } catch (e) {
      _avisar('No se pudo guardar: $e');
    }
    if (mounted) setState(() => _ocupado = false);
  }

  void _avisar(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  @override
  Widget build(BuildContext context) {
    if (!_modoMesa) return _cuerpo();
    return Scaffold(
      appBar: AppBar(title: Text('$_titulo${widget.zona == null ? '' : ' · ${widget.zona}'} · sin internet')),
      body: _cuerpo(),
    );
  }

  Widget _cuerpo() {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(textoError(_error)));
    final ancho = MediaQuery.sizeOf(context).width >= 900;
    final panel = _panel();
    return ancho
        ? Row(
            children: [
              Expanded(child: _carta()),
              Container(
                width: 420,
                decoration: const BoxDecoration(color: C.blanco, border: Border(left: BorderSide(color: C.borde))),
                child: panel,
              ),
            ],
          )
        : Column(
            children: [
              Expanded(child: _carta()),
              Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                decoration: const BoxDecoration(
                  color: C.blanco,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: panel,
              ),
            ],
          );
  }

  Widget _carta() {
    final visibles = _productos.where((p) => p['grupo_id'] == _grupoId).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final g in _grupos)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChipGrupo(
                    nombre: g['nombre'] as String,
                    color: colorDe(g['color'] as String?),
                    activo: g['id'] == _grupoId,
                    onTap: () => setState(() => _grupoId = g['id'] as String),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.extent(
            maxCrossAxisExtent: 190,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.3,
            padding: const EdgeInsets.all(16),
            children: [
              for (final p in visibles)
                BotonProducto(
                  producto: p,
                  cantidad: _ronda.where((l) => l.producto['id'] == p['id']).fold(0.0, (s, l) => s + l.cantidad),
                  onTap: () => _anadir(p),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _panel() {
    final yaEnCuenta = ((_cuenta?['pedido_detalle'] as List?) ?? []).cast<Map<String, dynamic>>();
    final total = _totalCuenta + _totalRonda;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_sinConexion)
          Material(
            color: const Color(0xFFFDF0DC),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.wifi_off, color: Color(0xFFB45309)),
              title: const Text('Sin internet', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Se cobra y firma en este equipo; se envía a Hacienda al volver la conexión'),
              trailing: TextButton(onPressed: _ocupado ? null : _reintentarConexion, child: const Text('Reintentar')),
            ),
          ),
        if (!_modoMesa && !_sinConexion && !_cajaAbierta)
          Material(
            color: const Color(0xFFFDF0DC),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, color: Color(0xFFB45309)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('La caja está cerrada', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  FilledButton.icon(
                    onPressed: _ocupado ? null : _abrirCaja,
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Abrir caja'),
                  ),
                ],
              ),
            ),
          ),
        // Cuentas abiertas (no en modo mesa)
        if (!_modoMesa) Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text('Cuentas', style: titulo(18)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => mostrarVentasHoy(context),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Ventas de hoy'),
              ),
              if (_cuenta != null)
                TextButton.icon(
                  onPressed: () => setState(() => _cuenta = null),
                  icon: const Icon(Icons.add),
                  label: const Text('Venta nueva'),
                ),
            ],
          ),
        ),
        if (!_modoMesa) SizedBox(
          height: 44,
          child: _cuentas.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Sin cuentas abiertas', style: TextStyle(color: C.gris)),
                )
              : ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final c in _cuentas)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          showCheckmark: false,
                          selected: _cuenta?['id'] == c['id'],
                          label: Text('${c['nombre_llevar']} · ${euros(c['total'] as num)}'),
                          onSelected: (_) => setState(() => _cuenta = c),
                        ),
                      ),
                  ],
                ),
        ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
              _modoMesa
                  ? _titulo
                  : _cuenta == null
                      ? 'Venta rápida'
                      : 'Cuenta de ${_cuenta!['nombre_llevar']}',
              style: titulo(22)),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              for (final d in yaEnCuenta)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Text('${(d['cantidad'] as num).toStringAsFixed(0)}× ', style: const TextStyle(color: C.gris)),
                      Expanded(child: Text(d['descripcion'] as String, style: const TextStyle(color: C.gris))),
                      Text(euros((d['cantidad'] as num) * (d['precio_unitario'] as num)),
                          style: const TextStyle(color: C.gris)),
                    ],
                  ),
                ),
              if (yaEnCuenta.isNotEmpty && _ronda.isNotEmpty) const Divider(),
              if (_ronda.isEmpty && yaEnCuenta.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('Toca productos para empezar.', style: TextStyle(color: C.gris)),
                ),
              for (final l in _ronda)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Uno menos',
                        onPressed: () => setState(() => l.cantidad > 1 ? l.cantidad-- : _ronda.remove(l)),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text(l.cantidad.toStringAsFixed(0), style: titulo(18)),
                      IconButton(
                        tooltip: 'Uno más',
                        onPressed: () => setState(() => l.cantidad++),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                      Expanded(child: Text(l.nombre, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(euros(l.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.borde))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('Total', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const Spacer(),
                  Text(euros(total), style: titulo(36, color: C.verde)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _ronda.isEmpty || _ocupado ? null : _aCuenta,
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: Text(_modoMesa ? 'Guardar en la mesa' : _cuenta == null ? 'A cuenta' : 'Añadir'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 60,
                      child: FilledButton.icon(
                        onPressed: total <= 0 || _ocupado || !(Perfil.cache?.puede('cobrar') ?? false) ? null : _cobrar,
                        icon: const Icon(Icons.point_of_sale),
                        label: Text('Cobrar', style: titulo(20, color: C.sobreAccion)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Pago de una venta sin internet: un solo método.
class _CobroSinConexion extends StatefulWidget {
  const _CobroSinConexion({required this.total});
  final double total;

  @override
  State<_CobroSinConexion> createState() => _CobroSinConexionState();
}

class _CobroSinConexionState extends State<_CobroSinConexion> {
  String _metodo = 'efectivo';
  final _entregado = TextEditingController();

  @override
  void dispose() {
    _entregado.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entregado = leerImporte(_entregado.text);
    final cambio = entregado == null ? null : entregado - widget.total;
    final valido = _metodo != 'efectivo' || entregado == null || entregado >= widget.total - 0.001;
    return AlertDialog(
      title: const Text('Cobrar sin internet'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(euros(widget.total), style: titulo(34), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'efectivo', label: Text('Efectivo'), icon: Icon(Icons.payments_outlined)),
              ButtonSegment(value: 'tarjeta', label: Text('Tarjeta'), icon: Icon(Icons.credit_card)),
              ButtonSegment(value: 'bizum', label: Text('Bizum'), icon: Icon(Icons.phone_iphone)),
            ],
            selected: {_metodo},
            onSelectionChanged: (v) => setState(() => _metodo = v.first),
          ),
          if (_metodo == 'efectivo') ...[
            const SizedBox(height: 12),
            TextField(
              controller: _entregado,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Entregado (opcional)', suffixText: '€'),
              onChanged: (_) => setState(() {}),
            ),
            if (cambio != null && cambio >= 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Cambio: ${euros(cambio)}', style: titulo(20, color: C.verde)),
              ),
          ],
          if (_metodo == 'tarjeta')
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('Comprueba que el datáfono tiene conexión (o cobra en efectivo).',
                  style: TextStyle(color: C.gris, fontSize: 13)),
            ),
        ]),
      ),
      actions: [
        const InterruptorTicket(),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: valido
              ? () => Navigator.pop(context, (metodo: _metodo, entregado: _metodo == 'efectivo' ? entregado : null))
              : null,
          child: const Text('Cobrar y emitir ticket'),
        ),
      ],
    );
  }
}
