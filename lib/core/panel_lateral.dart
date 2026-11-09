import 'package:flutter/material.dart';

import 'tema.dart';

/// Abre un formulario como panel que entra por la derecha (a pantalla completa en pantallas estrechas).
Future<T?> mostrarPanel<T>(BuildContext context, WidgetBuilder builder) => showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, _, __) => builder(ctx),
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );

/// Esqueleto del panel: título y cerrar arriba, contenido con scroll y botón principal abajo.
class PanelLateral extends StatelessWidget {
  const PanelLateral({
    super.key,
    required this.encabezado,
    required this.cuerpo,
    required this.boton,
    this.onBoton,
    this.onBorrar,
    this.textoBorrar = 'Borrar',
  });
  final String encabezado;
  final Widget cuerpo;
  final String boton;
  final VoidCallback? onBoton;
  final VoidCallback? onBorrar;
  final String textoBorrar;

  @override
  Widget build(BuildContext context) {
    final ancho = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: C.blanco,
        child: SizedBox(
          width: ancho < 600 ? ancho : 460,
          height: double.infinity,
          child: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 12, 4),
                child: Row(children: [
                  Expanded(child: Text(encabezado, style: titulo(26))),
                  IconButton(tooltip: 'Cerrar', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ]),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  child: cuerpo,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
                child: Column(children: [
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                    onPressed: onBoton,
                    child: Text(boton, style: const TextStyle(fontSize: 16)),
                  ),
                  if (onBorrar != null)
                    TextButton.icon(
                      onPressed: onBorrar,
                      icon: const Icon(Icons.delete_outline, color: Color(0xFFB3261E)),
                      label: Text(textoBorrar, style: const TextStyle(color: Color(0xFFB3261E))),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Título de un campo del formulario.
class EtiquetaCampo extends StatelessWidget {
  const EtiquetaCampo(this.texto, {super.key});
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(texto, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      );
}

/// Botones grandes tipo píldora para elegir una opción (categoría, IVA, estado…).
class Segmentos extends StatelessWidget {
  const Segmentos({super.key, required this.opciones, required this.actual, required this.onCambio});
  final Map<String, String> opciones;
  final String actual;
  final ValueChanged<String> onCambio;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: C.crema, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          for (final o in opciones.entries)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onCambio(o.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: actual == o.key ? C.blanco : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: actual == o.key
                        ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))]
                        : null,
                  ),
                  child: Text(
                    o.value,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w600, color: actual == o.key ? C.verde : C.gris),
                  ),
                ),
              ),
            ),
        ]),
      );
}

/// Etiqueta pequeña de estado (Pagado, Debe, Cerrada…).
class EtiquetaEstado extends StatelessWidget {
  const EtiquetaEstado(this.texto, {super.key, required this.aviso});
  final String texto;
  final bool aviso;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: aviso ? const Color(0xFFFDF0DC) : const Color(0xFFE3F1EC),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(texto,
            style: TextStyle(color: aviso ? const Color(0xFFB45309) : C.verde, fontWeight: FontWeight.w700, fontSize: 12.5)),
      );
}

/// Tarjeta de fila de lista, con borde suave y toque.
class TarjetaFila extends StatelessWidget {
  const TarjetaFila({super.key, required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: C.blanco,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: C.borde)),
            child: child,
          ),
        ),
      );
}

/// Icono cuadrado de color suave al inicio de una fila.
class IconoFila extends StatelessWidget {
  const IconoFila(this.icono, this.color, {super.key});
  final IconData icono;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
        child: Icon(icono, color: color),
      );
}
