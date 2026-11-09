import 'package:flutter/material.dart';

import '../../main.dart';
import 'facturacion_service.dart';
import 'modelos.dart';
import 'ticket_view.dart';

/// Listado de facturas emitidas y emisión de una factura de prueba.
class FacturasPage extends StatefulWidget {
  const FacturasPage({super.key});

  @override
  State<FacturasPage> createState() => _FacturasPageState();
}

class _FacturasPageState extends State<FacturasPage> {
  late Future<List<Map<String, dynamic>>> _facturas = _cargar();
  bool _emitiendo = false;

  Future<List<Map<String, dynamic>>> _cargar() async => List<Map<String, dynamic>>.from(
        await supabase.from('facturas').select().order('fecha', ascending: false).limit(100),
      );

  Future<void> _emitirPrueba() async {
    setState(() => _emitiendo = true);
    try {
      final f = await FacturacionService().emitir(lineas: const [
        LineaFactura('Txakoli Getariako', 2, 3.20),
        LineaFactura('Ensalada de bonito', 1, 11.50),
        LineaFactura('Carrilleras al vino', 1, 16.90),
        LineaFactura('Café con leche', 2, 1.80),
      ]);
      if (!mounted) return;
      setState(() {
        _facturas = _cargar();
      });
      _verTicket(f);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('No se pudo emitir: $e')));
    } finally {
      if (mounted) setState(() => _emitiendo = false);
    }
  }

  void _verTicket(Map<String, dynamic> f) => mostrarTicket(context, f, imprimirAuto: false);


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _emitiendo ? null : _emitirPrueba,
        icon: const Icon(Icons.receipt_long),
        label: Text(_emitiendo ? 'Emitiendo…' : 'Emitir factura de prueba'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _facturas,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final facturas = snap.data!;
          if (facturas.isEmpty) {
            return const Center(child: Text('Todavía no hay facturas emitidas.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: facturas.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final f = facturas[i];
              return ListTile(
                leading: const Icon(Icons.receipt),
                title: Text('${f['serie']}-${f['numero']} · ${euros(f['importe_total'] as num)}'),
                subtitle: Text('${f['tbai_id']}\n${f['estado_envio']}'),
                isThreeLine: true,
                onTap: () => _verTicket(f),
              );
            },
          );
        },
      ),
    );
  }
}
