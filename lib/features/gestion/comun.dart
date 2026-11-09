import 'package:flutter/material.dart';

import '../../core/tema.dart';

const categorias = {'fijos': 'Fijos', 'materia': 'Materia prima', 'otros': 'Otros'};
const coloresCategoria = {'fijos': Color(0xFF2F6DB5), 'materia': Color(0xFF0F5C4D), 'otros': Color(0xFFE8742A)};
const tiposIva = ['0', '4', '10', '21', 'mixto'];
const meses = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];

String iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String fechaCorta(String isoFecha) {
  final p = isoFecha.split('-');
  return '${p[2]}/${p[1]}';
}

/// Primer y último día (yyyy-mm-dd) del mes.
(String, String) rangoMes(DateTime mes) =>
    (iso(DateTime(mes.year, mes.month, 1)), iso(DateTime(mes.year, mes.month + 1, 0)));

/// IVA de una factura de gasto (importe con IVA incluido).
double ivaGasto(Map<String, dynamic> g) {
  if (g['iva_tipo'] == 'mixto') return (g['iva_importe'] as num?)?.toDouble() ?? 0;
  final t = double.parse(g['iva_tipo'] as String);
  final imp = (g['importe'] as num).toDouble();
  return imp * t / (100 + t);
}

/// Flechas para pasar de mes.
class SelectorMes extends StatelessWidget {
  const SelectorMes({super.key, required this.mes, required this.onCambio});
  final DateTime mes;
  final ValueChanged<DateTime> onCambio;

  @override
  Widget build(BuildContext context) {
    final hoy = DateTime.now();
    final esActual = mes.year == hoy.year && mes.month == hoy.month;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'Mes anterior',
        onPressed: () => onCambio(DateTime(mes.year, mes.month - 1)),
        icon: const Icon(Icons.chevron_left),
      ),
      SizedBox(
        width: 170,
        child: Text('${meses[mes.month - 1][0].toUpperCase()}${meses[mes.month - 1].substring(1)} ${mes.year}',
            textAlign: TextAlign.center, style: titulo(18)),
      ),
      IconButton(
        tooltip: 'Mes siguiente',
        onPressed: esActual ? null : () => onCambio(DateTime(mes.year, mes.month + 1)),
        icon: const Icon(Icons.chevron_right),
      ),
    ]);
  }
}

/// Tarjeta de cifra grande.
class Cifra extends StatelessWidget {
  const Cifra(this.etiqueta, this.valor, {super.key, this.detalle, this.destacada = false, this.color});
  final String etiqueta;
  final String valor;
  final String? detalle;
  final bool destacada;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = destacada ? Colors.white : C.tinta;
    return Container(
      width: 230,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: destacada ? C.verde : C.blanco,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: destacada ? C.verde : C.borde),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(etiqueta, style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 13)),
        const SizedBox(height: 6),
        Text(valor, style: titulo(26, color: color ?? fg)),
        if (detalle != null) Text(detalle!, style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12)),
      ]),
    );
  }
}

/// Lee todas las filas de una consulta, de 1000 en 1000 (Supabase corta en 1000).
Future<List<Map<String, dynamic>>> leerTodo(Future<List<dynamic>> Function(int desde, int hasta) consulta) async {
  const lote = 1000;
  final todo = <Map<String, dynamic>>[];
  for (var i = 0;; i += lote) {
    final r = await consulta(i, i + lote - 1);
    todo.addAll(r.cast<Map<String, dynamic>>());
    if (r.length < lote) break;
  }
  return todo;
}
