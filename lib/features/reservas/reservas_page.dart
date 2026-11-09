import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';

const _dias = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const estadosReserva = {'confirmada': 'Confirmada', 'sentada': 'Ha llegado', 'no_vino': 'No vino', 'cancelada': 'Cancelada'};

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String horaReserva(Map<String, dynamic> r) => (r['hora'] as String).substring(0, 5);

/// Reservas de hoy (para marcar el plano de mesas). Sin conexión, lista vacía.
Future<Map<String, Map<String, dynamic>>> reservasDeHoyPorMesa() async {
  try {
    final hoy = DateTime.now();
    final filas = await supabase
        .from('reservas')
        .select('id, hora, nombre, personas, mesa_id')
        .eq('fecha', _iso(hoy))
        .eq('estado', 'confirmada')
        .not('mesa_id', 'is', null)
        .order('hora');
    final ahora = hoy.hour * 60 + hoy.minute;
    final r = <String, Map<String, dynamic>>{};
    for (final f in filas) {
      final p = (f['hora'] as String).split(':');
      // La próxima de cada mesa (las de hace más de 30 min se dan por pasadas)
      if (int.parse(p[0]) * 60 + int.parse(p[1]) < ahora - 30) continue;
      r.putIfAbsent(f['mesa_id'] as String, () => f);
    }
    return r;
  } catch (_) {
    return {};
  }
}

class ReservasPage extends StatefulWidget {
  const ReservasPage({super.key});

  @override
  State<ReservasPage> createState() => _ReservasPageState();
}

