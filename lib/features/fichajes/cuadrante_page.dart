import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import 'fichajes_comun.dart';

const _dias = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
const _rojo = Color(0xFFB3261E);
const _margen = 10; // minutos de cortesía al comparar con lo fichado

String _iso(DateTime d) => diaClave(d);
TimeOfDay _t(String s) => TimeOfDay(hour: int.parse(s.substring(0, 2)), minute: int.parse(s.substring(3, 5)));
String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
int _minTramo(Map<String, dynamic> c) {
  final a = _t(c['inicio'] as String), b = _t(c['fin'] as String);
  var m = (b.hour * 60 + b.minute) - (a.hour * 60 + a.minute);
  if (m <= 0) m += 24 * 60; // acaba al día siguiente
  return m;
}

/// Cuadrante semanal: horario de cada empleado comparado con lo que fichó.
class CuadrantePage extends StatefulWidget {
  const CuadrantePage({super.key});

  @override
  State<CuadrantePage> createState() => _CuadrantePageState();
}

class _CuadrantePageState extends State<CuadrantePage> {
  late DateTime _lunes = _inicioSemana(DateTime.now());
  List<Map<String, dynamic>> _equipo = [];
  List<Map<String, dynamic>> _turnos = [];
  List<Map<String, dynamic>> _fichajes = [];
  bool _cargando = true;
  String? _errorCarga;

