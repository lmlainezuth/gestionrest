import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'modelos.dart';

/// Factura simplificada tal como sale impresa (80 mm).
class TicketView extends StatelessWidget {
  const TicketView({super.key, required this.factura});
  final Map<String, dynamic> factura;

  @override
  Widget build(BuildContext context) {
    final fecha = DateTime.parse(factura['fecha'] as String).toLocal();
    String dos(int n) => n.toString().padLeft(2, '0');
    final lineas = (factura['lineas'] as List)
        .map((m) => LineaFactura.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    const mono = TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.5, color: Colors.black);
    final negrita = mono.copyWith(fontWeight: FontWeight.bold);
    Widget fila(String a, String b, [TextStyle? s]) => Row(
          children: [Expanded(child: Text(a, style: s ?? mono)), Text(b, style: s ?? mono)],
        );
    const linea = Divider(color: Colors.black54, height: 20);

    return Container(
      width: 302,
      color: Colors.white,
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(factura['razon_social_emisor'] as String,
              textAlign: TextAlign.center, style: negrita.copyWith(fontSize: 14)),
          Text('NIF ${factura['nif_emisor']}', textAlign: TextAlign.center, style: mono),
          linea,
          Text('FACTURA SIMPLIFICADA', style: negrita),
          Text('Nº ${factura['serie']}-${factura['numero']}', style: mono),
          Text('${dos(fecha.day)}/${dos(fecha.month)}/${fecha.year} '
              '${dos(fecha.hour)}:${dos(fecha.minute)}', style: mono),
          linea,
          for (final l in lineas)
            fila('${l.cantidad.toStringAsFixed(0)} ${l.descripcion}',
                l.total.toStringAsFixed(2).replaceAll('.', ',')),
          linea,
          fila('Base imponible', euros(factura['base_imponible'] as num)),
          fila('IVA ${(factura['tipo_iva'] as num).toStringAsFixed(0)} %',
              euros(factura['cuota_iva'] as num)),
          fila('TOTAL', euros(factura['importe_total'] as num), negrita.copyWith(fontSize: 15)),
          linea,
          // Anexo V: código TicketBAI en una línea y debajo el QR (nivel M)
          FittedBox(child: Text(factura['tbai_id'] as String, style: mono)),
          const SizedBox(height: 8),
          Center(
            child: QrImageView(
              data: factura['qr_url'] as String,
              size: 140,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              backgroundColor: Colors.white,
            ),
          ),
          if (factura['estado_envio'] == 'simulada')
            Text('MODO SIMULADO · NO VÁLIDA FISCALMENTE',
                textAlign: TextAlign.center, style: negrita.copyWith(fontSize: 10)),
          linea,
          Text('Gracias por su visita · Eskerrik asko', textAlign: TextAlign.center, style: mono),
        ],
      ),
    );
  }
}
