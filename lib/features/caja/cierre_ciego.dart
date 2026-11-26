import 'package:flutter/material.dart';

import '../../core/panel_lateral.dart';
import '../../core/pedir_cantidad.dart';
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

  /// Botones − y +: para contar sin teclado (se puede seguir escribiendo el número).
  void _sumar(double v, int n) {
    final r = _piezas(v) + n;
    setState(() => _cant[v]!.text = r <= 0 ? '' : '$r');
  }

  /// Las casillas de números se rellenan con el teclado de la app (el TPV no tiene teclado).
  // Pantalla ancha (TPV): todo en una sola pantalla, con el teclado de números al lado.
  // Se toca una casilla y el teclado escribe en ella.
  TextEditingController? _destino;
  bool _destinoDecimal = false;
  VoidCallback? _despues;
  bool _nuevo = true; // la primera tecla sustituye lo que hubiera
  bool get _ancha => MediaQuery.sizeOf(context).width >= 1000;
  static const _marcada = Color(0xFFE3F1EC);

  void _pulsar(String d) {
    final c = _destino;
    if (c == null) return;
    var t = _nuevo ? '' : c.text.replaceAll('.', ',');
    if (d == ',') {
      if (!_destinoDecimal || t.contains(',')) return;
      if (t.isEmpty) t = '0';
    } else {
      final i = t.indexOf(',');
      if (i >= 0 && t.length - i > 2) return; // dos decimales
      if (t == '0') t = '';
    }
    if (t.length >= (_destinoDecimal ? 8 : 4)) return;
    c.text = t + d;
    _nuevo = false;
    _despues?.call();
    setState(() => _err = null);
  }

  void _borrarTecla({bool todo = false}) {
    final c = _destino;
    if (c == null) return;
    c.text = todo || c.text.isEmpty ? '' : c.text.substring(0, c.text.length - 1);
    _nuevo = false;
    _despues?.call();
    setState(() {});
  }

  Future<void> _teclear(TextEditingController c, String titulo, {bool decimal = false, VoidCallback? despues}) async {
    if (_ancha) {
      setState(() {
        _destino = c;
        _destinoDecimal = decimal;
        _despues = despues;
        _nuevo = true;
      });
      return;
    }
    if (await teclearEn(context, c, titulo: titulo, decimal: decimal) && mounted) {
      despues?.call();
      setState(() {});
    }
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
          IconButton(
            tooltip: 'Una menos',
            onPressed: _piezas(v) > 0 ? () => _sumar(v, -1) : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 70,
            child: TextField(
              controller: _cant[v],
              readOnly: true,
              onTap: () => _teclear(_cant[v]!, '¿Cuántos de ${_etiqueta(v)}?'),
              textAlign: TextAlign.center,
              decoration: InputDecoration(isDense: true, hintText: '0', filled: _destino == _cant[v], fillColor: _marcada),
            ),
          ),
          IconButton(
            tooltip: 'Una más',
            onPressed: () => _sumar(v, 1),
            icon: const Icon(Icons.add_circle_outline),
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
              readOnly: true,
              onTap: () => _teclear(_gramos[v]!, 'Gramos de ${_etiqueta(v)}', decimal: true, despues: () => _alPesar(v)),
              textAlign: TextAlign.center,
              decoration: InputDecoration(isDense: true, hintText: '0', suffixText: 'g', filled: _destino == _gramos[v], fillColor: _marcada),
            ),
          ),
          const Text('  →  ', style: TextStyle(color: C.gris)),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _cant[v],
              readOnly: true,
              onTap: () => _teclear(_cant[v]!, '¿Cuántos de ${_etiqueta(v)}?'),
              textAlign: TextAlign.center,
              decoration: InputDecoration(isDense: true, hintText: '0', suffixText: ' uds', filled: _destino == _cant[v], fillColor: _marcada),
            ),
          ),
          const Spacer(),
          Text(euros(_piezas(v) * v), style: const TextStyle(color: C.gris)),
        ]),
      );

  /// TPV: monedas y billetes en dos columnas, y a la derecha el teclado, los totales y el botón.
  Widget _unaPantalla() {
    final total = _porPiezas ? _sumaPiezas : (_num(_total.text) ?? 0);
    Widget campo(TextEditingController c, String etiqueta, String titulo, {String? pista}) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextField(
            controller: c,
            readOnly: true,
            onTap: () => _teclear(c, titulo, decimal: true),
            decoration: InputDecoration(
              labelText: etiqueta,
              hintText: pista,
              suffixText: '€',
              isDense: true,
              filled: _destino == c,
              fillColor: _marcada,
            ),
          ),
        );
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: C.blanco,
        child: SizedBox(
          width: 1060,
          height: double.infinity,
          child: SafeArea(
            minimum: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 12, 0),
                child: Row(children: [
                  Text('Cerrar caja', style: titulo(26)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                        widget.aviso ?? 'Cuenta todo el efectivo del cajón (fondo incluido). Una vez cerrada no se puede cambiar.',
                        style: TextStyle(
                            color: widget.aviso != null ? C.naranja : C.gris,
                            fontSize: 13,
                            fontWeight: widget.aviso != null ? FontWeight.w700 : FontWeight.w400)),
                  ),
                  IconButton(tooltip: 'Cerrar', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ]),
              ),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Izquierda: lo que se cuenta
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 12, 16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Segmentos(
                          opciones: const {'piezas': 'Billetes y monedas', 'peso': 'Monedas por peso', 'total': 'Solo el total'},
                          actual: _modo,
                          onCambio: (v) => setState(() {
                            _modo = v;
                            _destino = v == 'total' ? _total : null;
                            _destinoDecimal = true;
                            _despues = null;
                            _nuevo = true;
                          }),
                        ),
                        const SizedBox(height: 10),
                        if (_modo == 'piezas')
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('Billetes', style: titulo(16)),
                                const SizedBox(height: 6),
                                for (final v in _billetes) _fila(v),
                              ]),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('Monedas', style: titulo(16)),
                                const SizedBox(height: 6),
                                for (final v in _monedas) _fila(v),
                              ]),
                            ),
                          ])
                        else if (_modo == 'peso') ...[
                          const Text('Pesa cada tipo de moneda por separado y marca los gramos: las unidades se calculan solas.',
                              style: TextStyle(color: C.gris, fontSize: 13)),
                          const SizedBox(height: 6),
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(
                              flex: 5,
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('Monedas', style: titulo(16)),
                                const SizedBox(height: 6),
                                for (final v in _monedas) _filaPeso(v),
                              ]),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              flex: 4,
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('Billetes', style: titulo(16)),
                                const SizedBox(height: 6),
                                for (final v in _billetes) _fila(v),
                              ]),
                            ),
                          ]),
                        ] else
                          campo(_total, 'Efectivo contado', 'Efectivo contado'),
                        const EtiquetaCampo('Nota (opcional)'),
                        TextField(
                            controller: _nota,
                            decoration: const InputDecoration(isDense: true, hintText: 'Ej. pagué 20 € al repartidor sin apuntarlo')),
                      ]),
                    ),
                  ),
                  // Derecha: totales, teclado y cerrar
                  SizedBox(
                    width: 300,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 24, 16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(color: _marcada, borderRadius: BorderRadius.circular(14)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Total contado', style: TextStyle(color: C.gris, fontWeight: FontWeight.w600)),
                            Text(euros(total), style: titulo(30, color: C.verde)),
                          ]),
                        ),
                        const SizedBox(height: 8),
                        TecladoNumeros(
                          activo: _destino != null,
                          coma: _destinoDecimal,
                          alPulsar: _pulsar,
                          alBorrar: _borrarTecla,
                          alLimpiar: () => _borrarTecla(todo: true),
                        ),
                        if (_destino == null)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text('Toca una casilla y marca la cantidad.', style: TextStyle(color: C.gris, fontSize: 13)),
                          ),
                        campo(_fondo, 'Dejo de fondo en el cajón', 'Dejo de fondo'),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(children: [
                            Text('Retirar', style: titulo(16)),
                            const Spacer(),
                            Text(euros(_retirar), style: titulo(20, color: C.verde)),
                          ]),
                        ),
                        campo(_tarjeta, 'Total del datáfono (opcional)', 'Total del datáfono'),
                        if (_err != null) ...[
                          const SizedBox(height: 8),
                          Text(_err!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
                        ],
                        const SizedBox(height: 10),
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                          onPressed: _guardar,
                          child: Text('Cerrar caja con ${euros(total)}', style: const TextStyle(fontSize: 16)),
                        ),
                      ]),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _ancha ? _unaPantalla() : PanelLateral(
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
              readOnly: true,
              onTap: () => _teclear(_total, 'Efectivo contado', decimal: true),
              decoration: const InputDecoration(labelText: 'Efectivo contado', suffixText: '€'),
            ),
          const EtiquetaCampo('Dejo de fondo en el cajón'),
          TextField(
            controller: _fondo,
            readOnly: true,
            onTap: () => _teclear(_fondo, 'Dejo de fondo', decimal: true),
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
            readOnly: true,
            onTap: () => _teclear(_tarjeta, 'Total del datáfono', decimal: true),
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
