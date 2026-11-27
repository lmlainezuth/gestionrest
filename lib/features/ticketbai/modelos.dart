/// Línea de factura. El precio unitario lleva el IVA incluido.
class LineaFactura {
  final String descripcion;
  final double cantidad;
  final double precioUnitario;
  final double tipoIva; // 10 hostelería; 21 / 4 en ventas para llevar

  const LineaFactura(this.descripcion, this.cantidad, this.precioUnitario, [this.tipoIva = 10]);

  double get total => _r2(cantidad * precioUnitario);

  Map<String, dynamic> toMap() => {
        'descripcion': descripcion,
        'cantidad': cantidad,
        'precio_unitario': precioUnitario,
        'total': total,
        'tipo_iva': tipoIva,
      };

  factory LineaFactura.fromMap(Map<String, dynamic> m) => LineaFactura(
        m['descripcion'] as String,
        (m['cantidad'] as num).toDouble(),
        (m['precio_unitario'] as num).toDouble(),
        ((m['tipo_iva'] as num?) ?? 10).toDouble(),
      );
}

/// Tramo del desglose: base y cuota de un tipo de IVA.
class TramoIva {
  final double tipo;
  final double base;
  final double cuota;
  const TramoIva(this.tipo, this.base, this.cuota);
  double get total => _r2(base + cuota);
  Map<String, dynamic> toMap() => {'tipo': tipo, 'base': base, 'cuota': cuota};
}

/// Desglose de IVA (uno o varios tipos) a partir de precios con IVA incluido.
class Desglose {
  final double total;
  final double base;
  final double cuota;
  final List<TramoIva> tramos; // ordenados de menor a mayor tipo

  Desglose._(this.total, this.base, this.cuota, this.tramos);

  /// Tipo principal (el de mayor importe): se guarda en facturas.tipo_iva.
  double get tipoIva => tramos.isEmpty
      ? 10
      : tramos.reduce((a, b) => a.total.abs() >= b.total.abs() ? a : b).tipo;

  factory Desglose.de(List<LineaFactura> lineas) {
    final porTipo = <double, double>{};
    for (final l in lineas) {
      porTipo[l.tipoIva] = (porTipo[l.tipoIva] ?? 0) + l.total;
    }
    final tipos = porTipo.keys.toList()..sort();
    final tramos = [
      for (final t in tipos)
        () {
          final tot = _r2(porTipo[t]!);
          final base = _r2(tot / (1 + t / 100));
          return TramoIva(t, base, _r2(tot - base));
        }(),
    ];
    final total = _r2(tramos.fold(0.0, (s, t) => s + t.total));
    return Desglose._(
      total,
      _r2(tramos.fold(0.0, (s, t) => s + t.base)),
      _r2(tramos.fold(0.0, (s, t) => s + t.cuota)),
      tramos,
    );
  }

  /// Desglose guardado en una factura (facturas.desglose_iva o, si es antigua, sus columnas).
  static List<TramoIva> deFactura(Map<String, dynamic> f) {
    final d = f['desglose_iva'] as List?;
    if (d == null || d.isEmpty) {
      return [
        TramoIva((f['tipo_iva'] as num).toDouble(), (f['base_imponible'] as num).toDouble(),
            (f['cuota_iva'] as num).toDouble()),
      ];
    }
    return [
      for (final m in d.cast<Map>())
        TramoIva((m['tipo'] as num).toDouble(), (m['base'] as num).toDouble(), (m['cuota'] as num).toDouble()),
    ];
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

/// Pie del ticket cuando la cuenta se pagó a partes iguales («Entre N» en el cobro).
/// Solo al cobrar: el reparto no se guarda, así que una reimpresión posterior no lo lleva.
String? textoEntre(Map<String, dynamic> f) {
  final n = f['entre'];
  if (n is! int || n < 2) return null;
  final parte = ((f['importe_total'] as num) / n * 100).ceilToDouble() / 100;
  return 'Pagado entre $n · ${euros(parte)} por persona';
}