class _ReservasPageState extends State<ReservasPage> {
  DateTime _dia = DateTime.now();
  List<Map<String, dynamic>> _reservas = [];
  List<Map<String, dynamic>> _mesas = [];
  bool _cargando = true;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await online(() async {
        final r = await Future.wait<dynamic>([
          supabase.from('reservas').select().eq('fecha', _iso(_dia)).order('hora'),
          supabase.from('mesas').select('id, nombre, capacidad, salones(nombre)').eq('activo', true).order('nombre'),
        ]);
        _reservas = List<Map<String, dynamic>>.from(r[0] as List);
        _mesas = List<Map<String, dynamic>>.from(r[1] as List);
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

  void _irA(DateTime d) {
    setState(() {
      _dia = d;
      _cargando = true;
    });
    _cargar();
  }

  String? _mesa(String? id) => id == null ? null : _mesas.firstWhere((m) => m['id'] == id, orElse: () => {'nombre': '?'})['nombre'] as String;

  Future<void> _editar([Map<String, dynamic>? r]) async {
    try {
      exigirConexion();
      final datos = await mostrarPanel<Map<String, dynamic>>(
          context, (_) => _PanelReserva(reserva: r, dia: _dia, mesas: _mesas, ocupadas: _reservas));
      if (datos == null) return;
      if (datos['_borrar'] == true) {
        await supabase.from('reservas').update({'estado': 'cancelada'}).eq('id', r!['id']);
      } else if (r == null) {
        await supabase.from('reservas').insert(datos);
      } else {
        await supabase.from('reservas').update(datos).eq('id', r['id']);
      }
      if (datos['fecha'] != null && datos['fecha'] != _iso(_dia)) {
        _irA(DateTime.parse(datos['fecha'] as String));
      } else {
        await _cargar();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
  }

  Future<void> _estado(Map<String, dynamic> r, String estado) async {
    try {
      exigirConexion();
      await supabase.from('reservas').update({'estado': estado}).eq('id', r['id']);
      await _cargar();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    final hoy = DateTime.now();
    final esHoy = _iso(_dia) == _iso(hoy);
    final activas = _reservas.where((r) => r['estado'] != 'cancelada').toList();
    final personas = activas.where((r) => r['estado'] != 'no_vino').fold(0, (s, r) => s + (r['personas'] as int));
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(onPressed: () => _irA(_dia.subtract(const Duration(days: 1))), icon: const Icon(Icons.chevron_left)),
          InkWell(
            onTap: () async {
              final d = await showDatePicker(
                  context: context, initialDate: _dia, firstDate: DateTime(hoy.year - 1), lastDate: DateTime(hoy.year + 2));
              if (d != null) _irA(d);
            },
            child: Text('${esHoy ? 'Hoy, ' : ''}${_dias[_dia.weekday - 1]} ${_dia.day}/${_dia.month}', style: titulo(20)),
          ),
          IconButton(onPressed: () => _irA(_dia.add(const Duration(days: 1))), icon: const Icon(Icons.chevron_right)),
          if (!esHoy) TextButton(onPressed: () => _irA(hoy), child: const Text('Hoy')),
          FilledButton.icon(onPressed: _editar, icon: const Icon(Icons.add), label: const Text('Nueva reserva')),
        ]),
        const SizedBox(height: 6),
        Text('${activas.length} reservas · $personas personas', style: const TextStyle(color: C.gris)),
        const SizedBox(height: 14),
        if (_cargando)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (_reservas.isEmpty)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Sin reservas este día', style: TextStyle(color: C.gris)))),
        for (final r in _reservas) _fila(r),
      ],
    );
  }

  Widget _fila(Map<String, dynamic> r) {
    final estado = r['estado'] as String;
    final apagada = estado == 'cancelada' || estado == 'no_vino';
    final color = switch (estado) { 'sentada' => C.verde, 'confirmada' => C.reserva, _ => C.gris };
    return Opacity(
      opacity: apagada ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TarjetaFila(
          onTap: () => _editar(r),
          child: Row(children: [
            Container(
              width: 64,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Text(horaReserva(r), style: titulo(18, color: color)),
                Text('${r['personas']} pers.', style: TextStyle(fontSize: 11, color: color)),
              ]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r['nombre'] as String,
                    style: titulo(17).copyWith(decoration: estado == 'cancelada' ? TextDecoration.lineThrough : null)),
                Text(
                  [
                    estadosReserva[estado]!,
                    if (_mesa(r['mesa_id'] as String?) != null) 'Mesa ${_mesa(r['mesa_id'] as String?)}' else 'sin mesa',
                    if ((r['telefono'] as String?)?.isNotEmpty ?? false) r['telefono'],
                    if ((r['nota'] as String?)?.isNotEmpty ?? false) r['nota'],
                  ].join(' · '),
                  style: const TextStyle(color: C.gris, fontSize: 13),
                ),
              ]),
            ),
            if (estado == 'confirmada') ...[
              IconButton(tooltip: 'Ha llegado', onPressed: () => _estado(r, 'sentada'), icon: const Icon(Icons.how_to_reg, color: C.verde)),
              IconButton(tooltip: 'No vino', onPressed: () => _estado(r, 'no_vino'), icon: const Icon(Icons.person_off_outlined, color: C.gris)),
            ] else if (estado != 'cancelada')
              TextButton(onPressed: () => _estado(r, 'confirmada'), child: const Text('Deshacer')),
          ]),
        ),
      ),
    );
  }
}

class _PanelReserva extends StatefulWidget {
  const _PanelReserva({required this.reserva, required this.dia, required this.mesas, required this.ocupadas});
  final Map<String, dynamic>? reserva;
  final DateTime dia;
  final List<Map<String, dynamic>> mesas, ocupadas;

  @override
  State<_PanelReserva> createState() => _PanelReservaState();
}

class _PanelReservaState extends State<_PanelReserva> {
  late final r = widget.reserva;
  late DateTime _fecha = r == null ? widget.dia : DateTime.parse(r!['fecha'] as String);
  late TimeOfDay _hora = r == null
      ? const TimeOfDay(hour: 14, minute: 0)
      : TimeOfDay(hour: int.parse((r!['hora'] as String).substring(0, 2)), minute: int.parse((r!['hora'] as String).substring(3, 5)));
  late final _nombre = TextEditingController(text: r?['nombre'] as String?);
  late final _tel = TextEditingController(text: r?['telefono'] as String?);
  late final _nota = TextEditingController(text: r?['nota'] as String?);
  late int _personas = (r?['personas'] as int?) ?? 2;
  late String? _mesa = r?['mesa_id'] as String?;
  String? _err;

