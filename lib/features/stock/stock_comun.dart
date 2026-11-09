import 'package:flutter/material.dart';

import '../../core/tema.dart';

const unidades = {'ud': 'Unidades', 'kg': 'Kilos', 'l': 'Litros'};

const tiposMovimiento = <String, ({String texto, IconData icono, Color color})>{
  'venta': (texto: 'Venta', icono: Icons.point_of_sale, color: C.gris),
  'anulacion': (texto: 'Venta anulada', icono: Icons.undo, color: C.reserva),
  'entrada': (texto: 'Entrada', icono: Icons.move_to_inbox_outlined, color: C.verde),
  'merma': (texto: 'Merma', icono: Icons.delete_outline, color: Color(0xFFB3261E)),
  'recuento': (texto: 'Recuento', icono: Icons.fact_check_outlined, color: C.naranja),
};

/// 3 → "3", 0.05 → "0,05", 2.5 → "2,5".
String cantidad(num v) {
  var s = v.toStringAsFixed(3);
  s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s.replaceAll('.', ',');
}

/// "12 ud", "1,5 kg".
String conUnidad(num v, String unidad) => '${cantidad(v)} $unidad';

/// Lee un número escrito con coma o punto. Vacío o mal escrito → null.
double? leerNumero(String t) => double.tryParse(t.trim().replaceAll(',', '.'));

double num0(Object? v) => (v as num?)?.toDouble() ?? 0;

/// Lo que conviene pedir: hasta el doble del mínimo.
double sugerido(Map<String, dynamic> a) {
  final falta = num0(a['minimo']) * 2 - num0(a['stock']);
  if (falta <= 0) return 0;
  return a['unidad'] == 'ud' ? falta.ceilToDouble() : falta;
}

bool bajoMinimo(Map<String, dynamic> a) => num0(a['minimo']) > 0 && num0(a['stock']) <= num0(a['minimo']);
