import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../control/control_comun.dart' show rojo;
import '../ticketbai/modelos.dart' show euros;

/// Seguridad de TODOS los bares, solo para programadores. Arriba, si hay algo que mirar y dónde;
/// después las cifras de la plataforma, una tarjeta por bar, las alertas separadas de la actividad
/// normal y las cuentas. Los datos los da resumen_plataforma (migraciones 0046 y 0055). El aviso
/// diario por correo (función alertas-seguridad) cuenta lo mismo de las últimas 24 horas.
class PlataformaTab extends StatefulWidget {
  const PlataformaTab({super.key});

  @override
  State<PlataformaTab> createState() => _PlataformaTabState();
}

// A partir de aquí se marca en rojo
const _muchosPin = 10;
const _copiaVieja = Duration(days: 2);
const _baseLlena = 0.75;

// Acciones normales que quedan registradas (igual que evento_es_actividad, migración 0055)
const _tiposActividad = {
  'pin_cambiado', 'usuario_creado', 'miembro_cambiado', 'certificado_subido', 'alta_bar', 'paso_produccion', 'factura_forzada',
};

// Qué pasó, dicho de la persona: «Ana» + esto
const _queHizo = {
  'pin_bloqueado': 'se quedó bloqueada por meter mal el PIN',
  'anulacion_denegada': 'intentó anular una factura sin ser administrador',
  'usuario_ajeno': 'intentó cambiar el PIN de un usuario de otro bar',
  'pin_otro_bar': 'no pudo cambiar el PIN de un empleado que también está en otro bar',
  'pin_bloqueado_bar': 'provocó el bloqueo de la entrada con PIN en todo el bar',
  'precio_distinto': 'vendió sin internet a un precio distinto del de la carta',
  'fondo_distinto': 'abrió la caja con un fondo distinto del que se dejó',
  'factura_rechazada': 'emitió una factura que el servidor no aceptó',
  'factura_descuadre': 'hizo una venta sin internet que no cuadra con su pedido',
  'pin_admin_denegado': 'intentó cambiar el PIN de otro administrador',
  'venta_en_espera': 'hizo una venta sin internet que quedó en espera',
  'altas_limitadas': 'dio de alta demasiados usuarios seguidos y se frenaron',
  'produccion_denegada': 'intentó pasar el bar a producción, pero faltaba algo',
  'pin_cambiado': 'cambió un PIN',
  'usuario_creado': 'dio de alta a un usuario',
  'miembro_cambiado': 'cambió el rol, los permisos o la baja de un empleado',
  'certificado_subido': 'subió el certificado del titular',
  'alta_bar': 'dio de alta el bar',
  'paso_produccion': 'pasó el bar a producción',
  'factura_forzada': 'envió tal cual una venta que estaba en espera',
};

typedef _Fila = ({IconData icono, String nombre, String valor, bool mal});
typedef _Revisar = ({String texto, VoidCallback? abrir});

class _PlataformaTabState extends State<PlataformaTab> {
  int _dias = 7;
  Map<String, dynamic>? _r;
  bool _cargando = true;
  String? _errorCarga;
  bool _todasAlertas = false, _todaActividad = false;
  final _claveCuentas = GlobalKey();

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

  // ---------- Datos ----------
  List<Map<String, dynamic>> _lista(String clave) =>
      [for (final x in (_r?[clave] as List?) ?? const []) Map<String, dynamic>.from(x as Map)];
  static int _n(Object? v) => (v as num?)?.toInt() ?? 0;

  String get _periodo => switch (_dias) { 1 => 'hoy', 30 => 'en los últimos 30 días', _ => 'en los últimos 7 días' };

