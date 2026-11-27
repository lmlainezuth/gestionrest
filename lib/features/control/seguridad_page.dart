import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/modelos.dart' show euros;
import 'control_comun.dart';

/// Señales de que alguien intenta algo que no debe en este bar: PIN incorrectos y bloqueos,
/// intentos que el servidor rechazó, anulaciones y borrados por persona, descuadres de caja y
/// fichajes que llegaron tarde. Lo apunta la base de datos; nadie lo puede borrar desde la app.
class SeguridadPage extends StatefulWidget {
  const SeguridadPage({super.key});

  @override
  State<SeguridadPage> createState() => _SeguridadPageState();
}

class _SeguridadPageState extends State<SeguridadPage> {
  int _dias = 7;
  Map<String, dynamic>? _r;
  Map<String, String> _nombres = {};
  bool _cargando = true;
  String? _errorCarga;

  // A partir de aquí se marca en rojo
  static const _muchosPin = 10;

  static const _eventos = {
    'anulacion_denegada': 'Intentó anular una factura sin ser administrador',
    'usuario_ajeno': 'Intentó cambiar el PIN de un usuario de otro bar',
    'pin_otro_bar': 'No pudo cambiar el PIN de un empleado que también está en otro bar',
    'pin_bloqueado_bar': 'Entrada con PIN bloqueada 15 minutos en todo el bar (20 PIN incorrectos)',
    'pin_cambiado': 'Cambió su PIN',
  };

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await online(() async {
        final r = await Future.wait<dynamic>([
          supabase.rpc('resumen_seguridad', params: {'p_dias': _dias}),
          supabase.rpc('equipo_empresa'),
        ]);
        _r = Map<String, dynamic>.from(r[0] as Map);
        _nombres = {for (final p in r[1] as List) p['id'] as String: p['nombre'] as String};
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

  List<Map<String, dynamic>> _lista(String clave) =>
      [for (final x in (_r?[clave] as List?) ?? const []) Map<String, dynamic>.from(x as Map)];
  String _quien(Object? id) => _nombres[id] ?? (id == null ? 'Sistema' : 'Alguien que ya no está');
  String _cuando(Object? m) {
    final d = DateTime.parse(m as String).toLocal();
    return '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final pin = _lista('pin');
    final eventos = _lista('eventos');
    final control = _lista('control');
    final descuadres = _lista('descuadres');
    final tarde = _lista('fichajes_tarde');
    final alarmas = pin.where((p) => (p['fallidos'] as num) >= _muchosPin || (p['bloqueos'] as num) > 0).length +
        eventos.length +
        control.where((c) => c['tipo'] == 'cobro_fuera_turno').length;
    final ancho = MediaQuery.sizeOf(context).width;

    Widget tarjeta(String nombre, String vacio, List<Widget> filas) => Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(nombre, style: titulo(17)),
            const SizedBox(height: 8),
            if (filas.isEmpty) Text(vacio, style: const TextStyle(color: C.gris)) else ...filas,
          ]),
        );
    Widget fila(String texto, {String? sub, bool grave = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(grave ? Icons.warning_amber_rounded : Icons.circle, size: grave ? 18 : 8, color: grave ? rojo : C.gris),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(texto, style: TextStyle(fontWeight: grave ? FontWeight.w700 : FontWeight.w500)),
                if (sub != null) Text(sub, style: const TextStyle(color: C.gris, fontSize: 12)),
              ]),
            ),
          ]),
        );

    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
        children: [
          Row(children: [
            Expanded(
              child: Text(alarmas == 0 ? 'Todo en orden' : '$alarmas cosas para mirar',
                  style: titulo(24).copyWith(color: alarmas == 0 ? null : rojo)),
            ),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Hoy')),
                ButtonSegment(value: 7, label: Text('7 días')),
                ButtonSegment(value: 30, label: Text('30 días')),
              ],
              selected: {_dias},
              onSelectionChanged: (s) {
                setState(() {
                  _dias = s.first;
                  _cargando = true;
                });
                _cargar();
              },
            ),
          ]),
          const SizedBox(height: 4),
          const Text('Lo apunta la base de datos y no se puede borrar. Cada mañana llega un resumen por correo a la plataforma.',
              style: TextStyle(color: C.gris, fontSize: 12)),
          const SizedBox(height: 14),
          tarjeta('PIN incorrectos', 'Ningún PIN incorrecto.', [
            for (final p in pin)
              fila(
                '${_quien(p['usuario_id'])}: ${p['fallidos']} PIN incorrectos'
                '${(p['bloqueos'] as num) > 0 ? ' · ${p['bloqueos']} bloqueos' : ''}',
                sub: 'Último: ${_cuando(p['ultimo'])}. Muchos seguidos: alguien prueba PIN, o bloquea a esa persona a propósito.',
                grave: (p['fallidos'] as num) >= _muchosPin || (p['bloqueos'] as num) > 0,
              ),
          ]),
          tarjeta('Intentos rechazados', 'Ninguno.', [
            for (final e in eventos)
              fila('${_quien(e['usuario_id'])}: ${_eventos[e['tipo']] ?? e['tipo']}',
                  sub: [_cuando(e['momento']), if (e['detalle'] != null) e['detalle'] as String].join(' · '), grave: true),
          ]),
          tarjeta('Anulaciones, borrados y cobros fuera de turno', 'Nada en este periodo.', [
            for (final c in control)
              fila(
                '${_quien(c['usuario_id'])}: ${c['n']} × ${tiposAnulacion[c['tipo']]?.texto ?? c['tipo']}',
                sub: euros((c['importe'] as num).toDouble()),
                grave: c['tipo'] == 'cobro_fuera_turno' || colorAnulacion({'tipo': c['tipo']}) == rojo,
              ),
          ]),
          tarjeta('Cierres de caja que no cuadraron', 'Todos los cierres cuadraron (menos de 1 €).', [
            for (final d in descuadres)
              fila('${_quien(d['usuario_id'])}: ${euros((d['diferencia'] as num).toDouble())}',
                  sub: 'Cerró el ${_cuando(d['cerrado_en'])}', grave: ((d['diferencia'] as num).abs()) >= 20),
          ]),
          tarjeta('Fichajes que llegaron tarde', 'Ninguno.', [
            for (final f in tarde)
              fila('${_quien(f['usuario_id'])}: ${f['n']} fichajes sin internet que llegaron tarde',
                  sub: 'Revísalos en Equipo › Fichajes: la hora la puso el equipo, no el servidor.'),
          ]),
        ],
      ),
    );
  }
}