  /// Mesas con otra reserva a menos de 2 h de esta (aviso, no bloqueo).
  Set<String> get _choques {
    final m = _hora.hour * 60 + _hora.minute;
    return {
      for (final o in widget.ocupadas)
        if (o['id'] != r?['id'] && o['estado'] == 'confirmada' && o['mesa_id'] != null && o['fecha'] == _iso(_fecha))
          if ((int.parse((o['hora'] as String).substring(0, 2)) * 60 + int.parse((o['hora'] as String).substring(3, 5)) - m).abs() < 120)
            o['mesa_id'] as String,
    };
  }

  void _guardar() {
    if (_nombre.text.trim().isEmpty) return setState(() => _err = 'Escribe el nombre');
    Navigator.pop(context, {
      'fecha': _iso(_fecha),
      'hora': '${_hora.hour.toString().padLeft(2, '0')}:${_hora.minute.toString().padLeft(2, '0')}',
      'nombre': _nombre.text.trim(),
      'telefono': _tel.text.trim().isEmpty ? null : _tel.text.trim(),
      'personas': _personas,
      'mesa_id': _mesa,
      'nota': _nota.text.trim().isEmpty ? null : _nota.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final choques = _choques;
    final hoy = DateTime.now();
    return PanelLateral(
      encabezado: r == null ? 'Nueva reserva' : 'Reserva',
      boton: 'Guardar reserva',
      onBoton: _guardar,
      onBorrar: r == null || r!['estado'] == 'cancelada' ? null : () => Navigator.pop(context, {'_borrar': true}),
      textoBorrar: 'Cancelar reserva',
      cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(
                    context: context, initialDate: _fecha, firstDate: DateTime(hoy.year - 1), lastDate: DateTime(hoy.year + 2));
                if (d != null) setState(() => _fecha = d);
              },
              icon: const Icon(Icons.calendar_today),
              label: Text('${_fecha.day}/${_fecha.month}/${_fecha.year}'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final t = await showTimePicker(context: context, initialTime: _hora);
                if (t != null) setState(() => _hora = t);
              },
              icon: const Icon(Icons.schedule),
              label: Text(_hora.format(context)),
            ),
          ),
        ]),
        const EtiquetaCampo('Nombre'),
        TextField(controller: _nombre, autofocus: r == null, textCapitalization: TextCapitalization.words),
        const EtiquetaCampo('Teléfono'),
        TextField(controller: _tel, keyboardType: TextInputType.phone, decoration: const InputDecoration(hintText: 'Opcional')),
        const EtiquetaCampo('Personas'),
        Row(children: [
          IconButton.outlined(onPressed: _personas > 1 ? () => setState(() => _personas--) : null, icon: const Icon(Icons.remove)),
          SizedBox(width: 60, child: Text('$_personas', textAlign: TextAlign.center, style: titulo(24))),
          IconButton.outlined(onPressed: () => setState(() => _personas++), icon: const Icon(Icons.add)),
        ]),
        const EtiquetaCampo('Mesa'),
        DropdownButtonFormField<String?>(
          initialValue: _mesa,
          isExpanded: true,
          menuMaxHeight: 420,
          items: [
            const DropdownMenuItem(value: null, child: Text('Sin asignar')),
            for (final m in widget.mesas)
              DropdownMenuItem(
                value: m['id'] as String,
                child: Text(
                  '${m['nombre']} · ${(m['salones'] as Map?)?['nombre'] ?? ''}'
                  '${m['capacidad'] == null ? '' : ' · ${m['capacidad']} pax'}${choques.contains(m['id']) ? ' · ⚠ otra reserva cerca' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _mesa = v),
        ),
        if (_mesa != null && choques.contains(_mesa))
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Esa mesa tiene otra reserva a menos de 2 horas', style: TextStyle(color: C.naranja, fontWeight: FontWeight.w600)),
          ),
        const EtiquetaCampo('Nota'),
        TextField(controller: _nota, decoration: const InputDecoration(hintText: 'Cumpleaños, trona, terraza…')),
        if (_err != null) ...[
          const SizedBox(height: 10),
          Text(_err!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }
}
