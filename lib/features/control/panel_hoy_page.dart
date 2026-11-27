import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../gestion/comun.dart' show Cifra;
import '../barra/venta_offline.dart' show VentaOffline;
import '../ticketbai/caducidad_certificados.dart';
import '../ticketbai/modelos.dart' show euros;
import 'control_comun.dart';

/// Panel del dueño (pensado para el móvil): cómo va hoy frente al mismo día de la semana
/// pasada y avisos de lo que hay que mirar. Se actualiza solo cada minuto.
class PanelHoyPage extends StatefulWidget {
  const PanelHoyPage({super.key});

  @override
  State<PanelHoyPage> createState() => _PanelHoyPageState();
}

typedef _Aviso = ({IconData icono, Color color, String titulo, String detalle});

class _PanelHoyPageState extends State<PanelHoyPage> {
  bool _cargando = true;
  String? _errorCarga;
  Timer? _timer;
  DateTime _actualizado = DateTime.now();

  List<Map<String, dynamic>> _hoy = [], _semana = [], _pagos = [];
  final _avisos = <_Aviso>[];
  Map<String, dynamic>? _copia;
  int? _tamano; // bytes que ocupa la base (plan gratuito: 500 MB)
  static const _limiteBase = 500 * 1024 * 1024;
  bool _copiando = false;
  bool _conDatos = false; // si una recarga falla, se sigue viendo lo último

