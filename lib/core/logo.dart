import 'dart:math' as math;

import 'package:flutter/material.dart';

/// El logo de GestiónRest (la G con forma de plato sobre verde), dibujado: el mismo del icono de la app.
class LogoGestionRest extends StatelessWidget {
  const LogoGestionRest({super.key, this.tam = 44});
  final double tam;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: tam, child: CustomPaint(painter: _LogoPintor()));
}

class _LogoPintor extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide, u = s / 100;
    final fondo = Offset.zero & Size(s, s);
    canvas.drawRRect(
      RRect.fromRectAndRadius(fondo, Radius.circular(s * 0.225)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF188A70), Color(0xFF0A453A)],
        ).createShader(fondo),
    );
    final c = Offset(s / 2 - 1.5 * u, s / 2);
    final grosor = 13.5 * u, radio = 33 * u - grosor / 2;
    const grados = math.pi / 180;
    // La G: un aro (el plato) abierto por la derecha
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: radio),
      42 * grados,
      280 * grados,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = grosor
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFF6F4EF),
    );
    // La barra de la G, en naranja
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(c.dx - 2 * u, c.dy - grosor / 2 + 2 * u, c.dx + 36 * u, c.dy + grosor / 2 + 2 * u),
        Radius.circular(grosor / 2),
      ),
      Paint()..color = const Color(0xFFE8742A),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
