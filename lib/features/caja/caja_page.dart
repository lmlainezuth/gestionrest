import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/impresion.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/modelos.dart' show euros;
import 'caja_service.dart';

/// Turno de caja: apertura con fondo, ventas por forma de pago,
/// ingresos y gastos, y cierre con arqueo.
class CajaPage extends StatefulWidget {
  const CajaPage({super.key});

  @override
  State<CajaPage> createState() => _CajaPageState();
}

class _CajaPageState extends State<CajaPage> {
  bool _cargando = true;
  String? _error;
  Map<String, dynamic>? _caja;
  Map<String, dynamic>? _turno;
  Map<String, double> _ventas = {};
  List<Map<String, dynamic>> _movimientos = [];
  List<Map<String, dynamic>> _conceptos = [];
  int _tickets = 0;
  int _mesasAbiertas = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      _caja = await CajaService.caja();
      _turno = await CajaService.turnoAbierto(_caja!['id'] as String);
      _conceptos = List<Map<String, dynamic>>.from(
          await supabase.from('conceptos_gasto').select().eq('activo', true).order('nombre'));
      if (_turno != null) {
        final pagos = await supabase.from('pagos').select('metodo, importe, pedido_id').eq('turno_id', _turno!['id']);
        _ventas = {};
        for (final p in pagos) {
          final m = p['metodo'] as String;
          _ventas[m] = (_ventas[m] ?? 0) + (p['importe'] as num).toDouble();
        }
        _tickets = pagos.map((p) => p['pedido_id']).toSet().length;
        _movimientos = List<Map<String, dynamic>>.from(await supabase
            .from('movimientos_caja')
            .select('*, conceptos_gasto(nombre)')
            .eq('turno_id', _turno!['id'])
            .order('creado_en', ascending: false));
        final abiertos = await supabase.from('pedidos').select('id').inFilter('estado', ['abierto', 'precuenta']);
        _mesasAbiertas = abiertos.length;
      }
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  double get _ingresos => _sumaMov('ingreso');
  double get _gastos => _sumaMov('gasto');
  double _sumaMov(String tipo) =>
      _movimientos.where((m) => m['tipo'] == tipo).fold(0.0, (s, m) => s + (m['importe'] as num).toDouble());
  double get _totalVentas => _ventas.values.fold(0.0, (s, v) => s + v);
  double get _efectivoEsperado =>
      (_turno!['efectivo_inicial'] as num).toDouble() + (_ventas['efectivo'] ?? 0) + _ingresos - _gastos;

