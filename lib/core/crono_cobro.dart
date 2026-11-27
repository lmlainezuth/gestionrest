import 'package:flutter/material.dart';

/// Cronómetro del cobro, para saber en qué se va el tiempo. Solo mide: no cambia nada del cobro.
/// Al terminar, el desglose (y la media de los últimos cobros) sale en la consola de depuración,
/// no en la pantalla. El tiempo que el camarero pasa en la ventana de cobro (importe, forma de pago) no cuenta.
class CronoCobro {
  CronoCobro._();
  static Stopwatch? _reloj;
  static int _ultimo = 0;
  static final _pasos = <(String, int)>[];
  static var _servidor = <(String, int)>[];
  static final _ultimos = <int>[];

  /// Empieza a medir (Barra: al pulsar Cobrar, antes de abrir la ventana).
  static void empezar() {
    _reloj = Stopwatch()..start();
    _ultimo = 0;
    _pasos.clear();
    _servidor = [];
  }

  /// Lo que la función del servidor dice que ha tardado por dentro (se enseña bajo su paso).
  static void detalleServidor(List<(String, int)> pasos) => _servidor = pasos;

  /// Al pulsar Cobrar en la ventana: lo de antes (el camarero eligiendo) no cuenta. Si no se
  /// había empezado (cobro desde una mesa), empieza aquí.
  static void reanudar() {
    final r = _reloj;
    if (r == null) return empezar();
    _ultimo = r.elapsedMilliseconds;
  }

  /// Fin de un paso: apunta lo que ha tardado desde la marca anterior.
  static void marca(String paso) {
    final r = _reloj;
    if (r == null) return;
    final t = r.elapsedMilliseconds;
    _pasos.add((paso, t - _ultimo));
    _ultimo = t;
  }

  /// Cobro cancelado o fallido: no se enseña nada.
  static void cancelar() => _reloj = null;

  static String _s(int ms) => (ms / 1000).toStringAsFixed(2).replaceAll('.', ',');

  /// Cobro terminado: el desglose a la consola de depuración.
  static void terminar(BuildContext context) {
    if (_reloj == null) return;
    _reloj = null;
    final total = _pasos.fold(0, (s, p) => s + p.$2);
    _ultimos.add(total);
    if (_ultimos.length > 10) _ultimos.removeAt(0);
    final media = _ultimos.fold(0, (s, t) => s + t) ~/ _ultimos.length;
    final texto = [
      'Cobro: ${_s(total)} s'
          '${_ultimos.length > 1 ? ' · media de los últimos ${_ultimos.length}: ${_s(media)} s' : ''}',
      for (final p in _pasos) ...[
        '${p.$1}: ${_s(p.$2)} s',
        if (p.$1 == 'Guardar la factura en el servidor') ...[
          for (final d in _servidor) '    · ${d.$1}: ${_s(d.$2)} s',
          if (_servidor.isNotEmpty)
            '    · Viaje y arranque de la función: '
                '${_s(p.$2 - _servidor.fold(0, (s, d) => s + d.$2))} s',
          if (_servidor.isEmpty) '    · (la función no da su detalle: ¿está desplegada la nueva?)',
        ],
      ],
    ].join('\n');
    // Solo en la consola de depuración: en el bar no se enseña nada
    debugPrint(texto);
  }
}
