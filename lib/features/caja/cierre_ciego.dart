import 'package:flutter/material.dart';

import '../../core/panel_lateral.dart';
import '../../core/tema.dart';
import '../ticketbai/modelos.dart' show euros;

const _billetes = [500.0, 200.0, 100.0, 50.0, 20.0, 10.0, 5.0];
const _monedas = [2.0, 1.0, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01];

/// Peso oficial de cada moneda de euro, en gramos.
final _pesoMoneda = <double, double>{2.0: 8.5, 1.0: 7.5, 0.5: 7.8, 0.2: 5.74, 0.1: 4.1, 0.05: 3.92, 0.02: 3.06, 0.01: 2.3};

String _etiqueta(double v) => v >= 1 ? '${v.toStringAsFixed(0)} €' : '${(v * 100).round()} cts';
String _clave(double v) => v.toString(); // "50.0", "0.05"

/// Recuento del cajón SIN mostrar lo esperado. Devuelve {efectivo, conteo, tarjeta, nota} o null.
/// [fondo]: fondo habitual que se propone dejar en el cajón.
Future<Map<String, dynamic>?> contarCajaCiega(BuildContext context, {String? aviso, double fondo = 0}) =>
    mostrarPanel<Map<String, dynamic>>(context, (_) => _PanelCierre(aviso: aviso, fondo: fondo));

class _PanelCierre extends StatefulWidget {
  const _PanelCierre({this.aviso, this.fondo = 0});
  final String? aviso;
  final double fondo;

  @override
  State<_PanelCierre> createState() => _PanelCierreState();
}

class _PanelCierreState extends State<_PanelCierre> {
  String _modo = 'piezas';
  final _cant = {for (final v in [..._billetes, ..._monedas]) v: TextEditingController()};
  final _gramos = {for (final v in _monedas) v: TextEditingController()};
  final _total = TextEditingController();
  final _tarjeta = TextEditingController();
  late final _fondo = TextEditingController(text: widget.fondo.toStringAsFixed(2).replaceAll('.', ','));
  final _nota = TextEditingController();
  String? _err;

  double? _num(String t) => t.trim().isEmpty ? 0 : double.tryParse(t.trim().replaceAll(',', '.'));

  /// Gramos escritos → unidades en su casilla (se pueden corregir a mano después).
  void _alPesar(double v) {
    final g = _num(_gramos[v]!.text) ?? 0;
    _cant[v]!.text = g <= 0 ? '' : '${(g / _pesoMoneda[v]!).round()}';
    setState(() {});
  }

  /// Piezas de cada valor (las de la casilla de unidades).
  int _piezas(double v) {
    return int.tryParse(_cant[v]!.text.trim()) ?? 0;
  }

  bool get _porPiezas => _modo != 'total';

  double get _sumaPiezas {
    var s = 0.0;
    for (final v in [..._billetes, ..._monedas]) {
      s += _piezas(v) * v;
    }
    return (s * 100).roundToDouble() / 100;
  }

  double get _contado => _porPiezas ? _sumaPiezas : (_num(_total.text) ?? 0);
  double get _retirar {
    final r = _contado - (_num(_fondo.text) ?? 0);
    return r < 0 ? 0 : (r * 100).roundToDouble() / 100;
  }

  void _guardar() {
    final efectivo = _porPiezas ? _sumaPiezas : _num(_total.text);
    final tarjeta = _tarjeta.text.trim().isEmpty ? null : _num(_tarjeta.text);
    if (efectivo == null || efectivo < 0) return setState(() => _err = 'Revisa el total contado');
    if (_tarjeta.text.trim().isNotEmpty && (tarjeta == null || tarjeta < 0)) {
      return setState(() => _err = 'Revisa el total del datáfono');
    }
    if (_porPiezas && [..._billetes, ..._monedas].any((v) => _cant[v]!.text.trim().isNotEmpty && int.tryParse(_cant[v]!.text.trim()) == null)) {
      return setState(() => _err = 'En billetes y monedas pon cuántas piezas hay (número entero)');
    }
    final fondo = _num(_fondo.text);
    if (fondo == null || fondo < 0) return setState(() => _err = 'Revisa el fondo que dejas');
    if (fondo > efectivo + 0.004) return setState(() => _err = 'No puedes dejar de fondo más de lo que has contado');
    if (_modo == 'peso' && _monedas.any((v) => (_num(_gramos[v]!.text) ?? -1) < 0)) {
      return setState(() => _err = 'Revisa los gramos de las monedas');
    }
    Navigator.pop(context, {
      'efectivo': efectivo,
      'conteo': _porPiezas
          ? {
              for (final v in [..._billetes, ..._monedas])
                if (_piezas(v) > 0) _clave(v): _piezas(v),
            }
          : null,
      'tarjeta': tarjeta,
      'nota': _nota.text.trim(),
      'fondo': fondo,
    });
  }

