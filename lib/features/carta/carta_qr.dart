import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/tema.dart';
import '../auth/perfil.dart';

/// Dirección pública de la carta (página web ligera en Netlify).
String? enlaceCarta() {
  final e = Perfil.cache?.empresaId;
  return e == null ? null : 'https://gestionrest.netlify.app/carta/?e=$e';
}

/// QR de la carta para las mesas: verlo, copiar el enlace o imprimir el cartel.
Future<void> mostrarQrCarta(BuildContext context) {
  final url = enlaceCarta();
  final nombre = Perfil.cache?.empresaNombre ?? '';
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Carta QR'),
      content: SizedBox(
        width: 320,
        child: url == null
            ? const Text('Elige antes la empresa')
            : Column(mainAxisSize: MainAxisSize.min, children: [
                QrImageView(data: url, size: 240),
                const SizedBox(height: 8),
                SelectableText(url, style: const TextStyle(color: C.gris, fontSize: 12), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text('El cliente ve la carta con precios y alérgenos. Se actualiza sola al cambiar la Carta.',
                    style: TextStyle(fontSize: 13), textAlign: TextAlign.center),
              ]),
      ),
      actions: url == null
          ? [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))]
          : [
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: url)),
                child: const Text('Copiar enlace'),
              ),
              TextButton(
                onPressed: () async {
                  final doc = pw.Document()
                    ..addPage(pw.Page(
                      pageFormat: PdfPageFormat.a4,
                      build: (_) => pw.Center(
                        child: pw.Column(mainAxisSize: pw.MainAxisSize.min, children: [
                          pw.Text(nombre, style: pw.TextStyle(fontSize: 34, fontWeight: pw.FontWeight.bold)),
                          pw.SizedBox(height: 10),
                          pw.Text('Escanea para ver la carta', style: const pw.TextStyle(fontSize: 22)),
                          pw.SizedBox(height: 24),
                          pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: url, width: 300, height: 300),
                          pw.SizedBox(height: 18),
                          pw.Text('Precios con IVA · alérgenos en cada plato', style: const pw.TextStyle(fontSize: 14)),
                        ]),
                      ),
                    ));
                  await Printing.layoutPdf(name: 'Carta QR', onLayout: (_) async => doc.save());
                },
                child: const Text('Imprimir cartel'),
              ),
              FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
            ],
    ),
  );
}