  static String _fecha(Object? m) {
    if (m == null) return 'nunca';
    final d = DateTime.parse(m as String).toLocal();
    return '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  static bool _esActividad(Map<String, dynamic> e) => e['actividad'] as bool? ?? _tiposActividad.contains(e['tipo']);

  static bool _copiaMal(Map<String, dynamic> b) {
    if (_n(b['copias_error']) > 0) return true;
    final u = b['ultima_copia'];
    return u != null && DateTime.now().difference(DateTime.parse(u as String)) > _copiaVieja;
  }

  // Lo que va en rojo de un bar (cada cosa, una frase)
  static List<String> _problemas(Map<String, dynamic> b) => [
        if (_n(b['pin_bloqueos']) > 0) '${_n(b['pin_bloqueos'])} bloqueos por PIN',
        if (_n(b['pin_max_persona']) >= _muchosPin) 'una persona con ${_n(b['pin_max_persona'])} PIN incorrectos',
        if (_n(b['rechazos']) > 0) '${_n(b['rechazos'])} intentos rechazados',
        if (_n(b['cobros_fuera_turno']) > 0) '${_n(b['cobros_fuera_turno'])} cobros en un turno ya cerrado',
        if (_n(b['copias_error']) > 0) '${_n(b['copias_error'])} copias en Drive fallidas',
        if (_n(b['copias_error']) == 0 && _copiaMal(b)) 'la última copia en Drive es del ${_fecha(b['ultima_copia'])}',
      ];

  List<_Fila> _filas(Map<String, dynamic> b) {
    final ultima = b['ultima_copia'];
    return [
      (icono: Icons.pin_outlined, nombre: 'PIN incorrectos', mal: _n(b['pin_max_persona']) >= _muchosPin,
          valor: _n(b['pin_fallidos']) == 0 ? 'ninguno' : '${_n(b['pin_fallidos'])} · como mucho ${_n(b['pin_max_persona'])} de una persona'),
      (icono: Icons.lock_outline, nombre: 'Bloqueos por PIN', mal: _n(b['pin_bloqueos']) > 0, valor: '${_n(b['pin_bloqueos'])}'),
      (icono: Icons.block, nombre: 'Intentos rechazados', mal: _n(b['rechazos']) > 0, valor: '${_n(b['rechazos'])}'),
      (icono: Icons.point_of_sale, nombre: 'Cobros en turno cerrado', mal: _n(b['cobros_fuera_turno']) > 0,
          valor: '${_n(b['cobros_fuera_turno'])}'),
      (icono: Icons.undo, nombre: 'Anulaciones', mal: false,
          valor: '${_n(b['anulaciones'])} · ${euros(((b['anulado_importe'] as num?) ?? 0).toDouble())}'),
      (icono: Icons.calculate_outlined, nombre: 'Descuadres de caja', mal: false, valor: '${_n(b['descuadres'])}'),
      (icono: Icons.cloud_done_outlined, nombre: 'Última copia en Drive', mal: _copiaMal(b),
          valor: ultima == null ? 'ninguna todavía' : '${_fecha(ultima)}${_n(b['copias_error']) > 0 ? ' · ${_n(b['copias_error'])} fallidas' : ''}'),
      (icono: Icons.history, nombre: 'Actividad registrada', mal: false, valor: '${_n(b['actividad'])}'),
    ];
  }

  // ---------- Piezas ----------
  Widget _tarjeta(Widget hijo, {Key? key, Color? borde}) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: C.blanco,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borde ?? C.borde, width: borde == null ? 1 : 2),
        ),
        child: hijo,
      );

  Widget _titulo(String texto, {String? ayuda}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(texto, style: titulo(17)),
          if (ayuda != null) Text(ayuda, style: const TextStyle(color: C.gris, fontSize: 12)),
        ]),
      );

  Widget _fila(_Fila f, {VoidCallback? onTap}) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(f.icono, size: 20, color: f.mal ? rojo : C.gris),
            const SizedBox(width: 10),
            Expanded(child: Text(f.nombre, style: TextStyle(color: f.mal ? rojo : C.tinta, fontWeight: f.mal ? FontWeight.w600 : null))),
            const SizedBox(width: 8),
            Flexible(
              child: Text(f.valor,
                  textAlign: TextAlign.right,
                  style: TextStyle(color: f.mal ? rojo : C.gris, fontWeight: f.mal ? FontWeight.w700 : null)),
            ),
          ]),
        ),
      );

  Widget _evento(Map<String, dynamic> e, {bool conBar = true}) {
    final quien = (e['quien'] as String?)?.trim();
    final tipo = e['tipo'] as String?;
    final detalle = (e['detalle'] as String?)?.trim();
    String que;
    if (tipo == 'pin_bloqueado_bar') {
      que = 'Se bloqueó la entrada con PIN en todo el bar';
    } else if (tipo == 'pin_cambiado' && detalle != null && detalle.isNotEmpty) {
      // El servidor ya lo dice entero: «Cambió su propio PIN», «Cambió el PIN de Luis»
      que = '${quien?.isNotEmpty == true ? quien : 'Alguien'} ${detalle[0].toLowerCase()}${detalle.substring(1)}';
    } else {
      que = '${quien?.isNotEmpty == true ? quien : 'Alguien'} ${_queHizo[tipo] ?? 'hizo algo apuntado como «$tipo»'}';
    }
    final mostrarDetalle = detalle != null && detalle.isNotEmpty && tipo != 'pin_cambiado';
    final alerta = !_esActividad(e);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(alerta ? Icons.error_outline : Icons.check_circle_outline, size: 20, color: alerta ? rojo : C.verde),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(conBar ? '${_fecha(e['momento'])} · ${e['bar'] ?? 'sin bar'}' : _fecha(e['momento']),
                style: const TextStyle(color: C.gris, fontSize: 12)),
            Text(que),
            if (mostrarDetalle) Text(detalle, style: const TextStyle(color: C.gris, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  Widget _listaEventos(List<Map<String, dynamic>> eventos, bool todas, VoidCallback verTodas, String vacio) {
    if (eventos.isEmpty) return Text(vacio, style: const TextStyle(color: C.gris));
    final vistos = todas ? eventos : eventos.take(10).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final e in vistos) _evento(e),
      if (vistos.length < eventos.length) TextButton(onPressed: verTodas, child: Text('Ver las ${eventos.length}')),
    ]);
  }

  // ---------- Detalle de un bar (sin cambiar de bar en este equipo) ----------
  void _abrirBar(Map<String, dynamic> b) {
    final eventos = _lista('eventos').where((e) => e['bar_id'] == b['id']).toList();
    final alertas = eventos.where((e) => !_esActividad(e)).toList();
    final actividad = eventos.where(_esActividad).toList();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: C.crema,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('${b['nombre']}', style: titulo(22)),
            Text('${_n(b['usuarios'])} usuarios · datos de $_periodo', style: const TextStyle(color: C.gris)),
            const SizedBox(height: 12),
            _tarjeta(Column(children: [for (final f in _filas(b)) _fila(f)])),
            _tarjeta(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _titulo('Alertas', ayuda: 'Intentos rechazados, bloqueos y cosas denegadas'),
              if (alertas.isEmpty) const Text('Ninguna.', style: TextStyle(color: C.gris)),
              for (final e in alertas) _evento(e, conBar: false),
            ])),
            _tarjeta(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _titulo('Actividad', ayuda: 'Acciones normales que quedan registradas'),
              if (actividad.isEmpty) const Text('Ninguna.', style: TextStyle(color: C.gris)),
              for (final e in actividad) _evento(e, conBar: false),
            ])),
            const Text('Los PIN incorrectos sueltos no salen en la lista: solo cuentan en la cifra. '
                'El detalle completo lo ve el administrador del bar en Números › Seguridad.',
                style: TextStyle(color: C.gris, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  void _irACuentas() {
    final c = _claveCuentas.currentContext;
    if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300));
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final bares = _lista('bares');
    final sinBar = _lista('cuentas_sin_bar');
    final baja = _lista('cuentas_baja');
    final eventos = _lista('eventos');
    final alertas = eventos.where((e) => !_esActividad(e)).toList();
    final actividad = eventos.where(_esActividad).toList();
    final accesos = _r?['accesos'] == null ? null : _lista('accesos');
    final ips = _r?['ips'] == null ? null : _lista('ips');
    final bytes = _n(_r?['base_bytes']), limite = _n(_r?['base_limite']);
    final uso = limite == 0 ? 0.0 : bytes / limite;
    final ancho = MediaQuery.sizeOf(context).width;

    // Lo que hay que revisar, una línea cada cosa
    final revisar = <_Revisar>[
      for (final b in bares)
        for (final p in _problemas(b)) (texto: '${b['nombre']}: $p', abrir: () => _abrirBar(b)),
      if (uso >= _baseLlena) (texto: 'La base de datos está al ${(uso * 100).toStringAsFixed(0)} % del plan', abrir: null),
      if (sinBar.isNotEmpty)
        (texto: '${sinBar.length} ${sinBar.length == 1 ? 'cuenta' : 'cuentas'} con correo real que no ${sinBar.length == 1 ? 'es' : 'son'} de ningún bar',
            abrir: _irACuentas),
    ];
    final enOrden = revisar.isEmpty;

    Widget cifra(IconData icono, String numero, String nombre, String frase, bool mal) => _tarjeta(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icono, color: mal ? rojo : C.verde),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: (mal ? rojo : C.gris).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                child: Text(mal ? 'revisar' : 'normal',
                    style: TextStyle(color: mal ? rojo : C.gris, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(numero, style: titulo(28).copyWith(color: mal ? rojo : null)),
            Text(nombre, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(frase, style: const TextStyle(color: C.gris, fontSize: 12)),
          ]),
        );
    final cifras = [
      cifra(Icons.storage_outlined, '${(uso * 100).toStringAsFixed(0)} %', 'Espacio de la base de datos',
          'Ahora: ${(bytes / 1048576).toStringAsFixed(0)} MB de ${(limite / 1048576).toStringAsFixed(0)} MB. Revisar desde el 75 %',
          uso >= _baseLlena),
      cifra(Icons.person_add_alt, '${_n(_r?['altas'])}', 'Cuentas nuevas', 'Creadas $_periodo (empleados y administradores)', false),
      cifra(Icons.no_accounts_outlined, '${sinBar.length}', 'Cuentas que no pertenecen a ningún bar',
          sinBar.isEmpty ? 'Ahora. Sin contar programadores, Yitso ni empleados dados de baja' : 'Ahora. Con correo real: alguien se ha registrado',
          sinBar.isNotEmpty),
      cifra(Icons.login, accesos == null ? '—' : '${accesos.fold(0, (s, a) => s + _n(a['n']))}', 'Inicios de sesión',
          accesos == null ? 'No disponible: míralo en Supabase › Logs' : 'Entradas en la app $_periodo', false),
    ];

    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: EdgeInsets.all(ancho < 600 ? 12 : 28),
        children: [
          // 1 · Estado general
          _tarjeta(
            borde: enOrden ? C.verde : rojo,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(enOrden ? Icons.check_circle : Icons.warning_amber_rounded, size: 36, color: enOrden ? C.verde : rojo),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    enOrden ? 'Todo en orden' : 'Hay ${revisar.length} ${revisar.length == 1 ? 'cosa' : 'cosas'} que revisar',
                    style: titulo(24).copyWith(color: enOrden ? C.verde : rojo),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              Text(enOrden ? 'Ningún bar pasa de los umbrales $_periodo.' : 'Toca una línea para ver el detalle.',
                  style: const TextStyle(color: C.gris, fontSize: 13)),
              for (final r in revisar)
                InkWell(
                  onTap: r.abrir,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      const Icon(Icons.cancel, size: 18, color: rojo),
                      const SizedBox(width: 8),
                      Expanded(child: Text(r.texto)),
                      if (r.abrir != null) const Icon(Icons.chevron_right, color: C.gris),
                    ]),
                  ),
                ),
            ]),
          ),

          // 2 · Periodo y cifras
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Periodo:', style: TextStyle(fontWeight: FontWeight.w600)),
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
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            final columnas = c.maxWidth >= 700 ? 2 : 1;
            final w = (c.maxWidth - 14 * (columnas - 1)) / columnas;
            return Wrap(spacing: 14, children: [for (final t in cifras) SizedBox(width: w, child: t)]);
          }),

          // 3 · Por bar
          Padding(padding: const EdgeInsets.only(top: 8, bottom: 8), child: Text('Por bar', style: titulo(20))),
          Text('Datos de $_periodo. Toca un dato para ver el detalle del bar.', style: const TextStyle(color: C.gris, fontSize: 12)),
          const SizedBox(height: 8),
          for (final b in bares)
            Builder(builder: (context) {
              final mal = _problemas(b).isNotEmpty;
              return _tarjeta(
                borde: mal ? rojo : null,
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  InkWell(
                    onTap: () => _abrirBar(b),
                    child: Row(children: [
                      Icon(mal ? Icons.warning_amber_rounded : Icons.check_circle, color: mal ? rojo : C.verde),
                      const SizedBox(width: 10),
                      Expanded(child: Text('${b['nombre']}', style: titulo(17))),
                      Text('${_n(b['usuarios'])} usuarios', style: const TextStyle(color: C.gris, fontSize: 12)),
                      const Icon(Icons.chevron_right, color: C.gris),
                    ]),
                  ),
                  const Divider(height: 16),
                  for (final f in _filas(b)) _fila(f, onTap: () => _abrirBar(b)),
                ]),
              );
            }),

          // 4 · Alertas y actividad, separadas
          _tarjeta(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _titulo('Alertas', ayuda: 'Intentos rechazados, bloqueos y cosas denegadas, $_periodo'),
            _listaEventos(alertas, _todasAlertas, () => setState(() => _todasAlertas = true), 'Ninguna.'),
          ])),
          _tarjeta(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _titulo('Actividad', ayuda: 'Acciones normales que quedan registradas, $_periodo'),
            _listaEventos(actividad, _todaActividad, () => setState(() => _todaActividad = true), 'Ninguna.'),
          ])),

          // 5 · Cuentas
          _tarjeta(
            key: _claveCuentas,
            borde: sinBar.isEmpty ? null : rojo,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _titulo('Cuentas que no pertenecen a ningún bar', ayuda: 'Sin contar programadores ni cuentas de Yitso'),
              if (sinBar.isEmpty)
                _fila((icono: Icons.check_circle, nombre: 'Ninguna con correo real', valor: '', mal: false))
              else ...[
                const Text('Alguien se ha creado una cuenta por su cuenta. Desactiva el registro abierto en '
                    'Supabase › Authentication › Sign In / Providers y borra las que no conozcas.',
                    style: TextStyle(color: rojo)),
                const SizedBox(height: 6),
                for (final u in sinBar)
                  _fila((icono: Icons.mail_outline, nombre: '${u['correo']}', valor: 'creada ${_fecha(u['creado'])}', mal: true)),
              ],
              if (baja.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('Cuentas de empleados dados de baja (${baja.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
                const Text('Normal: empleados que ya no están en ningún bar. Ya no pueden entrar en ninguno.',
                    style: TextStyle(color: C.gris, fontSize: 12)),
                const SizedBox(height: 4),
                for (final u in baja)
                  _fila((icono: Icons.person_off_outlined, nombre: '${u['nombre']}',
                      valor: 'último acceso ${_fecha(u['ultimo_acceso'])}', mal: false)),
              ],
            ]),
          ),

          // Inicios de sesión por día
          _tarjeta(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _titulo('Inicios de sesión por día', ayuda: _periodo[0].toUpperCase() + _periodo.substring(1)),
            if (accesos == null)
              const Text('El registro de Supabase Auth no está disponible: míralo en Supabase › Logs.',
                  style: TextStyle(color: C.gris))
            else ...[
              for (final a in accesos)
                _fila((icono: Icons.calendar_today_outlined, nombre: '${a['dia']}', valor: '${a['n']}', mal: false)),
              if (ips != null && ips.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Direcciones IP con más entradas', style: TextStyle(fontWeight: FontWeight.w600)),
                for (final i in ips) _fila((icono: Icons.lan_outlined, nombre: '${i['ip']}', valor: '${i['n']}', mal: false)),
              ],
              const SizedBox(height: 6),
              const Text('Los intentos de entrada fallidos solo están en Supabase › Logs › Auth.',
                  style: TextStyle(color: C.gris, fontSize: 12)),
            ],
          ])),
          const Text('Solo lo ven los programadores. Cada mañana llega un correo si hay algo que mirar.',
              style: TextStyle(color: C.gris, fontSize: 12)),
        ],
      ),
    );
  }
}
