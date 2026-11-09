import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../caja/cobro_dialog.dart';
import '../carta/alergenos.dart';
import '../carta/colores.dart';
import '../ticketbai/modelos.dart' show euros;
import '../ticketbai/ticket_view.dart';

const _cursos = {'ya': 'Ya', '1': '1.º', '2': '2.º', 'postre': 'Postre'};
const _siguienteCurso = {'ya': '1', '1': '2', '2': 'postre', 'postre': 'ya'};
const _estadosCocina = {
  'pendiente': 'En cola',
  'preparando': 'Preparando',
  'listo': 'Listo',
  'servido': 'Servido',
  'anulado': 'Anulado',
};

/// Una línea de la ronda que aún no se ha enviado.
class _Linea {
  _Linea(this.producto, this.curso);
  final Map<String, dynamic> producto;
  double cantidad = 1;
  String nota = '';
  String curso;

  double get precio => (producto['precio_venta'] as num).toDouble();
  double get total => cantidad * precio;
}

/// Toma de comanda de una mesa: carta a la izquierda (o arriba en móvil)
/// y la ronda a la derecha (o abajo).
class ComandaPage extends StatefulWidget {
  const ComandaPage({super.key, required this.mesa, required this.zona});
  final Map<String, dynamic> mesa;
  final String zona;

  @override
  State<ComandaPage> createState() => _ComandaPageState();
}

class _ComandaPageState extends State<ComandaPage> {
  bool _cargando = true;
  String? _error;
  bool _enviando = false;

  List<Map<String, dynamic>> _grupos = [];
  List<Map<String, dynamic>> _productos = [];
  Map<String, String> _areas = {};
  String? _grupoId;
  String _busqueda = '';

  Map<String, dynamic>? _pedido;
  final List<_Linea> _ronda = [];
  late int _pax = (widget.mesa['capacidad'] as int?) ?? 2;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final r = await Future.wait([
        supabase.from('grupos_productos').select('id, nombre, color').eq('activo', true).order('orden').order('nombre'),
        supabase
            .from('productos')
            .select('id, grupo_id, area_id, nombre, precio_venta, alergenos')
            .eq('activo', true)
            .order('nombre'),
        supabase.from('areas_preparacion').select('id, nombre'),
      ]);
      final pedido = await supabase
          .from('pedidos')
          .select('id, num_personas, total, creado_en, estado, '
              'pedido_detalle(id, descripcion, cantidad, precio_unitario, nota, curso, estado_cocina, en_espera, creado_en)')
          .eq('mesa_id', widget.mesa['id'])
          .inFilter('estado', ['abierto', 'precuenta'])
          .order('creado_en')
          .limit(1)
          .maybeSingle();
      _grupos = List<Map<String, dynamic>>.from(r[0]);
      _productos = List<Map<String, dynamic>>.from(r[1]);
      _areas = {for (final a in r[2]) a['id'] as String: a['nombre'] as String};
      _grupoId ??= _grupos.isEmpty ? null : _grupos.first['id'] as String;
      _pedido = pedido;
      if (pedido?['num_personas'] != null) _pax = pedido!['num_personas'] as int;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  // ---------------- Ronda ----------------

  void _anadir(Map<String, dynamic> p) {
    final esBarra = _areas[p['area_id']] == 'Barra';
    final curso = esBarra ? 'ya' : '1';
    final existente = _ronda.where((l) => l.producto['id'] == p['id'] && l.nota.isEmpty && l.curso == curso);
    setState(() {
      if (existente.isNotEmpty) {
        existente.first.cantidad++;
      } else {
        _ronda.add(_Linea(p, curso));
      }
    });
  }

  double _cantidadEnRonda(String productoId) =>
      _ronda.where((l) => l.producto['id'] == productoId).fold(0.0, (s, l) => s + l.cantidad);

  double get _totalRonda => _ronda.fold(0.0, (s, l) => s + l.total);
  int get _unidades => _ronda.fold(0, (s, l) => s + l.cantidad.round());

