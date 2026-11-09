import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/escpos.dart';
import '../../core/impresion.dart';
import '../../core/tema.dart';

/// Qué impresora usa este equipo para tickets, Cocina y Barra:
/// de red (ESC/POS, directa y con cajón) o del sistema (PDF).
class ImpresorasTab extends StatefulWidget {
  const ImpresorasTab({super.key});

  @override
  State<ImpresorasTab> createState() => _ImpresorasTabState();
}

class _ImpresorasTabState extends State<ImpresorasTab> {
  static const _usos = {
    Impresion.ticket: ('Tickets y precuentas', 'El cajón se abre al cobrar en efectivo (impresora de red)'),
    'Cocina': ('Comandas de cocina', 'Se imprimen solas al enviar una comanda'),
    'Barra': ('Comandas de barra', 'Se imprimen solas al enviar una comanda'),
  };
  List<Printer> _sistema = [];
  final Map<String, String?> _valor = {};
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      _sistema = await Printing.listPrinters();
    } catch (_) {
      _sistema = []; // en Android/web no hay lista de impresoras del sistema
    }
    for (final u in _usos.keys) {
      _valor[u] = await Impresion.impresora(u);
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _guardar(String uso, String? v) async {
    await Impresion.guardar(uso, v);
    setState(() => _valor[uso] = v);
  }

  Future<void> _configurarRed(String uso) async {
    final actual = ImpresoraRed.desde(_valor[uso]);
    final ip = TextEditingController(text: actual?.ip ?? '192.168.1.');
    final puerto = TextEditingController(text: '${actual?.puerto ?? 9100}');
    var ancho = actual?.ancho ?? 80;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Impresora de red'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: ip, decoration: const InputDecoration(labelText: 'IP de la impresora'), keyboardType: TextInputType.number),
              const SizedBox(height: 12),
              TextField(controller: puerto, decoration: const InputDecoration(labelText: 'Puerto'), keyboardType: TextInputType.number),
              const SizedBox(height: 16),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 58, label: Text('Papel 58 mm')),
                  ButtonSegment(value: 80, label: Text('Papel 80 mm')),
                ],
                selected: {ancho},
                onSelectionChanged: (s) => set(() => ancho = s.first),
              ),
              const SizedBox(height: 10),
              const Text('La IP sale en la hoja de prueba de la impresora (mantén pulsado FEED al encenderla).',
                  style: TextStyle(fontSize: 12, color: C.gris)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok == true && ip.text.trim().isNotEmpty) {
      await _guardar(uso, ImpresoraRed(ip.text.trim(), puerto: int.tryParse(puerto.text) ?? 9100, ancho: ancho).valor);
    }
  }

  Future<void> _probar(String uso, {bool cajon = false}) async {
    try {
      if (cajon) {
        await Impresion.abrirCajon();
      } else {
        await Impresion.imprimirComanda(uso, 'PRUEBA', [
          {'cantidad': 1, 'descripcion': 'Prueba de impresión ñ á é í ó ú', 'curso': 'ya', 'nota': 'GestiónRest'},
        ]);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No responde la impresora: $e')));
    }
  }

  String _descripcion(String? v) {
    final r = ImpresoraRed.desde(v);
    if (r != null) return 'Red · ${r.ip}:${r.puerto} · ${r.ancho} mm';
    if (v == null) return 'Ninguna';
    return _sistema.where((p) => p.url == v).firstOrNull?.name ?? v;
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        const Text(
            'Configuración de este equipo. Lo mejor es una impresora térmica de red: imprime al instante, corta el papel '
            'y abre el cajón. También vale cualquier impresora instalada en Windows.',
            style: TextStyle(color: C.gris)),
        const SizedBox(height: 20),
        for (final e in _usos.entries)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.borde)),
            child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 320,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.value.$1, style: titulo(18)),
                  Text(e.value.$2, style: const TextStyle(color: C.gris, fontSize: 13)),
                  const SizedBox(height: 6),
                  Text(_descripcion(_valor[e.key]), style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
              FilledButton.icon(
                onPressed: () => _configurarRed(e.key),
                icon: const Icon(Icons.lan_outlined),
                label: const Text('Impresora de red'),
              ),
              if (_sistema.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'Impresora del sistema',
                  onSelected: (v) => _guardar(e.key, v),
                  itemBuilder: (_) => [for (final p in _sistema) PopupMenuItem(value: p.url, child: Text(p.name))],
                  child: const Chip(avatar: Icon(Icons.print_outlined, size: 18), label: Text('Del sistema')),
                ),
              if (_valor[e.key] != null) ...[
                IconButton(tooltip: 'Imprimir prueba', onPressed: () => _probar(e.key), icon: const Icon(Icons.receipt_long)),
                if (e.key == Impresion.ticket && ImpresoraRed.desde(_valor[e.key]) != null)
                  IconButton(tooltip: 'Probar cajón', onPressed: () => _probar(e.key, cajon: true), icon: const Icon(Icons.point_of_sale)),
                IconButton(tooltip: 'Quitar', onPressed: () => _guardar(e.key, null), icon: const Icon(Icons.close)),
              ],
            ]),
          ),
      ],
    );
  }
}
