import 'package:flutter/material.dart';

import '../../core/panel_lateral.dart';
import '../../core/tema.dart';
import '../ticketbai/modelos.dart' show euros;

const _billetes = [500.0, 200.0, 100.0, 50.0, 20.0, 10.0, 5.0];
const _monedas = [2.0, 1.0, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01];

String _etiqueta(double v) => v >= 1 ? '${v.toStringAsFixed(0)} €' : '${(v * 100).round()} cts';
String _clave(double v) => v.toString(); // "50.0", "0.05"

/// Recuento del cajón SIN mostrar lo esperado. Devuelve {efectivo, conteo, tarjeta, nota} o null.
Future<Map<String, dynamic>?> contarCajaCiega(BuildContext context, {String? aviso}) =>
    mostrarPanel<Map<String, dynamic>>(context, (_) => _PanelCierre(aviso: aviso));

class _PanelCierre extends StatefulWidget {
  const _PanelCierre({this.aviso});
  final String? aviso;

  @override
  State<_PanelCierre> createState() => _PanelCierreState();
}

class _PanelCierreState extends State<_PanelCierre> {
  String _modo = 'piezas';
  final _cant = {for (final v in [..._billetes, ..._monedas]) v: TextEditingController()};
  final _total = TextEditingController();
  final _tarjeta = TextEditingController();
  final _nota = TextEditingController();
  String? _err;

  double? _num(String t) => t.trim().isEmpty ? 0 : double.tryParse(t.trim().replaceAll(',', '.'));

  double get _sumaPiezas {
    var s = 0.0;
    for (final e in _cant.entries) {
      s += (int.tryParse(e.value.text.trim()) ?? 0) * e.key;
    }
    return (s * 100).roundToDouble() / 100;
  }

  void _guardar() {
    final efectivo = _modo == 'piezas' ? _sumaPiezas : _num(_total.text);
    final tarjeta = _tarjeta.text.trim().isEmpty ? null : _num(_tarjeta.text);
    if (efectivo == null || efectivo < 0) return setState(() => _err = 'Revisa el total contado');
    if (_tarjeta.text.trim().isNotEmpty && (tarjeta == null || tarjeta < 0)) {
      return setState(() => _err = 'Revisa el total del datáfono');
    }
    if (_modo == 'piezas' && _cant.values.any((c) => c.text.trim().isNotEmpty && int.tryParse(c.text.trim()) == null)) {
      return setState(() => _err = 'En billetes y monedas pon cuántas piezas hay (número entero)');
    }
    Navigator.pop(context, {
      'efectivo': efectivo,
      'conteo': _modo == 'piezas'
          ? {
              for (final e in _cant.entries)
                if ((int.tryParse(e.value.text.trim()) ?? 0) > 0) _clave(e.key): int.parse(e.value.text.trim()),
            }
          : null,
      'tarjeta': tarjeta,
      'nota': _nota.text.trim(),
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

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: 'Cerrar caja',
        boton: 'Cerrar caja con ${euros(_modo == 'piezas' ? _sumaPiezas : (_num(_total.text) ?? 0))}',
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
            opciones: const {'piezas': 'Billetes y monedas', 'total': 'Solo el total'},
            actual: _modo,
            onCambio: (v) => setState(() => _modo = v),
          ),
          const SizedBox(height: 12),
          if (_modo == 'piezas') ...[
            Text('Billetes', style: titulo(16)),
            const SizedBox(height: 6),
            for (final v in _billetes) _fila(v),
            const SizedBox(height: 8),
            Text('Monedas', style: titulo(16)),
            const SizedBox(height: 6),
            for (final v in _monedas) _fila(v),
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
