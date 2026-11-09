/// Línea de factura. El precio unitario lleva el IVA incluido.
class LineaFactura {
  final String descripcion;
  final double cantidad;
  final double precioUnitario;

  const LineaFactura(this.descripcion, this.cantidad, this.precioUnitario);

  double get total => _r2(cantidad * precioUnitario);

  Map<String, dynamic> toMap() => {
        'descripcion': descripcion,
        'cantidad': cantidad,
        'precio_unitario': precioUnitario,
        'total': total,
      };

  factory LineaFactura.fromMap(Map<String, dynamic> m) => LineaFactura(
        m['descripcion'] as String,
        (m['cantidad'] as num).toDouble(),
        (m['precio_unitario'] as num).toDouble(),
      );
}

/// Desglose de IVA a partir de precios con IVA incluido.
class Desglose {
  final double total;
  final double base;
  final double cuota;
  final double tipoIva;

  Desglose._(this.total, this.base, this.cuota, this.tipoIva);

  factory Desglose.de(List<LineaFactura> lineas, double tipoIva) {
    final total = _r2(lineas.fold(0.0, (s, l) => s + l.total));
    final base = _r2(total / (1 + tipoIva / 100));
    return Desglose._(total, base, _r2(total - base), tipoIva);
  }
}

/// Factura anterior de la serie, para el encadenamiento.
class FacturaAnterior {
  final String serie;
  final int numero;
  final DateTime fecha;
  final String signatureValue;

  const FacturaAnterior(this.serie, this.numero, this.fecha, this.signatureValue);

  String get firma100 => signatureValue.length > 100
      ? signatureValue.substring(0, 100)
      : signatureValue;
}

double _r2(double v) => (v * 100).roundToDouble() / 100;

/// 78.4 -> "78,40 €"
String euros(num v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} €';
