import 'package:flutter/material.dart';

import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import 'facturacion_service.dart';
import 'modelos.dart' show euros;
import 'ticket_view.dart';

/// Ventas hechas sin internet que el servidor no aceptó al subirlas (migración 0052). Ya se
/// emitieron (el cliente tiene su ticket): el administrador las envía a Hacienda tal cual, con un
/// motivo, desde cualquier equipo. Queda "factura forzada" en Seguridad.
class VentasEsperaPage extends StatefulWidget {
  const VentasEsperaPage({super.key});

  /// Ventas en espera sin resolver del bar (solo las ve el administrador).
  static Future<List<Map<String, dynamic>>> pendientes() async {
    final espera = List<Map<String, dynamic>>.from(await supabase
        .from('ventas_espera')
        .select('id, serie, numero, fecha, importe, motivo_rechazo, creado_en')
        .order('creado_en'));
    if (espera.isEmpty) return espera;
    final hechas = await supabase.from('facturas').select('id').inFilter('id', [for (final e in espera) e['id']]);
    final resueltas = {for (final f in hechas) f['id']};
    return [for (final e in espera) if (!resueltas.contains(e['id'])) e];
  }

  @override
  State<VentasEsperaPage> createState() => _VentasEsperaPageState();
}

class _VentasEsperaPageState extends State<VentasEsperaPage> {
  late Future<List<Map<String, dynamic>>> _lista = VentasEsperaPage.pendientes();
  bool _trabajando = false;

  void _recargar() => setState(() => _lista = VentasEsperaPage.pendientes());

  String _fecha(Object? v) {
    if (v == null) return '';
    final d = DateTime.parse(v as String).toLocal();
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(d.day)}/${dos(d.month)}/${d.year} ${dos(d.hour)}:${dos(d.minute)}';
  }

  Future<void> _enviar(Map<String, dynamic> v) async {
    final motivo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Enviar ${v['serie']}-${v['numero']} tal cual'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                  'Esta venta ya se cobró y el cliente tiene su ticket. Se guarda y se envía a Hacienda tal como se '
                  'emitió. Si no encajaba en la cadena, queda marcada "fuera de cadena". Si Hacienda la rechaza, '
                  'podrás subsanarla desde Facturas. Queda registrado en Seguridad con tu nombre y el motivo.'),
              const SizedBox(height: 12),
              Text('No se aceptó porque: ${v['motivo_rechazo'] ?? '—'}', style: const TextStyle(color: C.gris)),
              const SizedBox(height: 12),
              TextField(
                controller: motivo,
                autofocus: true,
                maxLines: 3,
                maxLength: 300,
                onChanged: (_) => set(() {}),
                decoration: const InputDecoration(labelText: 'Motivo (obligatorio)', border: OutlineInputBorder()),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              onPressed: motivo.text.trim().length < 10 ? null : () => Navigator.pop(ctx, true),
              child: const Text('Enviar a Hacienda'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _trabajando = true);
    try {
      final f = await FacturacionService().forzar(v['id'] as String, motivo.text.trim());
      if (!mounted) return;
      final estado = f['estado_envio'] == 'enviada'
          ? 'Recibida por Hacienda'
          : f['estado_envio'] == 'error'
              ? 'Hacienda la ha rechazado: subsánala desde Facturas'
              : 'Guardada; se enviará a Hacienda en cuanto se pueda';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${v['serie']}-${v['numero']}: $estado')));
      await mostrarTicket(context, f, imprimirAuto: false);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo enviar: $e')));
    }
    if (mounted) {
      setState(() => _trabajando = false);
      _recargar();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ventas en espera')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _lista,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return Center(child: Text(textoError(snap.error)));
          final lista = snap.data!;
          if (lista.isEmpty) {
            return const Center(child: Text('No hay ventas en espera.'));
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                  'Ventas cobradas sin internet que el servidor no aceptó al subirlas. Hasta enviarlas, el equipo '
                  'que las hizo cobra en modo sin internet y sube el resto después, en orden.',
                  style: TextStyle(color: C.gris)),
              const SizedBox(height: 12),
              for (final v in lista)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.hourglass_top, color: Color(0xFFB45309)),
                    title: Text('${v['serie']}-${v['numero']} · ${euros((v['importe'] as num?) ?? 0)}'),
                    subtitle: Text('Emitida ${_fecha(v['fecha'])} · ${v['motivo_rechazo'] ?? ''}'),
                    trailing: FilledButton(
                      onPressed: _trabajando ? null : () => _enviar(v),
                      child: const Text('Enviar tal cual'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