  Widget _fila(double v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(width: 70, child: Text(_etiqueta(v), style: const TextStyle(fontWeight: FontWeight.w600))),
          const Text('×  ', style: TextStyle(color: C.gris)),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _cant[v],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(isDense: true, hintText: '0'),
            ),
          ),
          const Spacer(),
          Text(euros((int.tryParse(_cant[v]!.text.trim()) ?? 0) * v), style: const TextStyle(color: C.gris)),
        ]),
      );

  /// Moneda por peso: se pesa cada tipo por separado y se calculan las piezas.
  Widget _filaPeso(double v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(width: 70, child: Text(_etiqueta(v), style: const TextStyle(fontWeight: FontWeight.w600))),
          SizedBox(
            width: 90,
            child: TextField(
              controller: _gramos[v],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              onChanged: (_) => _alPesar(v),
              decoration: const InputDecoration(isDense: true, hintText: '0', suffixText: 'g'),
            ),
          ),
          const Text('  →  ', style: TextStyle(color: C.gris)),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _cant[v],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(isDense: true, hintText: '0', suffixText: ' uds'),
            ),
          ),
          const Spacer(),
          Text(euros(_piezas(v) * v), style: const TextStyle(color: C.gris)),
        ]),
      );

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: 'Cerrar caja',
        boton: 'Cerrar caja con ${euros(_porPiezas ? _sumaPiezas : (_num(_total.text) ?? 0))}',
        onBoton: _guardar,
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.aviso != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(widget.aviso!, style: const TextStyle(color: C.naranja, fontWeight: FontWeight.w700)),
            ),
          const Text('Cuenta todo el efectivo del cajón (fondo incluido). El sistema compara al cerrar; '
              'una vez cerrada no se puede cambiar.', style: TextStyle(color: C.gris, fontSize: 13)),
          const SizedBox(height: 12),
          Segmentos(
            opciones: const {'piezas': 'Billetes y monedas', 'peso': 'Monedas por peso', 'total': 'Solo el total'},
            actual: _modo,
            onCambio: (v) => setState(() => _modo = v),
          ),
          const SizedBox(height: 12),
          if (_porPiezas) ...[
            Text('Monedas', style: titulo(16)),
            const SizedBox(height: 6),
            if (_modo == 'peso') ...[
              const Text('Pesa cada tipo de moneda por separado (pon la báscula a cero con el recipiente) '
                  'y escribe los gramos: las unidades se calculan solas. Si ya sabes cuántas son, escríbelas directamente en uds.', style: TextStyle(color: C.gris, fontSize: 13)),
              const SizedBox(height: 6),
              for (final v in _monedas) _filaPeso(v),
            ] else
              for (final v in _monedas) _fila(v),
            const SizedBox(height: 8),
            Text('Billetes', style: titulo(16)),
            const SizedBox(height: 6),
            for (final v in _billetes) _fila(v),
            const Divider(),
            Row(children: [
              Text('Total contado', style: titulo(18)),
              const Spacer(),
              Text(euros(_sumaPiezas), style: titulo(22, color: C.verde)),
            ]),
          ] else
            TextField(
              controller: _total,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Efectivo contado', suffixText: '€'),
            ),
          const EtiquetaCampo('Dejo de fondo en el cajón'),
          TextField(
            controller: _fondo,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Lo que queda para abrir mañana', suffixText: '€'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text('Retirar', style: titulo(18)),
            const Spacer(),
            Text(euros(_retirar), style: titulo(22, color: C.verde)),
          ]),
          const Text('Lo que sacas del cajón (sobre / banco). Mejor deja monedas y billetes pequeños.',
              style: TextStyle(color: C.gris, fontSize: 13)),
          const EtiquetaCampo('Total del datáfono (opcional)'),
          TextField(
            controller: _tarjeta,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(hintText: 'El que sale en el cierre del banco', suffixText: '€'),
          ),
          const EtiquetaCampo('Nota (opcional)'),
          TextField(controller: _nota, decoration: const InputDecoration(hintText: 'Ej. pagué 20 € al repartidor sin apuntarlo')),
          if (_err != null) ...[
            const SizedBox(height: 12),
            Text(_err!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
          ],
        ]),
      );
}
