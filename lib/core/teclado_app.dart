import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tema.dart';

/// Teclado en pantalla de la propia app, para TODOS los campos de escribir: el TPV no tiene
/// teclado. Sale solo al tocar cualquier casilla (números o letras) y escribe en ella, así que
/// no hay que cambiar nada en cada pantalla. Va puesto en el `builder` de MaterialApp.
/// En la web (tablets de gestión) no se usa: ahí escribe el teclado del propio dispositivo.
class TecladoApp extends StatefulWidget {
  const TecladoApp({super.key, required this.child});
  final Widget child;

  /// Se puede apagar en un equipo con teclado físico.
  static bool activo = !kIsWeb;

  @override
  State<TecladoApp> createState() => _TecladoAppState();
}

class _TecladoAppState extends State<TecladoApp> {
  static const _altoTecla = 52.0, _hueco = 6.0;
  EditableTextState? _campo;
  bool _mayus = false;
  bool? _numeros; // null = según el tipo de casilla; el usuario puede cambiarlo con 123 / ABC

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_alCambiarFoco);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_alCambiarFoco);
    super.dispose();
  }

  void _alCambiarFoco() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    var e = ctx?.findAncestorStateOfType<EditableTextState>();
    // Sin teclado general: casillas de solo lectura y las que traen el suyo (TextInputType.none)
    if (e != null && (e.widget.readOnly || e.widget.keyboardType == TextInputType.none || !TecladoApp.activo)) e = null;
    if (identical(e, _campo)) return;
    final nuevo = e;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _campo = nuevo;
        _mayus = false;
        _numeros = null;
        _numeros = nuevo == null ? null : _esNumerico;
      });
      if (nuevo == null) return;
      _ocultarTecladoDelSistema();
      // Que la casilla no quede tapada por el teclado
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!nuevo.mounted) return;
        final v = nuevo.textEditingValue;
        nuevo.bringIntoView(v.selection.isValid ? v.selection.extent : TextPosition(offset: v.text.length));
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _ocultarTecladoDelSistema() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }

  EditableTextState? get _vivo => (_campo?.mounted ?? false) ? _campo : null;

  bool get _esNumerico {
    if (_numeros != null) return _numeros!;
    final c = _vivo;
    if (c == null) return false;
    final t = c.widget.keyboardType;
    if (t.index == TextInputType.number.index || t.index == TextInputType.phone.index) return true;
    // Casillas de importe que no dicen su tipo: se reconocen por la unidad (€, g, %…) o porque
    // ya traen un número escrito (5,00). Las vacías y las de texto abren el de letras.
    final unidad = c.context.findAncestorWidgetOfExactType<TextField>()?.decoration?.suffixText?.trim();
    if (unidad != null && const {'€', 'g', '%', 'kg', 'uds', 'ud', 'min'}.contains(unidad)) return true;
    return RegExp(r'^[0-9]+([.,][0-9]*)?$').hasMatch(c.textEditingValue.text.trim());
  }

  void _escribir(String s) {
    final c = _vivo;
    if (c == null) return;
    final v = c.textEditingValue;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    c.userUpdateTextEditingValue(
      TextEditingValue(
        text: v.text.replaceRange(sel.start, sel.end, s),
        selection: TextSelection.collapsed(offset: sel.start + s.length),
      ),
      SelectionChangedCause.keyboard,
    );
    if (_mayus) setState(() => _mayus = false);
  }

  void _borrar({bool todo = false}) {
    final c = _vivo;
    if (c == null) return;
    final v = c.textEditingValue;
    if (todo) {
      c.userUpdateTextEditingValue(const TextEditingValue(selection: TextSelection.collapsed(offset: 0)), SelectionChangedCause.keyboard);
      return;
    }
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final desde = sel.isCollapsed ? math.max(0, sel.start - 1) : sel.start;
    if (desde == sel.end) return;
    c.userUpdateTextEditingValue(
      TextEditingValue(text: v.text.replaceRange(desde, sel.end, ''), selection: TextSelection.collapsed(offset: desde)),
      SelectionChangedCause.keyboard,
    );
  }

  void _cerrar() => FocusManager.instance.primaryFocus?.unfocus();

  void _intro() {
    final c = _vivo;
    if (c == null) return;
    if (c.widget.maxLines != 1) return _escribir('\n'); // casilla de varias líneas
    c.widget.onSubmitted?.call(c.textEditingValue.text);
    if (identical(_vivo, c)) _cerrar();
  }

  // ---------- Teclas ----------

  Widget _tecla(Widget hijo, VoidCallback alPulsar, {int ancho = 2, Color? fondo, VoidCallback? alMantener}) => Expanded(
        flex: ancho,
        child: Padding(
          padding: const EdgeInsets.all(_hueco / 2),
          child: Material(
            color: fondo ?? const Color(0xFF3A3834),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              canRequestFocus: false,
              onTap: alPulsar,
              onLongPress: alMantener,
              child: SizedBox(height: _altoTecla, child: Center(child: hijo)),
            ),
          ),
        ),
      );

  static const _claro = Color(0xFFF6F4EF);
  Widget _txt(String t, {double tam = 22}) =>
      Text(t, style: TextStyle(color: _claro, fontSize: tam, fontWeight: FontWeight.w600));

  static const _acentos = {'a': 'á', 'e': 'é', 'i': 'í', 'o': 'ó', 'u': 'ú', 'n': 'ñ'};

  Widget _letra(String l) {
    final v = _mayus ? l.toUpperCase() : l;
    final ac = _acentos[l];
    return _tecla(_txt(v), () => _escribir(v),
        alMantener: ac == null ? null : () => _escribir(_mayus ? ac.toUpperCase() : ac)); // mantener: á é í ó ú
  }

  Widget _car(String c, {int ancho = 2}) => _tecla(_txt(c), () => _escribir(c), ancho: ancho);
  Widget _fila(List<Widget> teclas) => Row(children: teclas);
  Widget get _borrarTecla => _tecla(const Icon(Icons.backspace_outlined, color: _claro), _borrar,
      ancho: 3, alMantener: () => _borrar(todo: true)); // mantener: borra todo
  Widget get _ok =>
      _tecla(const Icon(Icons.check, color: Colors.white), _intro, ancho: 3, fondo: C.verde);
  Widget get _ocultar =>
      _tecla(const Icon(Icons.keyboard_hide_outlined, color: _claro), _cerrar, ancho: 2);

  Widget _numerico() => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _fila([_car('1', ancho: 3), _car('2', ancho: 3), _car('3', ancho: 3), _borrarTecla]),
          _fila([_car('4', ancho: 3), _car('5', ancho: 3), _car('6', ancho: 3), _car(',', ancho: 3)]),
          _fila([_car('7', ancho: 3), _car('8', ancho: 3), _car('9', ancho: 3), _car('-', ancho: 3)]),
          _fila([
            _tecla(_txt('ABC', tam: 16), () => setState(() => _numeros = false), ancho: 3),
            _car('0', ancho: 3),
            _tecla(const Icon(Icons.keyboard_hide_outlined, color: _claro), _cerrar, ancho: 3),
            _ok,
          ]),
        ]),
      );

  Widget _letras() => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _fila([for (final c in '1234567890'.split('')) _car(c)]),
          _fila([for (final l in 'qwertyuiop'.split('')) _letra(l)]),
          _fila([for (final l in 'asdfghjklñ'.split('')) _letra(l)]),
          _fila([
            _tecla(Icon(Icons.arrow_upward, color: _mayus ? C.naranja : _claro), () => setState(() => _mayus = !_mayus), ancho: 3),
            for (final l in 'zxcvbnm'.split('')) _letra(l),
            _borrarTecla,
          ]),
          _fila([
            _tecla(_txt('123', tam: 16), () => setState(() => _numeros = true), ancho: 3),
            _car('@'),
            _car(','),
            _tecla(_txt('espacio', tam: 15), () => _escribir(' '), ancho: 6),
            _car('.'),
            _car('-'),
            _ocultar,
            _ok,
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final visible = _vivo != null;
    final esNum = visible && _esNumerico;
    final alto = !visible ? 0.0 : (esNum ? 4 : 5) * (_altoTecla + _hueco) + 16;
    final mq = MediaQuery.of(context);
    return Listener(
      // Si Android saca su teclado al volver a tocar la casilla, se quita: escribe el de la app
      onPointerUp: (_) {
        if (visible) WidgetsBinding.instance.addPostFrameCallback((_) => _ocultarTecladoDelSistema());
      },
      child: Stack(children: [
        Positioned.fill(
          // La app cree que hay un teclado abajo: ventanas y listas suben para no quedar tapadas
          child: MediaQuery(
            data: mq.copyWith(viewInsets: mq.viewInsets.copyWith(bottom: math.max(mq.viewInsets.bottom, alto))),
            child: widget.child,
          ),
        ),
        if (visible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: alto,
            child: TextFieldTapRegion(
              // tocar una tecla no cuenta como «tocar fuera» de la casilla (no pierde el foco)
              child: ExcludeFocus(
                child: Material(
                  color: C.panel,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Center(child: esNum ? _numerico() : _letras()),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