  Future<void> _editarNota(_Linea l) async {
    final ctrl = TextEditingController(text: l.nota);
    const rapidas = ['Sin cebolla', 'Sin sal', 'Poco hecho', 'Al punto', 'Muy hecho', 'Sin gluten', 'Para compartir'];
    final nota = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Nota · ${l.producto['nombre']}'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Nota para cocina')),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final n in rapidas)
                    ActionChip(
                      label: Text(n),
                      onPressed: () => ctrl.text = ctrl.text.isEmpty ? n : '${ctrl.text}, $n',
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Guardar')),
        ],
      ),
    );
    if (nota != null) setState(() => l.nota = nota);
  }

  Future<void> _marchar(String curso) async {
    try {
      await supabase
          .from('pedido_detalle')
          .update({'en_espera': false})
          .eq('pedido_id', _pedido!['id'])
          .eq('curso', curso)
          .eq('en_espera', true);
      await _cargar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Marchando ${curso == '2' ? 'segundos' : 'postres'}')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _servido(Map<String, dynamic> d) async {
    await supabase.from('pedido_detalle').update({'estado_cocina': 'servido'}).eq('id', d['id']);
    await _cargar();
  }

  Future<void> _precuenta() async {
    await supabase.from('pedidos').update({'estado': 'precuenta'}).eq('id', _pedido!['id']);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Mesa ${widget.mesa['nombre']}: pide la cuenta')),
    );
    Navigator.pop(context, true);
  }

  Future<void> _cobrar() async {
    final factura = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CobroDialog(pedido: _pedido!, mesaId: widget.mesa['id'] as String),
    );
    if (factura == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(child: SingleChildScrollView(child: TicketView(factura: factura))),
    );
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _enviar() async {
    if (_ronda.isEmpty) return;
    setState(() => _enviando = true);
    try {
      var pedidoId = _pedido?['id'] as String?;
      if (pedidoId == null) {
        final nuevo = await supabase
            .from('pedidos')
            .insert({
              'tipo': 'mesa',
              'mesa_id': widget.mesa['id'],
              'num_personas': _pax,
              'camarero_id': supabase.auth.currentUser?.id,
            })
            .select('id')
            .single();
        pedidoId = nuevo['id'] as String;
      }
      await supabase.from('pedido_detalle').insert([
        for (final l in _ronda)
          {
            'pedido_id': pedidoId,
            'producto_id': l.producto['id'],
            'area_id': l.producto['area_id'],
            'descripcion': l.producto['nombre'],
            'cantidad': l.cantidad,
            'precio_unitario': l.precio,
            'nota': l.nota.isEmpty ? null : l.nota,
            'curso': l.curso,
            'en_espera': l.curso == '2' || l.curso == 'postre',
          },
      ]);
      if (widget.mesa['disponibilidad'] != 'ocupada') {
        await supabase.from('mesas').update({'disponibilidad': 'ocupada'}).eq('id', widget.mesa['id']);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Mesa ${widget.mesa['nombre']}: enviado a cocina y barra')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _enviando = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo enviar: $e')));
    }
  }

  // ---------------- Interfaz ----------------

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_error != null) return Scaffold(appBar: AppBar(), body: Center(child: Text('Error: $_error')));

    final ancho = MediaQuery.sizeOf(context).width >= 900;
    return PopScope(
      canPop: _ronda.isEmpty || _enviando,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final salir = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('¿Descartar la ronda?'),
            content: const Text('Hay productos sin enviar.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Seguir pidiendo')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Descartar')),
            ],
          ),
        );
        if (salir == true && context.mounted) {
          _ronda.clear();
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: ancho
              ? Row(
                  children: [
                    Expanded(child: _carta()),
                    Container(
                      width: 420,
                      decoration: const BoxDecoration(
                        color: C.blanco,
                        border: Border(left: BorderSide(color: C.borde)),
                      ),
                      child: _panel(compacto: false),
                    ),
                  ],
                )
              : Column(
                  children: [
                    Expanded(child: _carta()),
                    Container(
                      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                      decoration: const BoxDecoration(
                        color: C.blanco,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                        border: Border(top: BorderSide(color: C.borde)),
                      ),
                      child: _panel(compacto: true),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _carta() {
    final texto = _busqueda.trim().toLowerCase();
    final visibles = _productos
        .where((p) => texto.isEmpty
            ? p['grupo_id'] == _grupoId
            : (p['nombre'] as String).toLowerCase().contains(texto))
        .toList();
    final abierta = _pedido == null
        ? 'Mesa nueva'
        : 'Abierta hace ${DateTime.now().difference(DateTime.parse(_pedido!['creado_en'] as String)).inMinutes} min';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            children: [
              IconButton.outlined(
                tooltip: 'Volver a mesas',
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Mesa ${widget.mesa['nombre']} · ${widget.zona}', style: titulo(24)),
                    Text(abierta, style: const TextStyle(color: C.gris, fontSize: 13)),
                  ],
                ),
              ),
              _Comensales(
                valor: _pax,
                onCambio: _pedido == null ? (v) => setState(() => _pax = v) : null,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            onChanged: (v) => setState(() => _busqueda = v),
            decoration: const InputDecoration(
              hintText: 'Buscar en la carta',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
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
                    activo: _busqueda.isEmpty && g['id'] == _grupoId,
                    onTap: () => setState(() {
                      _grupoId = g['id'] as String;
                      _busqueda = '';
                    }),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: visibles.isEmpty
              ? const Center(child: Text('No hay productos'))
              : GridView.extent(
                  maxCrossAxisExtent: 210,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.45,
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final p in visibles)
                      BotonProducto(
                        producto: p,
                        cantidad: _cantidadEnRonda(p['id'] as String),
                        onTap: () => _anadir(p),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _panel({required bool compacto}) {
    final yaPedido = ((_pedido?['pedido_detalle'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: compacto ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Text('Nueva ronda', style: titulo(20)),
              const Spacer(),
              if (_ronda.isNotEmpty)
                TextButton(onPressed: () => setState(_ronda.clear), child: const Text('Vaciar')),
            ],
          ),
        ),
        Flexible(
          fit: compacto ? FlexFit.loose : FlexFit.tight,
          child: ListView(
            shrinkWrap: compacto,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              if (_ronda.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Toca productos de la carta para añadirlos.', style: TextStyle(color: C.gris)),
                ),
              for (final l in _ronda) _lineaRonda(l),
              if (yaPedido.isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('Ya pedido', style: TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text(euros(_pedido!['total'] as num), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final c in ['2', 'postre'])
                      if (yaPedido.any((d) => d['curso'] == c && d['en_espera'] == true))
                        OutlinedButton.icon(
                          onPressed: () => _marchar(c),
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: Text('Marchar ${_cursos[c]}'),
                        ),
                  ],
                ),
                for (final d in yaPedido)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Text('${(d['cantidad'] as num).toStringAsFixed(0)}× ',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: C.gris)),
                        Expanded(child: Text(d['descripcion'] as String, style: const TextStyle(color: C.gris))),
                        if (d['estado_cocina'] == 'listo')
                          TextButton(onPressed: () => _servido(d), child: const Text('Listo · Servir'))
                        else
                          Text(
                            d['en_espera'] == true
                                ? 'En espera'
                                : _estadosCocina[d['estado_cocina']] ?? '',
                            style: const TextStyle(fontSize: 12, color: C.gris),
                          ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
        if (_pedido != null && _ronda.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                if (_pedido!['estado'] == 'abierto')
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _precuenta,
                      icon: const Icon(Icons.receipt_outlined),
                      label: const Text('Pide la cuenta'),
                    ),
                  ),
                if (_pedido!['estado'] == 'abierto' && (Perfil.cache?.rol != Rol.cocinero))
                  const SizedBox(width: 8),
                if (Perfil.cache?.rol != Rol.cocinero)
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: C.tinta),
                      onPressed: _cobrar,
                      icon: const Icon(Icons.point_of_sale),
                      label: Text('Cobrar ${euros(_pedido!['total'] as num)}'),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: FilledButton(
            onPressed: _ronda.isEmpty || _enviando ? null : _enviar,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_enviando ? 'Enviando…' : 'Enviar · $_unidades uds.'),
                const SizedBox(width: 12),
                Text(euros(_totalRonda), style: titulo(17, color: C.sobreAccion)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _lineaRonda(_Linea l) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.borde))),
      child: Row(
        children: [
          _Paso(
            icono: Icons.remove,
            onTap: () => setState(() {
              if (l.cantidad > 1) {
                l.cantidad--;
              } else {
                _ronda.remove(l);
              }
            }),
          ),
          SizedBox(
            width: 32,
            child: Text(l.cantidad.toStringAsFixed(0), textAlign: TextAlign.center, style: titulo(18)),
          ),
          _Paso(icono: Icons.add, onTap: () => setState(() => l.cantidad++)),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => _editarNota(l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.producto['nombre'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(l.nota.isEmpty ? 'Añadir nota' : l.nota,
                      style: TextStyle(fontSize: 12, color: l.nota.isEmpty ? C.gris : C.naranja)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: 'Cambiar orden de salida',
            child: ActionChip(
              label: Text(_cursos[l.curso]!),
              onPressed: () => setState(() => l.curso = _siguienteCurso[l.curso]!),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 64,
            child: Text(euros(l.total), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _Paso extends StatelessWidget {
  const _Paso({required this.icono, required this.onTap});
  final IconData icono;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 36,
        height: 36,
        child: IconButton.outlined(
          padding: EdgeInsets.zero,
          iconSize: 18,
          tooltip: icono == Icons.add ? 'Uno más' : 'Uno menos',
          onPressed: onTap,
          icon: Icon(icono),
        ),
      );
}

class _Comensales extends StatelessWidget {
  const _Comensales({required this.valor, required this.onCambio});
  final int valor;
  final ValueChanged<int>? onCambio;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.blanco,
        border: Border.all(color: C.bordeFuerte),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Menos comensales',
            onPressed: onCambio == null || valor <= 1 ? null : () => onCambio!(valor - 1),
            icon: const Icon(Icons.remove, size: 18),
          ),
          const Icon(Icons.person_outline, size: 18),
          Text(' $valor', style: const TextStyle(fontWeight: FontWeight.w700)),
          IconButton(
            tooltip: 'Más comensales',
            onPressed: onCambio == null ? null : () => onCambio!(valor + 1),
            icon: const Icon(Icons.add, size: 18),
          ),
        ],
      ),
    );
  }
}

class ChipGrupo extends StatelessWidget {
  const ChipGrupo({required this.nombre, required this.color, required this.activo, required this.onTap});
  final String nombre;
  final Color color;
  final bool activo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        shape: StadiumBorder(side: BorderSide(color: activo ? C.tinta : Colors.transparent, width: 2.5)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Center(
              child: Text(nombre, style: const TextStyle(fontWeight: FontWeight.w700, color: C.tinta)),
            ),
          ),
        ),
      );
}

class BotonProducto extends StatelessWidget {
  const BotonProducto({required this.producto, required this.cantidad, required this.onTap});
  final Map<String, dynamic> producto;
  final double cantidad;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final al = ((producto['alergenos'] as List?) ?? []).cast<String>();
    return Material(
      color: C.blanco,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cantidad > 0 ? C.verde : C.borde, width: cantidad > 0 ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: cantidad > 0 ? 30 : 0),
                    child: Text(producto['nombre'] as String,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, height: 1.2)),
                  ),
                  const Spacer(),
                  if (al.isNotEmpty)
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final a in al)
                          Tooltip(
                            message: alergenos[a] ?? a,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: C.borde,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(alergenosCorto[a] ?? a,
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: C.gris)),
                            ),
                          ),
                      ],
                    ),
                  const SizedBox(height: 4),
                  Text(euros(producto['precio_venta'] as num), style: titulo(17)),
                ],
              ),
              if (cantidad > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: C.verde,
                    child: Text(cantidad.toStringAsFixed(0),
                        style: const TextStyle(color: C.sobreAccion, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