  static DateTime _inicioSemana(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));
  DateTime _dia(int i) => DateTime(_lunes.year, _lunes.month, _lunes.day + i);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await online(() async {
        final r = await Future.wait<dynamic>([
          supabase.rpc('equipo_empresa'),
          supabase.from('cuadrante').select().gte('fecha', _iso(_lunes)).lte('fecha', _iso(_dia(6))).order('inicio'),
          supabase
              .from('fichajes')
              .select()
              .gte('momento', _dia(-1).toUtc().toIso8601String())
              .lt('momento', _dia(8).toUtc().toIso8601String())
              .order('momento'),
        ]);
        _equipo = [for (final p in r[0] as List) if (p['activo'] == true) Map<String, dynamic>.from(p as Map)];
        _turnos = List<Map<String, dynamic>>.from(r[1] as List);
        _fichajes = vigentes(List<Map<String, dynamic>>.from(r[2] as List));
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

  void _semana(int delta) {
    setState(() {
      _lunes = _dia(7 * delta);
      _cargando = true;
    });
    _cargar();
  }

  List<Map<String, dynamic>> _tramos(String usuario, DateTime d) =>
      [for (final c in _turnos) if (c['usuario_id'] == usuario && c['fecha'] == _iso(d)) c];

  Map<String, Jornada> _jornadas(String usuario) => {
        for (final j in jornadas([for (final f in _fichajes) if (f['usuario_id'] == usuario) f], ahora: DateTime.now()))
          j.dia: j,
      };

  Future<void> _editar(Map<String, dynamic> persona, DateTime d) async {
    try {
      exigirConexion();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
      return;
    }
    final tramos = await mostrarPanel<List<(TimeOfDay, TimeOfDay)>>(
      context,
      (_) => _PanelDia(
        titulo: '${persona['nombre']} · ${_dias[d.weekday - 1]} ${d.day}/${d.month}',
        tramos: [for (final c in _tramos(persona['id'] as String, d)) (_t(c['inicio'] as String), _t(c['fin'] as String))],
      ),
    );
    if (tramos == null) return;
    try {
      await supabase.from('cuadrante').delete().eq('usuario_id', persona['id']).eq('fecha', _iso(d));
      if (tramos.isNotEmpty) {
        await supabase.from('cuadrante').insert([
          for (final t in tramos) {'usuario_id': persona['id'], 'fecha': _iso(d), 'inicio': _hhmm(t.$1), 'fin': _hhmm(t.$2)},
        ]);
      }
      await _cargar();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
  }

  /// Copia la semana anterior en los días que aún están vacíos.
  Future<void> _copiarAnterior() async {
    try {
      exigirConexion();
      final ant = DateTime(_lunes.year, _lunes.month, _lunes.day - 7);
      final previos = List<Map<String, dynamic>>.from(await supabase
          .from('cuadrante')
          .select()
          .gte('fecha', _iso(ant))
          .lte('fecha', _iso(DateTime(ant.year, ant.month, ant.day + 6))));
      final ocupados = {for (final c in _turnos) '${c['usuario_id']}|${c['fecha']}'};
      final nuevos = <Map<String, dynamic>>[];
      for (final c in previos) {
        final f = DateTime.parse(c['fecha'] as String);
        final destino = _iso(DateTime(f.year, f.month, f.day + 7));
        if (ocupados.contains('${c['usuario_id']}|$destino')) continue;
        nuevos.add({'usuario_id': c['usuario_id'], 'fecha': destino, 'inicio': c['inicio'], 'fin': c['fin'], 'nota': c['nota']});
      }
      if (nuevos.isEmpty) throw 'No hay nada que copiar (la semana anterior está vacía o esta ya está hecha)';
      await supabase.from('cuadrante').insert(nuevos);
      await _cargar();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is String ? e : textoError(e))));
    }
  }

  Future<void> _copiarTexto() async {
    final lineas = ['Cuadrante semana ${_lunes.day}/${_lunes.month} – ${_dia(6).day}/${_dia(6).month}'];
    for (final p in _equipo) {
      final dias = [
        for (var i = 0; i < 7; i++)
          if (_tramos(p['id'] as String, _dia(i)).isNotEmpty)
            '${_dias[i]} ${_tramos(p['id'] as String, _dia(i)).map((c) => '${(c['inicio'] as String).substring(0, 5)}-${(c['fin'] as String).substring(0, 5)}').join(' y ')}',
      ];
      lineas.add('\n${p['nombre']}: ${dias.isEmpty ? 'libre' : dias.join(', ')}');
    }
    await Clipboard.setData(ClipboardData(text: lineas.join()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cuadrante copiado: pégalo en el grupo de WhatsApp')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(tooltip: 'Semana anterior', onPressed: () => _semana(-1), icon: const Icon(Icons.chevron_left)),
          Text('${_lunes.day}/${_lunes.month} – ${_dia(6).day}/${_dia(6).month}/${_dia(6).year}', style: titulo(18)),
          IconButton(tooltip: 'Semana siguiente', onPressed: () => _semana(1), icon: const Icon(Icons.chevron_right)),
          OutlinedButton.icon(onPressed: _copiarAnterior, icon: const Icon(Icons.content_copy), label: const Text('Repetir semana anterior')),
          OutlinedButton.icon(onPressed: _copiarTexto, icon: const Icon(Icons.share_outlined), label: const Text('Copiar para WhatsApp')),
        ]),
        const SizedBox(height: 6),
        const Text('Toca un día para poner o cambiar el horario. Verde: fichó a su hora · naranja: llegó tarde o salió antes · '
            'rojo: no fichó.', style: TextStyle(color: C.gris, fontSize: 13)),
        const SizedBox(height: 14),
        if (_cargando)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else
          for (final p in _equipo) _persona(p),
      ],
    );
  }

  Widget _persona(Map<String, dynamic> p) {
    final id = p['id'] as String;
    final js = _jornadas(id);
    var plan = 0, hecho = 0;
    for (var i = 0; i < 7; i++) {
      plan += _tramos(id, _dia(i)).fold(0, (s, c) => s + _minTramo(c));
      hecho += js[_iso(_dia(i))]?.minutos ?? 0;
    }
    final dif = hecho - plan;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(p['nombre'] as String, style: titulo(17)),
          Text('Plan ${horasMin(plan)} · fichado ${horasMin(hecho)}', style: const TextStyle(color: C.gris)),
          if (plan > 0 && dif.abs() >= _margen)
            Text('${dif > 0 ? '+' : '−'}${horasMin(dif.abs())}',
                style: TextStyle(fontWeight: FontWeight.w700, color: dif > 0 ? C.naranja : _rojo)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [for (var i = 0; i < 7; i++) _celda(p, _dia(i), js[_iso(_dia(i))])]),
      ]),
    );
  }

  Widget _celda(Map<String, dynamic> p, DateTime d, Jornada? j) {
    final tramos = _tramos(p['id'] as String, d);
    final hoy = DateTime.now();
    final pasado = d.isBefore(DateTime(hoy.year, hoy.month, hoy.day));
    final esHoy = _iso(d) == _iso(hoy);
    String? estado;
    var color = C.gris;
    if (tramos.isNotEmpty) {
      final ini = _t(tramos.first['inicio'] as String);
      final fin = _t(tramos.last['fin'] as String);
      if (j == null || j.entrada == null) {
        if (pasado || (esHoy && hoy.hour * 60 + hoy.minute > ini.hour * 60 + ini.minute + _margen)) {
          estado = 'No fichó';
          color = _rojo;
        }
      } else {
        final tarde = (j.entrada!.hour * 60 + j.entrada!.minute) - (ini.hour * 60 + ini.minute);
        final finMin = fin.hour * 60 + fin.minute;
        final antes = j.salida == null ? 0 : finMin - (j.salida!.hour * 60 + j.salida!.minute);
        if (tarde > _margen) {
          estado = 'Tarde $tarde min';
          color = C.naranja;
        } else if (antes > _margen && finMin > ini.hour * 60 + ini.minute) {
          estado = 'Salió $antes min antes';
          color = C.naranja;
        } else {
          estado = j.salida == null ? 'Trabajando' : 'OK';
          color = C.verde;
        }
      }
    } else if (j != null) {
      estado = 'Fichó sin turno';
      color = C.naranja;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _editar(p, d),
      child: Container(
        width: 118,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: esHoy ? C.crema : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: estado == null ? C.borde : color, width: estado == null ? 1 : 2),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_dias[d.weekday - 1]} ${d.day}', style: const TextStyle(fontWeight: FontWeight.w700)),
          if (tramos.isEmpty)
            const Text('Libre', style: TextStyle(color: C.gris))
          else
            for (final c in tramos)
              Text('${(c['inicio'] as String).substring(0, 5)}–${(c['fin'] as String).substring(0, 5)}'),
          if (j != null && j.entrada != null)
            Text('Fichó ${hora(j.entrada!)}${j.salida == null ? '' : '–${hora(j.salida!)}'}',
                style: const TextStyle(color: C.gris, fontSize: 11)),
          if (estado != null) Text(estado, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// Horario de un día: uno o varios tramos (turno partido). Vacío = libre.
class _PanelDia extends StatefulWidget {
  const _PanelDia({required this.titulo, required this.tramos});
  final String titulo;
  final List<(TimeOfDay, TimeOfDay)> tramos;

  @override
  State<_PanelDia> createState() => _PanelDiaState();
}

class _PanelDiaState extends State<_PanelDia> {
  late final _tramos = [...widget.tramos];

  Future<TimeOfDay?> _pedir(TimeOfDay inicial) => showTimePicker(context: context, initialTime: inicial);

  Future<void> _anadir() async {
    final ini = await _pedir(_tramos.isEmpty ? const TimeOfDay(hour: 10, minute: 0) : _tramos.last.$2);
    if (ini == null) return;
    final fin = await _pedir(TimeOfDay(hour: (ini.hour + 6) % 24, minute: ini.minute));
    if (fin == null || fin == ini) return;
    setState(() => _tramos.add((ini, fin)));
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: widget.titulo,
        boton: _tramos.isEmpty ? 'Guardar como libre' : 'Guardar horario',
        onBoton: () => Navigator.pop(context, _tramos),
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_tramos.isEmpty) const Text('Día libre.', style: TextStyle(color: C.gris)),
          for (final t in _tramos)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: Text('${_hhmm(t.$1)} – ${_hhmm(t.$2)}', style: titulo(18)),
              trailing: IconButton(
                tooltip: 'Quitar',
                onPressed: () => setState(() => _tramos.remove(t)),
                icon: const Icon(Icons.close, color: _rojo),
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _anadir,
            icon: const Icon(Icons.add),
            label: Text(_tramos.isEmpty ? 'Poner horario' : 'Añadir otro tramo (turno partido)'),
          ),
          const SizedBox(height: 8),
          const Text('Si la hora de fin es menor que la de inicio, el turno acaba al día siguiente.',
              style: TextStyle(color: C.gris, fontSize: 13)),
        ]),
      );
}