  Future<double?> _pedirImporte(String titulo, {String? ayuda}) async {
    final ctrl = TextEditingController();
    final r = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ayuda != null) ...[Text(ayuda, style: const TextStyle(color: C.gris)), const SizedBox(height: 12)],
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Importe', suffixText: '€'),
                onSubmitted: (v) => Navigator.pop(ctx, leerImporte(v)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, leerImporte(ctrl.text)), child: const Text('Aceptar')),
        ],
      ),
    );
    return r;
  }

  Future<void> _abrir() async {
    final fondo = await _pedirImporte('Abrir caja', ayuda: 'Efectivo con el que empiezas el turno (fondo de caja).');
    if (fondo == null) return;
    await _accion(() => supabase.from('turnos_caja').insert({
          'caja_id': _caja!['id'],
          'usuario_id': supabase.auth.currentUser!.id,
          'efectivo_inicial': fondo,
        }));
  }

  Future<void> _movimiento(String tipo) async {
    final ctrl = TextEditingController();
    final desc = TextEditingController();
    String? concepto = tipo == 'gasto' && _conceptos.isNotEmpty ? _conceptos.first['id'] as String : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tipo == 'gasto' ? 'Registrar gasto' : 'Registrar ingreso'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Importe', suffixText: '€'),
                ),
                const SizedBox(height: 12),
                if (tipo == 'gasto')
                  DropdownButtonFormField<String>(
                    initialValue: concepto,
                    decoration: const InputDecoration(labelText: 'Concepto'),
                    items: [
                      for (final c in _conceptos)
                        DropdownMenuItem(value: c['id'] as String, child: Text(c['nombre'] as String)),
                    ],
                    onChanged: (v) => setD(() => concepto = v),
                  ),
                if (tipo == 'gasto') const SizedBox(height: 12),
                TextField(controller: desc, decoration: const InputDecoration(labelText: 'Descripción (opcional)')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    final importe = leerImporte(ctrl.text);
    final texto = desc.text.trim();
    if (ok != true || importe == null || importe <= 0) return;
    await _accion(() => supabase.from('movimientos_caja').insert({
          'turno_id': _turno!['id'],
          'tipo': tipo,
          'concepto_id': concepto,
          'importe': importe,
          'descripcion': texto.isEmpty ? null : texto,
          'usuario_id': supabase.auth.currentUser!.id,
        }));
  }

  Future<void> _cerrar() async {
    final aviso = _mesasAbiertas > 0 ? 'Atención: hay $_mesasAbiertas mesas sin cobrar.\n' : '';
    final contado = await _pedirImporte('Cerrar caja',
        ayuda: '${aviso}Cuenta el efectivo del cajón. Esperado: ${euros(_efectivoEsperado)}');
    if (contado == null) return;
    final esperado = _efectivoEsperado;
    await _accion(() => supabase.from('turnos_caja').update({
          'cerrado_en': DateTime.now().toUtc().toIso8601String(),
          'efectivo_calculado': esperado,
          'efectivo_real': contado,
          'diferencia': contado - esperado,
          'estado': 'cerrado',
        }).eq('id', _turno!['id']));
    if (!mounted) return;
    final dif = contado - esperado;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(dif.abs() < 0.005
          ? 'Caja cerrada: cuadra al céntimo'
          : 'Caja cerrada con ${dif > 0 ? 'sobrante' : 'faltante'} de ${euros(dif.abs())}'),
    ));
  }

  Future<void> _accion(Future<dynamic> Function() f) async {
    try {
      await f();
      await _cargar();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AvisoSinConexion(textoError(_error), onReintentar: () {
        setState(() {
          _error = null;
          _cargando = true;
        });
        _cargar();
      });
    }

    if (_turno == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 56, color: C.gris),
            const SizedBox(height: 12),
            Text('${_caja!['nombre']} cerrada', style: titulo(26)),
            const SizedBox(height: 6),
            const Text('Abre la caja para empezar a cobrar.', style: TextStyle(color: C.gris)),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: _abrir, icon: const Icon(Icons.lock_open), label: const Text('Abrir caja')),
          ],
        ),
      );
    }

    final abierta = DateTime.parse(_turno!['abierto_en'] as String).toLocal();
    final hora = '${abierta.hour.toString().padLeft(2, '0')}:${abierta.minute.toString().padLeft(2, '0')}';

    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('${_caja!['nombre']} · abierta a las $hora · fondo ${euros(_turno!['efectivo_inicial'] as num)}',
                  style: const TextStyle(color: C.gris)),
            ),
            OutlinedButton.icon(
              onPressed: () => Impresion.abrirCajon().catchError((e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo abrir el cajón: $e')));
              }),
              icon: const Icon(Icons.point_of_sale),
              label: const Text('Abrir cajón'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: () => _movimiento('ingreso'), icon: const Icon(Icons.add), label: const Text('Ingreso')),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: () => _movimiento('gasto'), icon: const Icon(Icons.remove), label: const Text('Gasto')),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: C.tinta),
              onPressed: _cerrar,
              icon: const Icon(Icons.lock_outline),
              label: const Text('Cerrar caja'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            _Cifra('Ventas del turno', euros(_totalVentas), '$_tickets tickets', destacada: true),
            _Cifra('Efectivo', euros(_ventas['efectivo'] ?? 0), null),
            _Cifra('Tarjeta', euros(_ventas['tarjeta'] ?? 0), null),
            _Cifra('Bizum', euros(_ventas['bizum'] ?? 0), null),
            _Cifra('Efectivo esperado en cajón', euros(_efectivoEsperado),
                'Fondo + efectivo + ingresos − gastos'),
            _Cifra('Mesas sin cobrar', '$_mesasAbiertas', null),
          ],
        ),
        const SizedBox(height: 28),
        Text('Ingresos y gastos', style: titulo(20)),
        const SizedBox(height: 8),
        if (_movimientos.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Sin movimientos en este turno.', style: TextStyle(color: C.gris)),
          ),
        for (final m in _movimientos)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(m['tipo'] == 'gasto' ? Icons.arrow_upward : Icons.arrow_downward,
                color: m['tipo'] == 'gasto' ? C.naranja : C.verde),
            title: Text(((m['conceptos_gasto'] as Map?)?['nombre'] as String?) ??
                (m['tipo'] == 'gasto' ? 'Gasto' : 'Ingreso')),
            subtitle: m['descripcion'] == null ? null : Text(m['descripcion'] as String),
            trailing: Text('${m['tipo'] == 'gasto' ? '−' : '+'} ${euros(m['importe'] as num)}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }
}

class _Cifra extends StatelessWidget {
  const _Cifra(this.titulo_, this.valor, this.detalle, {this.destacada = false});
  final String titulo_;
  final String valor;
  final String? detalle;
  final bool destacada;

  @override
  Widget build(BuildContext context) {
    final fg = destacada ? C.sobreAccion : C.tinta;
    return Container(
      width: 250,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: destacada ? C.verde : C.blanco,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: destacada ? C.verde : C.borde),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo_, style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 13)),
          const SizedBox(height: 6),
          Text(valor, style: titulo(28, color: fg)),
          if (detalle != null) Text(detalle!, style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12)),
        ],
      ),
    );
  }
}
