import 'package:flutter/material.dart';

/// Paleta de grupos de la propuesta de diseño.
const coloresGrupo = ['#E9DFC9', '#F7C9A6', '#F2D59A', '#E8B8A8', '#BFD8E8', '#D9CFE6', '#C8E0C4'];

Color colorDe(String? hex) {
  if (hex == null || hex.length != 7) return const Color(0xFFE6E1D6);
  return Color(int.parse('FF${hex.substring(1)}', radix: 16));
}

/// "12,5" o "12.5" -> 12.5
double? leerImporte(String texto) => double.tryParse(texto.trim().replaceAll(',', '.'));
