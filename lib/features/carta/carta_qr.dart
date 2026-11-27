import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';

/// Dirección pública de la carta (página web ligera en Netlify). Lleva el código propio de la
/// carta (empresa.codigo_carta, migración 0037), no el id de la empresa: ese id no sale del bar,
/// porque con él la pantalla de entrada enseña quién trabaja aquí.
Future<String?> enlaceCarta() async {
  if (Perfil.cache?.empresaId == null) return null;
  final fila = await supabase.from('empresa').select('codigo_carta').limit(1).maybeSingle();
  final c = fila?['codigo_carta'] as String?;
  return c == null ? null : 'https://gestionrest.netlify.app/carta/?c=$c';
}

/// (enlace, aviso): el enlace, o por qué no se ha podido leer.
Future<(String?, String?)> _leerEnlace() async {
  try {
    return (await enlaceCarta(), null);
  } catch (e) {
    return (null, esErrorDeRed(e) ? 'Hace falta internet para ver el QR de la carta' : 'No se pudo leer el código de la carta: $e');
  }
}

/// QR de la carta para las mesas: verlo, copiar el enlace o imprimir el cartel.
Future<void> mostrarQrCarta(BuildContext context) async {
  final (url, aviso) = await _leerEnlace();
  if (!context.mounted) return;
  final nombre = Perfil.cache?.empresaNombre ?? '';
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Carta QR'),
      content: SizedBox(
        width: 320,
        child: url == null
            ? Text(aviso ?? 'Elige antes la empresa')
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
