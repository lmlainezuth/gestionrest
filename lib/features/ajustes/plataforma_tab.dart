import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../control/control_comun.dart' show rojo;
import '../ticketbai/modelos.dart' show euros;

/// Seguridad de TODOS los bares, solo para programadores: qué bar tiene PIN incorrectos, intentos
/// rechazados o cobros raros, cuentas creadas sin bar, inicios de sesión y tamaño de la base.
/// El aviso diario por correo (función alertas-seguridad) cuenta lo mismo de las últimas 24 horas.
class PlataformaTab extends StatefulWidget {
  const PlataformaTab({super.key});

  @override
  State<PlataformaTab> createState() => _PlataformaTabState();
}

class _PlataformaTabState extends State<PlataformaTab> {
  int _dias = 7;
  Map<String, dynamic>? _r;
  bool _cargando = true;
  String? _errorCarga;

  static const _tipos = {
    'pin_bloqueado': 'Bloqueo por PIN',
    'anulacion_denegada': 'Anulación intentada sin ser administrador',
    'usuario_ajeno': 'PIN de un usuario de otro bar',
    'pin_otro_bar': 'PIN de un empleado que está en otro bar',
  };

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await online(() async {
        _r = Map<String, dynamic>.from(await supabase.rpc('resumen_plataforma', params: {'p_dias': _dias}) as Map);
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
  int _n(Object? v) => (v as num?)?.toInt() ?? 0;
  String _fecha(Object? m) {
    if (m == null) return 'nunca';
    final d = DateTime.parse(m as String).toLocal();
    return '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final bares = _lista('bares');
    final sinBar = _lista('cuentas_sin_bar');
    final eventos = _lista('eventos');
    final accesos = _r?['accesos'] == null ? null : _lista('accesos');
    final ips = _r?['ips'] == null ? null : _lista('ips');
    final bytes = _n(_r?['base_bytes']), limite = _n(_r?['base_limite']);
    final uso = limite == 0 ? 0.0 : bytes / limite;
    final alarmas = bares.fold(0, (s, b) => s + _n(b['alarmas'])) + sinBar.length;
    final ancho = MediaQuery.sizeOf(context).width;

    Widget tarjeta(String nombre, Widget contenido) => Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(nombre, style: titulo(17)),
            const SizedBox(height: 8),
            contenido,
          ]),
        );
    Widget cifra(String etiqueta, String valor, {bool grave = false}) => Padding(
          padding: const EdgeInsets.only(right: 18, bottom: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(valor, style: titulo(20).copyWith(color: grave ? rojo : null)),
            Text(etiqueta, style: const TextStyle(color: C.gris, fontSize: 12)),
          ]),
        );

    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
        children: [
          Row(children: [
            Expanded(
              child: Text(alarmas == 0 ? 'Todos los bares en orden' : '$alarmas cosas para mirar',
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
          const Text('Solo lo ven los programadores. Cada mañana llega un resumen por correo si hay algo que mirar.',
              style: TextStyle(color: C.gris, fontSize: 12)),
          const SizedBox(height: 14),
          tarjeta(
            'Plataforma',
            Wrap(children: [
              cifra('base de datos (${(bytes / 1048576).toStringAsFixed(0)} MB)', '${(uso * 100).toStringAsFixed(0)} %',
                  grave: uso >= 0.75),
              cifra('cuentas nuevas', '${_n(_r?['altas'])}'),
              cifra('cuentas sin ningún bar', '${sinBar.length}', grave: sinBar.isNotEmpty),
              if (accesos != null) cifra('inicios de sesión', '${accesos.fold(0, (s, a) => s + _n(a['n']))}'),
            ]),
          ),
          tarjeta(
            'Por bar',
            Column(children: [
              for (final b in bares)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_n(b['alarmas']) > 0 ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                      color: _n(b['alarmas']) > 0 ? rojo : C.gris),
                  title: Text('${b['nombre']} · ${_n(b['usuarios'])} usuarios',
                      style: TextStyle(fontWeight: _n(b['alarmas']) > 0 ? FontWeight.w700 : FontWeight.w500)),
                  subtitle: Text([
                    '${_n(b['pin_fallidos'])} PIN incorrectos (máx. ${_n(b['pin_max_persona'])} de una persona)',
                    if (_n(b['pin_bloqueos']) > 0) '${_n(b['pin_bloqueos'])} bloqueos',
                    if (_n(b['rechazos']) > 0) '${_n(b['rechazos'])} intentos rechazados',
                    if (_n(b['cobros_fuera_turno']) > 0) '${_n(b['cobros_fuera_turno'])} cobros en turno cerrado',
                    '${_n(b['anulaciones'])} anulaciones (${euros((b['anulado_importe'] as num).toDouble())})',
                    if (_n(b['descuadres']) > 0) '${_n(b['descuadres'])} descuadres',
                    'última copia: ${_fecha(b['ultima_copia'])}${_n(b['copias_error']) > 0 ? ' · ${_n(b['copias_error'])} fallidas' : ''}',
                  ].join(' · ')),
                ),
            ]),
          ),
          tarjeta(
            'Intentos rechazados y bloqueos',
            eventos.isEmpty
                ? const Text('Ninguno.', style: TextStyle(color: C.gris))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final e in eventos)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                            '${_fecha(e['momento'])} · ${e['bar'] ?? '¿?'} · ${e['quien'] ?? '¿?'}: '
                            '${_tipos[e['tipo']] ?? e['tipo']}${e['detalle'] != null ? ' (${e['detalle']})' : ''}'),
                      ),
                  ]),
          ),
          tarjeta(
            'Cuentas sin ningún bar',
            sinBar.isEmpty
                ? const Text('Ninguna: todas las cuentas son de algún bar.', style: TextStyle(color: C.gris))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text(
                        'Alguien se ha creado una cuenta por su cuenta: desactiva el registro abierto en '
                        'Supabase › Authentication › Sign In / Providers y borra las que no conozcas.',
                        style: TextStyle(color: rojo)),
                    const SizedBox(height: 6),
                    for (final u in sinBar)
                      Text('${u['correo']} · creada ${_fecha(u['creado'])} · último acceso ${_fecha(u['ultimo_acceso'])}'),
                  ]),
          ),
          tarjeta(
            'Inicios de sesión',
            accesos == null
                ? const Text('El registro de auditoría de Supabase Auth no está disponible: míralo en Supabase › Logs.',
                    style: TextStyle(color: C.gris))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(accesos.map((a) => '${a['dia']}: ${a['n']}').join(' · ')),
                    if (ips != null && ips.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text('IP con más inicios de sesión:', style: TextStyle(color: C.gris)),
                      for (final i in ips) Text('${i['ip']}: ${i['n']}'),
                    ],
                    const SizedBox(height: 6),
                    const Text('Los intentos fallidos contra Supabase Auth solo están en Supabase › Logs › Auth.',
                        style: TextStyle(color: C.gris, fontSize: 12)),
                  ]),
          ),
        ],
      ),
    );
  }
}