  @override
  void initState() {
    super.initState();
    _cargar();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _cargar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _iso(DateTime d) => d.toUtc().toIso8601String();
  static String _dia(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  static String _fecha(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Future<void> _cargar() async {
    try {
      await online(_cargarDatos);
      if (mounted) {
        setState(() {
          _cargando = false;
          _errorCarga = null;
          _conDatos = true;
          _actualizado = DateTime.now();
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

  Future<void> _cargarDatos() async {
    final ahora = DateTime.now();
    final hoy0 = DateTime(ahora.year, ahora.month, ahora.day);
    final sem0 = hoy0.subtract(const Duration(days: 7));
    final r = await Future.wait<dynamic>([
      supabase.from('pedidos').select('total, pagado_en').eq('estado', 'pagado').gte('pagado_en', _iso(hoy0)),
      supabase.from('pedidos').select('total, pagado_en').eq('estado', 'pagado')
          .gte('pagado_en', _iso(sem0)).lt('pagado_en', _iso(sem0.add(const Duration(days: 1)))),
      supabase.from('pagos').select('metodo, importe').gte('creado_en', _iso(hoy0)),
      seguro(supabase.from('registro_anulaciones').select('tipo, importe, usuario_id, estado_cocina').gte('momento', _iso(hoy0))),
      seguro(supabase.from('turnos_caja').select('diferencia, cerrado_por, cerrado_en').eq('estado', 'cerrado')
          .gte('cerrado_en', _iso(hoy0.subtract(const Duration(days: 2))))),
      seguro(supabase.from('facturas').select('estado_envio, creado_en').inFilter('estado_envio', ['error', 'pendiente'])),
      seguro(supabase.from('articulos_stock').select('stock, minimo').eq('activo', true)),
      seguro(supabase.from('cuadrante').select('usuario_id, inicio').eq('fecha', _dia(ahora))),
      seguro(supabase.from('fichajes').select('usuario_id').gte('momento', _iso(hoy0))),
      seguro(supabase.rpc('equipo_empresa')),
      seguro(supabase.from('pedidos').select('total').inFilter('estado', ['abierto', 'precuenta'])),
      seguro(supabase.from('copias_seguridad').select().order('creado_en', ascending: false).limit(20)),
    ]);
    // El certificado del servidor se mira como mucho cada 12 h (lo apunta para todos los equipos)
    unawaited(CaducidadCertificados.registrarServidor());
    var certificados = <({String origen, String? titular, DateTime caduca, int dias})>[];
    try {
      certificados = await CaducidadCertificados.porCaducar();
    } catch (_) {}
    final cola = await VentaOffline.resumenCola();
    try {
      _tamano = (await supabase.rpc('tamano_base') as num?)?.toInt();
    } catch (_) {} // sin la migración 0028
    _hoy = List<Map<String, dynamic>>.from(r[0] as List);
    _semana = List<Map<String, dynamic>>.from(r[1] as List);
    _pagos = List<Map<String, dynamic>>.from(r[2] as List);
    final anul = r[3] as List<Map<String, dynamic>>;
    final cierres = r[4] as List<Map<String, dynamic>>;
    final facturas = r[5] as List<Map<String, dynamic>>;
    final stock = r[6] as List<Map<String, dynamic>>;
    final cuadrante = r[7] as List<Map<String, dynamic>>;
    final fichados = {for (final f in r[8] as List<Map<String, dynamic>>) f['usuario_id']};
    final nombres = {for (final p in r[9] as List<Map<String, dynamic>>) p['id']: p['nombre'] as String};
    final abiertas = r[10] as List<Map<String, dynamic>>;
    final copias = r[11] as List<Map<String, dynamic>>;
    _copia = copias.isEmpty ? null : copias.first;
    final copiaOk = copias.where((c) => c['estado'] == 'ok').firstOrNull;

    double n(Object? v) => (v as num?)?.toDouble() ?? 0;
    _avisos.clear();

    // Anulaciones de hoy
    if (anul.isNotEmpty) {
      final importe = anul.fold(0.0, (s, a) => s + n(a['importe']));
      final graves = anul.where((a) => colorAnulacion(a) == rojo).length;
      final porQuien = <String, int>{};
      for (final a in anul) {
        final q = nombres[a['usuario_id']] ?? '¿?';
        porQuien[q] = (porQuien[q] ?? 0) + 1;
      }
      final top = porQuien.entries.reduce((a, b) => a.value >= b.value ? a : b);
      _avisos.add((
        icono: Icons.remove_circle_outline,
        color: graves > 0 || anul.length >= 5 || importe >= 30 ? rojo : C.naranja,
        titulo: '${anul.length} anulaciones hoy · ${euros(importe)}',
        detalle: '${graves > 0 ? '$graves de cosas ya cobradas o borradas · ' : ''}más: ${top.key} (${top.value})',
      ));
    }
    // Descuadres de caja
    for (final c in cierres.where((c) => n(c['diferencia']).abs() >= 1)) {
      final d = n(c['diferencia']);
      _avisos.add((
        icono: Icons.point_of_sale,
        color: d < 0 ? rojo : C.naranja,
        titulo: 'Caja ${d < 0 ? 'faltan' : 'sobran'} ${euros(d.abs())}',
        detalle: 'Cierre de ${nombres[c['cerrado_por']] ?? '¿?'} · '
            '${hhmm(DateTime.parse(c['cerrado_en'] as String).toLocal())} del '
            '${DateTime.parse(c['cerrado_en'] as String).toLocal().day}',
      ));
    }
    // TicketBAI
    final errores = facturas.where((f) => f['estado_envio'] == 'error').length;
    final atascadas = facturas
        .where((f) => f['estado_envio'] == 'pendiente' &&
            DateTime.parse(f['creado_en'] as String).isBefore(ahora.subtract(const Duration(hours: 1))))
        .length;
    if (errores + atascadas > 0) {
      _avisos.add((
        icono: Icons.receipt_long,
        color: rojo,
        titulo: 'TicketBAI: ${errores > 0 ? '$errores rechazadas' : ''}${errores > 0 && atascadas > 0 ? ' · ' : ''}'
            '${atascadas > 0 ? '$atascadas sin enviar desde hace +1 h' : ''}',
        detalle: 'Míralo en Números › Facturas emitidas',
      ));
    }
    // Certificados que caducan (el día que caducan no se puede firmar)
    for (final c in certificados) {
      final caducado = c.caduca.isBefore(ahora);
      final equipo = c.origen.replaceFirst('equipo', '').trim();
      final donde = c.origen == 'servidor'
          ? 'el del servidor (tablets): el programador sube el nuevo en Ajustes › Programa › Estado de los bares'
          : 'el del ${equipo.isEmpty ? 'TPV' : 'equipo $equipo'}: instálalo en Ajustes › Empresa';
      _avisos.add((
        icono: Icons.key_off_outlined,
        color: caducado || c.dias <= 7 ? rojo : C.naranja,
        titulo: caducado
            ? 'Certificado caducado: no se puede firmar'
            : 'El certificado caduca en ${c.dias} día${c.dias == 1 ? '' : 's'} (${_fecha(c.caduca)})',
        detalle: '${c.titular ?? 'Certificado'} · renuévalo y cambia $donde',
      ));
    }
    // Ventas hechas sin internet en ESTE equipo que aún no han subido
    if (cola.n > 0) {
      final desde = cola.desde;
      _avisos.add((
        icono: Icons.cloud_upload_outlined,
        color: desde != null && ahora.difference(desde) > const Duration(hours: 12) ? rojo : C.naranja,
        titulo: '${cola.n} venta${cola.n == 1 ? '' : 's'} sin subir en este equipo'
            '${desde == null ? '' : ' desde ${desde.day == ahora.day && ahora.difference(desde).inHours < 24 ? hhmm(desde) : '${_fecha(desde)} ${hhmm(desde)}'}'}',
        detalle: 'Se suben solas al volver internet. No desinstales la app ni borres sus datos hasta entonces',
      ));
    }
    // Espacio de la base de datos: si se llena, deja de guardar ventas
    if (_tamano != null && _tamano! >= _limiteBase * 0.75) {
      final pct = (_tamano! * 100 / _limiteBase).round();
      _avisos.add((
        icono: Icons.storage_outlined,
        color: pct >= 90 ? rojo : C.naranja,
        titulo: 'Base de datos al $pct % (${_mb(_tamano!)} de 500 MB)',
        detalle: 'Plan gratuito de Supabase: si se llena, no se pueden guardar ventas. '
            'Hay que limpiar lo que ya está archivado en Drive',
      ));
    }
    // Empleados con turno que no han fichado
    final faltan = <String>{};
    for (final c in cuadrante) {
      final p = (c['inicio'] as String).split(':');
      final ini = DateTime(ahora.year, ahora.month, ahora.day, int.parse(p[0]), int.parse(p[1]));
      if (ahora.isAfter(ini.add(const Duration(minutes: 10))) && !fichados.contains(c['usuario_id'])) {
        faltan.add(nombres[c['usuario_id']] ?? '¿?');
      }
    }
    if (faltan.isNotEmpty) {
      _avisos.add((icono: Icons.badge_outlined, color: C.naranja, titulo: 'Sin fichar: ${faltan.join(', ')}',
          detalle: 'Tenían turno y no han fichado la entrada'));
    }
    // Stock
    final bajos = stock.where((a) => n(a['minimo']) > 0 && n(a['stock']) <= n(a['minimo'])).length;
    if (bajos > 0) {
      _avisos.add((icono: Icons.inventory_2_outlined, color: C.naranja, titulo: '$bajos artículos bajo mínimo',
          detalle: 'Stock › Para pedir'));
    }
    // Mesas abiertas (informativo)
    if (abiertas.isNotEmpty) {
      _avisos.add((icono: Icons.table_restaurant_outlined, color: C.gris,
          titulo: '${abiertas.length} cuentas abiertas · ${euros(abiertas.fold(0.0, (s, p) => s + n(p['total'])))}',
          detalle: 'Pendiente de cobrar'));
    }
    // Copia de seguridad: se hace sola cada día; avisa si la última buena tiene más de 2 días
    final okEn = copiaOk == null ? null : DateTime.parse(copiaOk['creado_en'] as String).toLocal();
    final ultimoError = _copia?['estado'] == 'error' ? 'Último intento: ${_copia!['detalle']}' : null;
    if (okEn == null || ahora.difference(okEn) > const Duration(days: 2)) {
      _avisos.add((
        icono: Icons.cloud_off_outlined,
        color: rojo,
        titulo: okEn == null ? 'Nunca se ha hecho copia en Google Drive' : 'La última copia en Drive es del ${_fecha(okEn)}',
        detalle: ultimoError ?? 'La copia automática no está funcionando: pulsa "Hacer copia ahora" abajo',
      ));
    } else if (ultimoError != null) {
      _avisos.add((icono: Icons.cloud_off_outlined, color: C.naranja, titulo: 'Falló la última copia en Drive',
          detalle: ultimoError));
    }
  }

  Future<void> _hacerCopia() async {
    setState(() => _copiando = true);
    try {
      exigirConexion();
      // Sin mes: la función guarda el mes en curso (y los días 1 y 2 también el anterior)
      final r = await supabase.functions.invoke('copia-mensual', body: const <String, dynamic>{});
      final res = ((r.data as Map)['resultados'] as List?)?.cast<Map>() ?? [];
      final ok = res.isNotEmpty && res.every((x) => x['ok'] == true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok ? 'Copia guardada en Google Drive' : 'La copia falló: ${(res.where((x) => x['ok'] != true).firstOrNull ?? const {})['detalle']}')));
      }
    } on FunctionException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('La copia falló: ${(e.details as Map?)?['error'] ?? e.details}')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
    if (mounted) setState(() => _copiando = false);
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null && !_conDatos) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    if (_cargando) return const Center(child: CircularProgressIndicator());
    double n(Object? v) => (v as num?)?.toDouble() ?? 0;
    final ahora = DateTime.now();
    final hace7 = ahora.subtract(const Duration(days: 7));
    final totalHoy = _hoy.fold(0.0, (s, p) => s + n(p['total']));
    // Semana pasada hasta esta misma hora, y el día entero
    final semHastaAhora = _semana
        .where((p) => DateTime.parse(p['pagado_en'] as String).toLocal().isBefore(hace7))
        .fold(0.0, (s, p) => s + n(p['total']));
    final semTotal = _semana.fold(0.0, (s, p) => s + n(p['total']));
    final pct = semHastaAhora == 0 ? null : (totalHoy - semHastaAhora) / semHastaAhora * 100;
    final metodos = <String, double>{};
    for (final p in _pagos) {
      metodos[p['metodo'] as String] = (metodos[p['metodo']] ?? 0) + n(p['importe']);
    }
    const dias = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
    final ancho = MediaQuery.sizeOf(context).width;

    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: C.verde, borderRadius: BorderRadius.circular(20)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Vendido hoy', style: TextStyle(color: Colors.white.withValues(alpha: 0.8))),
              Text(euros(totalHoy), style: titulo(40, color: Colors.white)),
              const SizedBox(height: 4),
              Text(
                pct == null
                    ? 'El ${dias[hace7.weekday - 1]} pasado a esta hora: ${euros(semHastaAhora)}'
                    : '${pct >= 0 ? '▲' : '▼'} ${pct.abs().toStringAsFixed(0)} % frente al ${dias[hace7.weekday - 1]} pasado '
                        'a esta hora (${euros(semHastaAhora)})',
                style: TextStyle(color: pct == null || pct >= 0 ? Colors.white : const Color(0xFFFFD2C2), fontWeight: FontWeight.w600),
              ),
              Text('Aquel día cerró con ${euros(semTotal)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 12, runSpacing: 12, children: [
            Cifra('Tickets', '${_hoy.length}', detalle: _hoy.isEmpty ? null : 'medio ${euros(totalHoy / _hoy.length)}'),
            Cifra('Efectivo', euros(metodos['efectivo'] ?? 0)),
            Cifra('Tarjeta', euros(metodos['tarjeta'] ?? 0)),
            if ((metodos['credito'] ?? 0) > 0) Cifra('A cuenta', euros(metodos['credito']!)),
          ]),
          const SizedBox(height: 18),
          Text('Por horas', style: titulo(18)),
          const SizedBox(height: 4),
          const Text('Verde: hoy · gris: el mismo día de la semana pasada', style: TextStyle(color: C.gris, fontSize: 12)),
          const SizedBox(height: 8),
          _PorHoras(hoy: _hoy, semana: _semana),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: Text('Avisos', style: titulo(18))),
            Text('actualizado ${hhmm(_actualizado)}', style: const TextStyle(color: C.gris, fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          if (_avisos.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(children: [
                Icon(Icons.check_circle, color: C.verde),
                SizedBox(width: 10),
                Text('Todo en orden', style: TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
          for (final a in _avisos)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: C.blanco,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: a.color == C.gris ? C.borde : a.color, width: a.color == C.gris ? 1 : 1.5),
                ),
                child: ListTile(
                leading: Icon(a.icono, color: a.color),
                title: Text(a.titulo, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(a.detalle),
              ),
              ),
            ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.borde)),
            child: Row(children: [
              Icon(_copia?['estado'] == 'ok' ? Icons.cloud_done_outlined : Icons.cloud_outlined,
                  color: _copia?['estado'] == 'ok' ? C.verde : C.gris),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _copia == null
                      ? 'Copia en Google Drive: ninguna todavía'
                      : 'Última copia (${_fecha(DateTime.parse(_copia!['creado_en'] as String).toLocal())}, mes ${_copia!['mes']}): '
                          '${_copia!['estado'] == 'ok' ? (_copia!['detalle'] ?? 'ok') : 'error: ${_copia!['detalle'] ?? '¿?'}'}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _copiando ? null : _hacerCopia,
                child: Text(_copiando ? 'Copiando…' : 'Hacer copia ahora'),
              ),
            ]),
          ),
          if (_tamano != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'Base de datos: ${_mb(_tamano!)} de 500 MB (${(_tamano! * 100 / _limiteBase).toStringAsFixed(0)} %)',
                style: const TextStyle(fontSize: 12, color: C.gris),
              ),
            ),
          const SizedBox(height: 10),
          const _ResumenCorreo(),
        ],
      ),
    );
  }
}

