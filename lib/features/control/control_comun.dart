import '../../core/tema.dart';
import 'package:flutter/material.dart';

const tiposAnulacion = <String, ({String texto, IconData icono})>{
  'linea_anulada': (texto: 'Producto anulado', icono: Icons.remove_circle_outline),
  'linea_borrada': (texto: 'Producto borrado', icono: Icons.delete_forever_outlined),
  'pedido_anulado': (texto: 'Cuenta anulada', icono: Icons.cancel_outlined),
  'venta_anulada': (texto: 'Venta cobrada anulada', icono: Icons.money_off),
  'factura_anulada': (texto: 'Factura anulada', icono: Icons.block),
  'devolucion': (texto: 'Devolución', icono: Icons.undo),
  'quitado_antes_cobrar': (texto: 'Eliminado antes de cobrar (Barra)', icono: Icons.exposure_minus_1),
};

const estadosCocina = {
  'pendiente': 'sin empezar',
  'preparando': 'en preparación',
  'listo': 'ya preparado',
  'servido': 'ya servido',
};

const rojo = Color(0xFFB3261E);

/// Más grave lo que ya estaba hecho o cobrado.
Color colorAnulacion(Map<String, dynamic> a) => switch (a['tipo']) {
      'venta_anulada' || 'factura_anulada' || 'linea_borrada' => rojo,
      'linea_anulada' when a['estado_cocina'] == 'listo' || a['estado_cocina'] == 'servido' => C.naranja,
      _ => C.gris,
    };

/// Nada de lo que falle por una tabla aún no creada debe tumbar la pantalla.
Future<List<Map<String, dynamic>>> seguro(Future<dynamic> f) async {
  try {
    return List<Map<String, dynamic>>.from(await f as List);
  } catch (_) {
    return [];
  }
}

String hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
