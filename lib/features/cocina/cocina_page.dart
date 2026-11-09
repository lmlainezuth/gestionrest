import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../carta/alergenos.dart';

// Paleta oscura de la pantalla de cocina
const _fondo = Color(0xFF121211);
const _tarjeta = Color(0xFF1E1D1B);
const _linea = Color(0xFF2A2926);
const _texto = Color(0xFFF3F1EC);
const _apagado = Color(0xFFB5B0A5);
const _amarillo = Color(0xFFE8B53A);
const _menta = Color(0xFF7FD1BE);

const _kCopia = 'offline_cocina';

const _cursos = {'ya': 'Ya', '1': '1.º', '2': '2.º', 'postre': 'Postre'};

/// Pantalla de comandas para cocina y barra (KDS), en tiempo real.
class CocinaPage extends StatefulWidget {
  const CocinaPage({super.key, this.onSalir});
  final VoidCallback? onSalir;

  @override
  State<CocinaPage> createState() => _CocinaPageState();
}

class _CocinaPageState extends State<CocinaPage> {
  String _vista = 'Cocina'; // Cocina | Barra | Listos
  Map<String, String> _areas = {}; // id -> nombre
  List<Map<String, dynamic>> _lineas = [];
  bool _cargando = true;
  String? _error;
  RealtimeChannel? _canal;
  Timer? _reloj;
  Timer? _espera;

  @override
  void initState() {
    super.initState();
    _iniciar();
  }