/// Barras por hora: hoy contra el mismo día de la semana pasada.
class _PorHoras extends StatelessWidget {
  const _PorHoras({required this.hoy, required this.semana});
  final List<Map<String, dynamic>> hoy, semana;

  Map<int, double> _porHora(List<Map<String, dynamic>> l) {
    final m = <int, double>{};
    for (final p in l) {
      final h = DateTime.parse(p['pagado_en'] as String).toLocal().hour;
      m[h] = (m[h] ?? 0) + ((p['total'] as num?)?.toDouble() ?? 0);
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final a = _porHora(hoy), b = _porHora(semana);
    final horas = {...a.keys, ...b.keys}.toList()..sort();
    if (horas.isEmpty) return const Text('Aún no hay ventas', style: TextStyle(color: C.gris));
    final desde = horas.first, hasta = horas.last;
    final max = [...a.values, ...b.values].fold(1.0, (m, v) => v > m ? v : m);
    return SizedBox(
      height: 150,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var h = desde; h <= hasta; h++)
          Expanded(
            child: Tooltip(
              message: '$h h · hoy ${euros(a[h] ?? 0)} · semana pasada ${euros(b[h] ?? 0)}',
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
                  _barra((a[h] ?? 0) / max * 120, C.verde),
                  const SizedBox(width: 2),
                  _barra((b[h] ?? 0) / max * 120, C.bordeFuerte),
                ]),
                const SizedBox(height: 4),
                Text('$h', style: const TextStyle(fontSize: 10, color: C.gris)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _barra(double alto, Color color) => Flexible(
        child: Container(
          height: alto < 2 ? 2 : alto,
          constraints: const BoxConstraints(maxWidth: 12),
          decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
        ),
      );
}

/// A qué correo llega cada mañana el resumen del día anterior.
class _ResumenCorreo extends StatefulWidget {
  const _ResumenCorreo();

  @override
  State<_ResumenCorreo> createState() => _ResumenCorreoState();
}

class _ResumenCorreoState extends State<_ResumenCorreo> {
  final _correo = TextEditingController();
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    () async {
      try {
        final e = await supabase.from('empresa').select('correo_resumen').eq('id', Perfil.cache!.empresaId!).single();
        if (mounted) setState(() => _correo.text = (e['correo_resumen'] as String?) ?? '');
      } catch (_) {}
    }();
  }

  void _avisar(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _guardar({bool probar = false}) async {
    final c = _correo.text.trim();
    if (c.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+(,\s*[^@\s]+@[^@\s]+\.[^@\s]+)*$').hasMatch(c)) {
      return _avisar('Revisa el correo (varios, separados por comas)');
    }
    if (c.split(',').length > 5) return _avisar('Como mucho 5 correos');
    setState(() => _ocupado = true);
    try {
      exigirConexion();
      await supabase.from('empresa').update({'correo_resumen': c.isEmpty ? null : c}).eq('id', Perfil.cache!.empresaId!);
      if (probar) {
        final r = await supabase.functions.invoke('resumen-diario');
        final res = ((r.data as Map)['resultados'] as List?)?.cast<Map>() ?? [];
        _avisar(res.isNotEmpty && res.first['ok'] == true ? 'Enviado: mira tu correo' : 'No se pudo enviar: ${res.firstOrNull?['detalle']}');
      } else {
        _avisar(c.isEmpty ? 'Resumen diario desactivado' : 'Guardado: llegará cada mañana');
      }
    } on FunctionException catch (e) {
      _avisar('No se pudo enviar: ${(e.details as Map?)?['error'] ?? e.details}');
    } catch (e) {
      _avisar(textoError(e));
    }
    if (mounted) setState(() => _ocupado = false);
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.borde)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.mail_outline, color: C.verde),
            SizedBox(width: 10),
            Text('Resumen diario por correo', style: TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
          const Text('Cada mañana: lo vendido ayer, caja, anulaciones, avisos y reservas de hoy.',
              style: TextStyle(color: C.gris, fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: _correo,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(hintText: 'correo@ejemplo.com', isDense: true),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _ocupado ? null : () => _guardar(), child: const Text('Guardar')),
            OutlinedButton(onPressed: _ocupado ? null : () => _guardar(probar: true), child: const Text('Enviar prueba')),
          ]),
        ]),
      );
}
