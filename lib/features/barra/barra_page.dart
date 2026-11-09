import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../caja/cobro_dialog.dart';
import '../carta/colores.dart';
import '../comanda/comanda_page.dart' show BotonProducto, ChipGrupo;
import '../ticketbai/modelos.dart' show euros;
import '../ticketbai/ticket_view.dart';

class _Linea {
  _Linea(this.producto);
  final Map<String, dynamic> producto;
  double cantidad = 1;
  double get precio => (producto['precio_venta'] as num).toDouble();
  double get total => cantidad * precio;
}

/// Venta rápida en barra: sin mesas. Se cobra al momento o se deja
/// en una cuenta con nombre para los habituales.
class BarraPage extends StatefulWidget {
  const BarraPage({super.key});

  @override
  State<BarraPage> createState() => _BarraPageState();
}

class _BarraPageState extends State<BarraPage> {
  bool _cargando = true;
  String? _error;
  bool _ocupado = false;

  List<Map<String, dynamic>> _grupos = [];
  List<Map<String, dynamic>> _productos = [];
  Map<String, String> _areas = {};
  String? _grupoId;

  List<Map<String, dynamic>> _cuentas = [];
  Map<String, dynamic>? _cuenta; // cuenta abierta seleccionada
  final List<_Linea> _ronda = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final r = await Future.wait([
        supabase.from('grupos_productos').select('id, nombre, color').eq('activo', true).order('orden').order('nombre'),
        supabase.from('productos').select('id, grupo_id, area_id, nombre, precio_venta, alergenos').eq('activo', true).order('nombre'),
        supabase.from('areas_preparacion').select('id, nombre'),
      ]);
      _grupos = List<Map<String, dynamic>>.from(r[0]);
      _productos = List<Map<String, dynamic>>.from(r[1]);
      _areas = {for (final a in r[2]) a['id'] as String: a['nombre'] as String};
      _grupoId ??= _grupos.isEmpty ? null : _grupos.first['id'] as String;
      await _cargarCuentas();
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _cargarCuentas() async {
    _cuentas = List<Map<String, dynamic>>.from(await supabase
        .from('pedidos')
        .select('id, nombre_llevar, total, creado_en, estado, '
            'pedido_detalle(id, descripcion, cantidad, precio_unitario, estado_cocina)')
        .eq('tipo', 'barra')
        .inFilter('estado', ['abierto', 'precuenta'])
        .not('nombre_llevar', 'is', null)
        .order('creado_en'));
    if (_cuenta != null) {
      _cuenta = _cuentas.where((c) => c['id'] == _cuenta!['id']).firstOrNull;
    }
  }

  void _anadir(Map<String, dynamic> p) {
    setState(() {
      final l = _ronda.where((l) => l.producto['id'] == p['id']).firstOrNull;
      if (l != null) {
        l.cantidad++;
      } else {
        _ronda.add(_Linea(p));
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
            'descripcion': l.producto['nombre'],
            'cantidad': l.cantidad,
            'precio_unitario': l.precio,
            // Lo de cocina va a la pantalla; lo de barra se sirve al momento
            'estado_cocina': _areas[l.producto['area_id']] == 'Cocina' ? 'pendiente' : 'servido',
            'curso': 'ya',
          },
      ]);
    }
    return id;
  }

  Future<void> _cobrar() async {
    if (_ronda.isEmpty && _cuenta == null) return;
    setState(() => _ocupado = true);
    final eraNueva = _cuenta == null;
    try {
      final id = await _guardarRonda();
      final pedido = await supabase
          .from('pedidos')
          .select('id, total, pedido_detalle(id, descripcion, cantidad, precio_unitario, estado_cocina)')
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
        await showDialog<void>(
          context: context,
          builder: (_) => Dialog(child: SingleChildScrollView(child: TicketView(factura: factura))),
        );
      }
      _ronda.clear();
      _cuenta = null;
      await _cargarCuentas();
    } catch (e) {
      _avisar('No se pudo cobrar: $e');
    }
    if (mounted) setState(() => _ocupado = false);
  }

  Future<void> _aCuenta() async {
    if (_ronda.isEmpty) return;
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
    setState(() => _ocupado = true);
    try {
      await _guardarRonda(nombre: nombre);
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
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Error: $_error'));
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
        // Cuentas abiertas
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text('Cuentas', style: titulo(18)),
              const Spacer(),
              if (_cuenta != null)
                TextButton.icon(
                  onPressed: () => setState(() => _cuenta = null),
                  icon: const Icon(Icons.add),
                  label: const Text('Venta nueva'),
                ),
            ],
          ),
        ),
        SizedBox(
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
          child: Text(_cuenta == null ? 'Venta rápida' : 'Cuenta de ${_cuenta!['nombre_llevar']}',
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
                      Expanded(child: Text(l.producto['nombre'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
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
                      label: Text(_cuenta == null ? 'A cuenta' : 'Añadir'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 60,
                      child: FilledButton.icon(
                        onPressed: total <= 0 || _ocupado ? null : _cobrar,
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
