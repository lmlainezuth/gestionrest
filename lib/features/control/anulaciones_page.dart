import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/modelos.dart' show euros;
import 'control_comun.dart';

const _dias = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];

/// Quién anuló qué y cuándo, día a día. Lo apunta la base de datos (no se puede borrar).
class AnulacionesPage extends StatefulWidget {
  const AnulacionesPage({super.key});

  @override
  State<AnulacionesPage> createState() => _AnulacionesPageState();
}

class _AnulacionesPageState extends State<AnulacionesPage> {
  late DateTime _lunes = _inicioSemana(DateTime.now()); // el día que se está viendo (antes era el lunes de la semana)
  List<Map<String, dynamic>> _lista = [];
  List<Map<String, dynamic>> _anterior = [];
  Map<String, String> _nombres = {};
  String? _persona;
  bool _cargando = true;
  String? _errorCarga;

  static DateTime _inicioSemana(DateTime d) => DateTime(d.year, d.month, d.day); // ahora: inicio del día
  DateTime _mas(int dias) => DateTime(_lunes.year, _lunes.month, _lunes.day + dias);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await online(() async {
        final r = await Future.wait<dynamic>([
          supabase.from('registro_anulaciones').select()
              .gte('momento', _lunes.toUtc().toIso8601String()).lt('momento', _mas(1).toUtc().toIso8601String())
              .order('momento', ascending: false),
          supabase.from('registro_anulaciones').select('importe')
              .gte('momento', _mas(-1).toUtc().toIso8601String()).lt('momento', _lunes.toUtc().toIso8601String()),
          supabase.rpc('equipo_empresa'),
        ]);
        _lista = List<Map<String, dynamic>>.from(r[0] as List);
        _anterior = List<Map<String, dynamic>>.from(r[1] as List);
        _nombres = {for (final p in r[2] as List) p['id'] as String: p['nombre'] as String};
      });
      if (mounted) {
        setState(() {
          _cargando = false;
          _errorCarga = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorCarga = textoError(e);
          _cargando = false;
        });
      }
    }
  }

  void _semana(int d) {
    setState(() {
      _lunes = _mas(d);
      _persona = null;
      _cargando = true;
    });
    _cargar();
  }

  double _n(Object? v) => (v as num?)?.toDouble() ?? 0;
  String _quien(Map<String, dynamic> a) => _nombres[a['usuario_id']] ?? 'Sistema';

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    final total = _lista.fold(0.0, (s, a) => s + _n(a['importe']));
    final totalAnt = _anterior.fold(0.0, (s, a) => s + _n(a['importe']));
    final porPersona = <String, (int, double, int)>{}; // nº, importe, graves
    for (final a in _lista) {
      final p = porPersona[_quien(a)] ?? (0, 0.0, 0);
      porPersona[_quien(a)] = (p.$1 + 1, p.$2 + _n(a['importe']), p.$3 + (colorAnulacion(a) == rojo ? 1 : 0));
    }
    final orden = porPersona.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    final visibles = _persona == null ? _lista : _lista.where((a) => _quien(a) == _persona).toList();
    final ancho = MediaQuery.sizeOf(context).width;

    final porDia = <String, List<Map<String, dynamic>>>{};
    for (final a in visibles) {
      final d = DateTime.parse(a['momento'] as String).toLocal();
      porDia.putIfAbsent('${_dias[d.weekday - 1]} ${d.day}/${d.month}', () => []).add(a);
    }

    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Row(children: [
          IconButton(tooltip: 'Día anterior', onPressed: () => _semana(-1), icon: const Icon(Icons.chevron_left)),
          Text('${_dias[_lunes.weekday - 1]} ${_lunes.day}/${_lunes.month}', style: titulo(18)),
          IconButton(
            tooltip: 'Día siguiente',
            onPressed: _mas(1).isAfter(DateTime.now()) ? null : () => _semana(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ]),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_lista.length} anulaciones · ${euros(total)}', style: titulo(24)),
            Text(
              'Día anterior: ${_anterior.length} · ${euros(totalAnt)}'
              '${totalAnt > 0 && total > totalAnt * 1.5 ? '  ▲ suben mucho' : ''}',
              style: TextStyle(color: totalAnt > 0 && total > totalAnt * 1.5 ? rojo : C.gris),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in orden)
                FilterChip(
                  selected: _persona == e.key,
                  onSelected: (s) => setState(() => _persona = s ? e.key : null),
                  label: Text('${e.key}: ${e.value.$1} · ${euros(e.value.$2)}${e.value.$3 > 0 ? ' · ${e.value.$3} graves' : ''}'),
                  avatar: e.value.$3 > 0 ? const Icon(Icons.warning_amber_rounded, color: rojo, size: 18) : null,
                ),
            ]),
          ]),
        ),
        const SizedBox(height: 8),
        const Text('Rojo: algo ya cobrado, facturado o borrado · naranja: plato ya preparado o servido.',
            style: TextStyle(color: C.gris, fontSize: 12)),
        const SizedBox(height: 12),
        if (_cargando)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (visibles.isEmpty)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Ninguna anulación este día', style: TextStyle(color: C.gris))))
        else
          for (final d in porDia.entries) ...[
            Padding(padding: const EdgeInsets.fromLTRB(4, 12, 0, 6), child: Text(d.key, style: titulo(16))),
            for (final a in d.value) _fila(a),
          ],
      ],
    );
  }

  Widget _fila(Map<String, dynamic> a) {
    final t = tiposAnulacion[a['tipo']]!;
    final color = colorAnulacion(a);
    final cant = _n(a['cantidad']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
      color: C.blanco,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color == C.gris ? C.borde : color),
      ),
      child: ListTile(
        leading: Icon(t.icono, color: color),
        title: Text('${cant > 0 ? '${cant % 1 == 0 ? cant.toStringAsFixed(0) : cant} × ' : ''}${a['descripcion'] ?? t.texto}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text([
          hhmm(DateTime.parse(a['momento'] as String).toLocal()),
          t.texto,
          _quien(a),
          ?a['mesa'] as String?,
          if (estadosCocina[a['estado_cocina']] != null) estadosCocina[a['estado_cocina']]!,
          if ((a['motivo'] as String?)?.isNotEmpty ?? false) '“${a['motivo']}”',
        ].join(' · ')),
        trailing: Text(euros(_n(a['importe'])), style: titulo(16, color: color == C.gris ? C.tinta : color)),
      ),
      ),
    );
  }
}
