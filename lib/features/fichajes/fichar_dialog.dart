import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/conexion.dart';
import '../../core/tema.dart';
import 'fichajes_comun.dart';

/// Fichar desde la pantalla de entrada, con el PIN ya marcado.
Future<void> abrirFichaje(BuildContext context,
        {required String empresa, required String usuario, required String nombre, required String pin}) =>
    showDialog(
      context: context,
      builder: (_) => _FicharDialog(empresa: empresa, usuario: usuario, nombre: nombre, pin: pin),
    );

class _FicharDialog extends StatefulWidget {
  const _FicharDialog({required this.empresa, required this.usuario, required this.nombre, required this.pin});
  final String empresa, usuario, nombre, pin;

  @override
  State<_FicharDialog> createState() => _FicharDialogState();
}

class _FicharDialogState extends State<_FicharDialog> {
  bool _cargando = true, _sinInternet = false, _fichando = false;
  List<Map<String, dynamic>> _regs = [];
  List<Map<String, dynamic>> _turnos = [];
  static const _dias = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  String? _error, _hecho;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (!Conexion.enLinea.value) {
      setState(() {
        _sinInternet = true;
        _cargando = false;
      });
      return;
    }
    try {
      final r = await FichajeService.estado(widget.empresa, widget.usuario, widget.pin);
      _regs = List<Map<String, dynamic>>.from(r['registros'] as List);
      _turnos = List<Map<String, dynamic>>.from((r['turnos'] as List?) ?? const []);
    } on FichajeError catch (e) {
      _error = e.mensaje;
    } catch (_) {
      _sinInternet = true;
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _fichar(String tipo) async {
    setState(() {
      _fichando = true;
      _error = null;
    });
    try {
      final enServidor = await FichajeService.fichar(widget.empresa, widget.usuario, widget.pin, tipo);
      setState(() => _hecho = '${nombresFichaje[tipo]} fichada a las ${hora(DateTime.now())}'
          '${enServidor ? '' : '\nSin internet: queda guardada en este equipo y se sube sola.'}');
      Timer(const Duration(seconds: 3), () {
        if (mounted) Navigator.pop(context);
      });
    } on FichajeError catch (e) {
      setState(() {
        _error = e.mensaje;
        _fichando = false;
      });
    }
  }

  Widget _boton(String tipo, IconData icono, {bool principal = false}) {
    final hijo = Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icono),
        const SizedBox(width: 10),
        Text(nombresFichaje[tipo]!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: principal
          ? FilledButton(onPressed: _fichando ? null : () => _fichar(tipo), child: hijo)
          : OutlinedButton(onPressed: _fichando ? null : () => _fichar(tipo), child: hijo),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ahora = DateTime.now();
    final js = jornadas(_regs, ahora: ahora);
    final hoy = js.where((j) => j.dia == diaClave(ahora) || j.abierta).fold(0, (s, j) => s + j.minutos);
    final semana = js.fold(0, (s, j) => s + j.minutos);
    final ultimo = ultimoTipo(_regs);

    Widget cuerpo;
    if (_cargando) {
      cuerpo = const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    } else if (_hecho != null) {
      cuerpo = Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check_circle, color: C.verde, size: 64),
        const SizedBox(height: 12),
        Text(_hecho!, textAlign: TextAlign.center, style: titulo(18)),
      ]);
    } else if (_error != null && _regs.isEmpty && !_sinInternet && !_fichando) {
      cuerpo = Text(_error!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600, fontSize: 16));
    } else {
      cuerpo = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_sinInternet)
          const Text('Sin internet: el fichaje se guarda con la hora de este equipo y se sube solo al volver la conexión.',
              style: TextStyle(color: C.naranja, fontWeight: FontWeight.w600))
        else ...[
          Text(
            _regs.isEmpty
                ? 'Esta semana aún no has fichado'
                : 'Último: ${nombresFichaje[ultimo]} a las ${hora(momento(_regs.last))}',
            style: const TextStyle(color: C.gris),
          ),
          const SizedBox(height: 4),
          Text('Hoy ${horasMin(hoy)} · Semana ${horasMin(semana)}', style: titulo(18)),
          if (_turnos.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Tus próximos turnos', style: TextStyle(color: C.gris, fontSize: 13)),
            Text(
              _turnos.take(6).map((t) {
                final d = DateTime.parse(t['fecha'] as String);
                return '${_dias[d.weekday - 1]} ${d.day}: ${(t['inicio'] as String).substring(0, 5)}–${(t['fin'] as String).substring(0, 5)}';
              }).join('\n'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ],
        if (_sinInternet || ultimo == 'salida') _boton('entrada', Icons.login, principal: true),
        if (_sinInternet || ultimo == 'entrada' || ultimo == 'vuelta') _boton('pausa', Icons.coffee_outlined),
        if (_sinInternet || ultimo == 'pausa') _boton('vuelta', Icons.play_arrow, principal: !_sinInternet),
        if (_sinInternet || ultimo != 'salida') _boton('salida', Icons.logout, principal: !_sinInternet && ultimo != 'pausa'),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
        ],
      ]);
    }

    return AlertDialog(
      title: Text('Fichar · ${widget.nombre}', style: titulo(22)),
      content: SizedBox(width: 360, child: cuerpo),
      actions: [if (_hecho == null) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
    );
  }
}
