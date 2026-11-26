import 'package:flutter/material.dart';

import 'tema.dart';

/// Teclado numérico para marcar una cantidad de golpe (15 cervezas = 3 toques, no 15).
/// Devuelve la cantidad (0 incluido si [permiteCero]) o null si se cancela.
Future<int?> pedirCantidad(BuildContext context, {required String titulo, bool permiteCero = false}) async {
  final t = await showDialog<String>(context: context, builder: (_) => _TecladoCantidad(titulo, permiteCero));
  return t == null ? null : int.tryParse(t);
}

/// El mismo teclado para rellenar una casilla (piezas, gramos o euros) sin teclado del sistema:
/// escribe el resultado en [campo]. [decimal]: con coma para céntimos o gramos.
/// Devuelve true si se cambió. Úsalo con `readOnly: true` y `onTap` en el TextField.
Future<bool> teclearEn(BuildContext context, TextEditingController campo,
    {required String titulo, bool decimal = false}) async {
  final t = await showDialog<String>(
      context: context, builder: (_) => _TecladoCantidad(titulo, true, decimal: decimal, largo: decimal ? 8 : 4));
  if (t == null) return false;
  campo.text = t == '0' && !decimal ? '' : t;
  return true;
}

class _TecladoCantidad extends StatefulWidget {
  const _TecladoCantidad(this.titulo, this.permiteCero, {this.decimal = false, this.largo = 3});
  final String titulo;
  final bool permiteCero;
  final bool decimal;
  final int largo;

  @override
  State<_TecladoCantidad> createState() => _TecladoCantidadState();
}

class _TecladoCantidadState extends State<_TecladoCantidad> {
  String _txt = '';

  double get _valor => double.tryParse(_txt.replaceAll(',', '.')) ?? 0;
  bool get _vale => _txt.isNotEmpty && (_valor > 0 || widget.permiteCero);

  void _tecla(String d) {
    if (_txt.length >= widget.largo) return; // cantidades: hasta 999
    if (d == ',') {
      if (_txt.contains(',')) return;
      if (_txt.isEmpty) _txt = '0';
    } else {
      final i = _txt.indexOf(',');
      if (i >= 0 && _txt.length - i > 2) return; // dos decimales
      if (_txt == '0') _txt = '';
    }
    setState(() => _txt += d);
  }

  /// Sin coma colgando ni ceros de más: "12," → "12".
  String get _limpio => _txt.endsWith(',') ? _txt.substring(0, _txt.length - 1) : _txt;

  Widget _boton(Widget hijo, VoidCallback? alPulsar, {bool principal = false}) => Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          width: 76,
          height: 60,
          child: principal
              ? FilledButton(onPressed: alPulsar, style: FilledButton.styleFrom(padding: EdgeInsets.zero), child: hijo)
              : OutlinedButton(onPressed: alPulsar, style: OutlinedButton.styleFrom(padding: EdgeInsets.zero), child: hijo),
        ),
      );

  @override
  Widget build(BuildContext context) {
    Widget digito(String d) => _boton(Text(d, style: titulo(22)), () => _tecla(d));
    return AlertDialog(
      title: Text(widget.titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_txt.isEmpty ? '–' : _txt, style: titulo(44, color: _txt.isEmpty ? C.gris : C.verde)),
        const SizedBox(height: 8),
        for (final fila in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
          Row(mainAxisSize: MainAxisSize.min, children: [for (final d in fila) digito(d)]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _boton(const Icon(Icons.backspace_outlined),
              _txt.isEmpty ? null : () => setState(() => _txt = _txt.substring(0, _txt.length - 1))),
          digito('0'),
          _boton(const Icon(Icons.check, color: C.sobreAccion), _vale ? () => Navigator.pop(context, _limpio) : null,
              principal: true),
        ]),
        if (widget.decimal) Row(mainAxisSize: MainAxisSize.min, children: [digito(',')]),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar'))],
    );
  }
}

/// Cajita de números para poner dentro de una pantalla (sin ventana aparte): escribe donde
/// diga quien la usa. [coma]: con tecla de coma para céntimos o gramos.
class TecladoNumeros extends StatelessWidget {
  const TecladoNumeros({super.key, required this.alPulsar, required this.alBorrar, required this.alLimpiar, this.coma = true, this.activo = true});
  final ValueChanged<String> alPulsar;
  final VoidCallback alBorrar, alLimpiar;
  final bool coma;
  final bool activo; // false: aún no se ha elegido casilla

  Widget _tecla(Widget hijo, VoidCallback? alTocar, {VoidCallback? alMantener}) => Expanded(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: alTocar == null ? C.crema : C.blanco,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: C.bordeFuerte)),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              canRequestFocus: false,
              onTap: alTocar,
              onLongPress: alTocar == null ? null : alMantener,
              child: SizedBox(height: 56, child: Center(child: hijo)),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    Widget tecla(String d, {bool vale = true}) =>
        _tecla(Text(d, style: titulo(24, color: activo && vale ? C.tinta : C.gris)), activo && vale ? () => alPulsar(d) : null);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final fila in const [['7', '8', '9'], ['4', '5', '6'], ['1', '2', '3']])
        Row(children: [for (final d in fila) tecla(d)]),
      Row(children: [
        tecla(',', vale: coma),
        tecla('0'),
        _tecla(const Icon(Icons.backspace_outlined), activo ? alBorrar : null, alMantener: alLimpiar), // mantener: borra todo
      ]),
    ]);
  }
}