  Future<void> _iniciar() async {
    // Primero lo guardado en el equipo (la pantalla aparece al instante), luego lo del servidor
    try {
      final p = await SharedPreferences.getInstance();
      final a = p.getString('${_kCopia}_areas'), c = p.getString(_kCopia);
      if (a != null) _areas = Map<String, String>.from(jsonDecode(a) as Map);
      if (c != null) _lineas = [for (final l in jsonDecode(c) as List) Map<String, dynamic>.from(l as Map)];
      if (c != null && mounted) setState(() => _cargando = false);
    } catch (_) {}
    try {
      final areas = await supabase.from('areas_preparacion').select('id, nombre');
      _areas = {for (final a in areas) a['id'] as String: a['nombre'] as String};
      SharedPreferences.getInstance().then((p) => p.setString('${_kCopia}_areas', jsonEncode(_areas))).ignore();
    } catch (_) {
      // Sin internet: se queda con las zonas guardadas
    }
    await _cargar();
    _canal = supabase
        .channel('cocina')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'pedido_detalle',
          callback: (_) => _programarCarga(),
        )
        .subscribe();
    // Refresca los temporizadores y recarga por si se perdió algún aviso
    _reloj = Timer.periodic(const Duration(seconds: 30), (_) => _cargar());
  }

  /// Agrupa varios avisos seguidos en una sola recarga.
  void _programarCarga() {
    _espera?.cancel();
    _espera = Timer(const Duration(milliseconds: 300), _cargar);
  }

  Future<void> _cargar() async {
    try {
      final haceUnaHora = DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String();
      final hace15 = DateTime.now().toUtc().subtract(const Duration(minutes: 15)).toIso8601String();
      final filas = await supabase
          .from('pedido_detalle')
          .select('id, pedido_id, descripcion, cantidad, nota, curso, estado_cocina, en_espera, '
              'area_id, creado_en, listo_en, anulado_motivo, productos(alergenos), '
              'pedidos!inner(id, numero, tipo, nombre_llevar, estado, mesas(nombre))')
          .neq('pedidos.estado', 'anulado')
          .or('estado_cocina.in.(pendiente,preparando),'
              'and(estado_cocina.eq.listo,listo_en.gte.$haceUnaHora),'
              'and(estado_cocina.eq.anulado,anulado_en.gte.$hace15)')
          .order('creado_en');
      _lineas = List<Map<String, dynamic>>.from(filas);
      _error = null;
      // Copia para seguir viendo las comandas si se va internet
      SharedPreferences.getInstance().then((p) => p.setString(_kCopia, jsonEncode(_lineas))).ignore();
    } catch (e) {
      _error = '$e';
      if (_lineas.isEmpty) {
        try {
          final copia = (await SharedPreferences.getInstance()).getString(_kCopia);
          if (copia != null) {
            _lineas = [for (final l in jsonDecode(copia) as List) Map<String, dynamic>.from(l as Map)];
          }
        } catch (_) {}
      }
    }
    if (mounted) setState(() => _cargando = false);
  }

  @override
  void dispose() {
    _reloj?.cancel();
    _espera?.cancel();
    if (_canal != null) supabase.removeChannel(_canal!);
    super.dispose();
  }

  String _areaDe(Map<String, dynamic> l) => _areas[l['area_id']] ?? 'Cocina';

  Future<void> _cambiar(List<Map<String, dynamic>> lineas, String estado) async {
    final ids = lineas.map((l) => l['id']).toList();
    if (ids.isEmpty) return;
    try {
      await supabase.from('pedido_detalle').update({
        'estado_cocina': estado,
        if (estado == 'listo') 'listo_en': DateTime.now().toUtc().toIso8601String(),
      }).inFilter('id', ids);
      await _cargar();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo actualizar: $e')));
      }
    }
  }

  /// Comandas (una por pedido) de la vista actual.
  List<_Comanda> _comandas() {
    final porPedido = <String, List<Map<String, dynamic>>>{};
    for (final l in _lineas) {
      final enVista = _vista == 'Listos'
          ? l['estado_cocina'] == 'listo'
          : l['estado_cocina'] != 'listo' && _areaDe(l) == _vista;
      if (enVista) porPedido.putIfAbsent(l['pedido_id'] as String, () => []).add(l);
    }
    final lista = porPedido.values.map(_Comanda.new).toList()
      ..sort((a, b) => a.desde.compareTo(b.desde));
    return _vista == 'Listos' ? lista.reversed.toList() : lista;
  }

  int _cuenta(String vista) {
    final pedidos = <String>{};
    for (final l in _lineas) {
      final ok = vista == 'Listos'
          ? l['estado_cocina'] == 'listo'
          : !['listo', 'anulado'].contains(l['estado_cocina']) && l['en_espera'] != true && _areaDe(l) == vista;
      if (ok) pedidos.add(l['pedido_id'] as String);
    }
    return pedidos.length;
  }

  @override
  Widget build(BuildContext context) {
    final ahora = TimeOfDay.now();
    final comandas = _comandas();

    return Container(
      color: _fondo,
      child: Column(
        children: [
          Container(
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _linea))),
            child: Row(
              children: [
                Text('Cocina', style: titulo(26, color: _texto)),
                const SizedBox(width: 20),
                for (final v in ['Cocina', 'Barra', 'Listos'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _Pestana(
                      texto: '$v · ${_cuenta(v)}',
                      activa: v == _vista,
                      onTap: () => setState(() => _vista = v),
                    ),
                  ),
                const Spacer(),
                if (_error != null)
                  const Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: Text('Sin internet: comandas de la última vez. Lo nuevo sale por la impresora de cocina',
                        style: TextStyle(color: _amarillo)),
                  ),
                Text('${ahora.hour.toString().padLeft(2, '0')}:${ahora.minute.toString().padLeft(2, '0')}',
                    style: titulo(28, color: _texto)),
                if (widget.onSalir != null) ...[
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: 'Cerrar sesión',
                    onPressed: widget.onSalir,
                    icon: const Icon(Icons.logout, color: _apagado),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : comandas.isEmpty
                    ? Center(
                        child: Text(_vista == 'Listos' ? 'Nada listo en la última hora' : 'Sin comandas pendientes',
                            style: titulo(22, color: _apagado, peso: FontWeight.w500)),
                      )
                    : GridView.extent(
                        maxCrossAxisExtent: 320,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.78,
                        padding: const EdgeInsets.all(20),
                        children: [
                          for (final c in comandas)
                            _TarjetaComanda(
                              comanda: c,
                              vistaListos: _vista == 'Listos',
                              onCambiar: _cambiar,
                            ),
                        ],
                      ),
          ),
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: _linea))),
            child: const Row(
              children: [
                _Leyenda('Menos de 10 min', _linea),
                SizedBox(width: 24),
                _Leyenda('10–15 min', _amarillo),
                SizedBox(width: 24),
                _Leyenda('Más de 15 min', C.naranja),
                Spacer(),
                Text('Toca un plato para cambiar su estado', style: TextStyle(color: _apagado, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Las líneas de un pedido que se ven en una tarjeta.
class _Comanda {
  _Comanda(this.lineas);
  final List<Map<String, dynamic>> lineas;

  Map<String, dynamic> get pedido => lineas.first['pedidos'] as Map<String, dynamic>;
  List<Map<String, dynamic>> get activas => lineas.where((l) => l['en_espera'] != true).toList();
  List<Map<String, dynamic>> get enEspera => lineas.where((l) => l['en_espera'] == true).toList();

  DateTime get desde => lineas
      .map((l) => DateTime.parse(l['creado_en'] as String))
      .reduce((a, b) => a.isBefore(b) ? a : b);

  String get titulo {
    final mesa = pedido['mesas'] as Map<String, dynamic>?;
    if (mesa != null) return 'Mesa ${mesa['nombre']}';
    final nombre = pedido['nombre_llevar'] as String?;
    return nombre == null ? 'Para llevar #${pedido['numero']}' : 'Llevar · $nombre';
  }
}

class _TarjetaComanda extends StatelessWidget {
  const _TarjetaComanda({required this.comanda, required this.vistaListos, required this.onCambiar});
  final _Comanda comanda;
  final bool vistaListos;
  final Future<void> Function(List<Map<String, dynamic>>, String) onCambiar;

  @override
  Widget build(BuildContext context) {
    final minutos = DateTime.now().difference(comanda.desde).inMinutes;
    final (cabecera, textoCab) = vistaListos
        ? (_menta, _fondo)
        : minutos >= 15
            ? (C.naranja, _fondo)
            : minutos >= 10
                ? (_amarillo, _fondo)
                : (_linea, _texto);
    final activas = comanda.activas;
    final pendientes = activas.where((l) => l['estado_cocina'] == 'pendiente').toList();
    final preparando = activas.where((l) => l['estado_cocina'] == 'preparando').toList();

    return Container(
      decoration: BoxDecoration(
        color: _tarjeta,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cabecera == _linea ? const Color(0xFF3A3934) : cabecera, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: cabecera,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                Expanded(child: Text(comanda.titulo, style: titulo(22, color: textoCab))),
                Text('${minutos.toString().padLeft(2, '0')} min', style: titulo(22, color: textoCab)),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final l in activas) _Plato(linea: l, onCambiar: onCambiar),
                if (comanda.enEspera.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Divider(color: _linea),
                  for (final l in comanda.enEspera)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        '${(l['cantidad'] as num).toStringAsFixed(0)}× ${l['descripcion']} · ${_cursos[l['curso']]} en espera',
                        style: const TextStyle(color: Color(0xFF7A766D), fontSize: 14),
                      ),
                    ),
                ],
              ],
            ),
          ),
          if (!vistaListos && (pendientes.isNotEmpty || preparando.isNotEmpty))
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                height: 52,
                child: pendientes.isNotEmpty
                    ? FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _texto, foregroundColor: _fondo),
                        onPressed: () => onCambiar(pendientes, 'preparando'),
                        child: const Text('Empezar'),
                      )
                    : FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _menta, foregroundColor: _fondo),
                        onPressed: () => onCambiar(preparando, 'listo'),
                        child: const Text('Listo para servir'),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Plato extends StatelessWidget {
  const _Plato({required this.linea, required this.onCambiar});
  final Map<String, dynamic> linea;
  final Future<void> Function(List<Map<String, dynamic>>, String) onCambiar;

  @override
  Widget build(BuildContext context) {
    final estado = linea['estado_cocina'] as String;
    final al = (((linea['productos'] as Map?)?['alergenos'] as List?) ?? []).cast<String>();
    final nota = linea['nota'] as String?;
    final siguiente = switch (estado) { 'pendiente' => 'preparando', 'preparando' => 'listo', _ => 'pendiente' };
    final anulado = estado == 'anulado';
    final marca = switch (estado) {
      'anulado' => const Icon(Icons.cancel, color: Color(0xFFFF6B5B), size: 20),
      'preparando' => const Icon(Icons.local_fire_department, color: _amarillo, size: 20),
      'listo' => const Icon(Icons.check_circle, color: _menta, size: 20),
      _ => const Icon(Icons.radio_button_unchecked, color: _apagado, size: 20),
    };

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: anulado ? null : () => onCambiar([linea], siguiente),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              child: Text((linea['cantidad'] as num).toStringAsFixed(0), style: titulo(22, color: _texto)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(linea['descripcion'] as String,
                      style: TextStyle(
                        color: _texto,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        decoration: estado == 'listo' || anulado ? TextDecoration.lineThrough : null,
                      )),
                  if (anulado)
                    Text('ANULADO · ${linea['anulado_motivo'] ?? ''}',
                        style: const TextStyle(color: Color(0xFFFF6B5B), fontSize: 14, fontWeight: FontWeight.w700))
                  else
                    Text(_cursos[linea['curso']] ?? '', style: const TextStyle(color: _apagado, fontSize: 12)),
                  if (nota != null && nota.isNotEmpty)
                    Text(nota, style: const TextStyle(color: Color(0xFFF2B183), fontSize: 15)),
                  if (al.isNotEmpty)
                    Text('Alérgenos: ${al.map((a) => alergenos[a] ?? a).join(', ')}',
                        style: const TextStyle(color: Color(0xFFF2B183), fontSize: 13)),
                ],
              ),
            ),
            marca,
          ],
        ),
      ),
    );
  }
}

class _Pestana extends StatelessWidget {
  const _Pestana({required this.texto, required this.activa, required this.onTap});
  final String texto;
  final bool activa;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: activa ? _texto : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: activa ? _texto : const Color(0xFF3A3934))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: Text(texto,
                style: TextStyle(color: activa ? _fondo : _texto, fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
      );
}

class _Leyenda extends StatelessWidget {
  const _Leyenda(this.texto, this.color);
  final String texto;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 8),
          Text(texto, style: const TextStyle(color: _apagado, fontSize: 13)),
        ],
      );
}
