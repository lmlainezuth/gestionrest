import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/modelos.dart' show euros;
import 'comun.dart';
import 'proveedores_page.dart' show editarProveedor;

/// Facturas de gastos: proveedores, fijos y otros.
class GastosPage extends StatefulWidget {
  const GastosPage({super.key});

  @override
  State<GastosPage> createState() => _GastosPageState();
}

class _GastosPageState extends State<GastosPage> {
  DateTime _mes = DateTime.now();
  bool _soloPendientes = false;
  List<Map<String, dynamic>> _gastos = [];
  List<Map<String, dynamic>> _provs = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final (desde, hasta) = rangoMes(_mes);
    var q = supabase.from('gastos').select('*, proveedores(nombre)');
    q = _soloPendientes ? q.eq('estado', 'pendiente') : q.gte('fecha', desde).lte('fecha', hasta);
    _gastos = List<Map<String, dynamic>>.from(await q.order('fecha', ascending: false));
    _provs = List<Map<String, dynamic>>.from(await supabase.from('proveedores').select().order('nombre'));
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _editar([Map<String, dynamic>? g]) async {
    var fecha = g == null ? DateTime.now() : DateTime.parse(g['fecha'] as String);
    String f(num? v) => v == null ? '' : v.toStringAsFixed(2).replaceAll('.', ',');
    final concepto = TextEditingController(text: g?['concepto'] as String?);
    final importe = TextEditingController(text: f(g?['importe'] as num?));
    final ivaImp = TextEditingController(text: f(g?['iva_importe'] as num?));
    String? proveedor = g?['proveedor_id'] as String?;
    var categoria = (g?['categoria'] as String?) ?? 'materia';
    var iva = (g?['iva_tipo'] as String?) ?? '10';
    var estado = (g?['estado'] as String?) ?? 'registrado';
    String? error;

    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: Text(g == null ? 'Nuevo gasto' : 'Editar gasto'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: proveedor,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Proveedor'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Sin proveedor')),
                        for (final p in _provs) DropdownMenuItem(value: p['id'] as String, child: Text(p['nombre'] as String)),
                      ],
                      onChanged: (v) => setD(() {
                        proveedor = v;
                        final p = _provs.where((x) => x['id'] == v).firstOrNull;
                        if (p != null) iva = p['iva_habitual'] as String;
                      }),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Nuevo proveedor',
                    onPressed: () async {
                      final nuevo = await editarProveedor(ctx);
                      if (nuevo != null) {
                        _provs.add(nuevo);
                        setD(() {
                          proveedor = nuevo['id'] as String;
                          iva = nuevo['iva_habitual'] as String;
                        });
                      }
                    },
                    icon: const Icon(Icons.add_business_outlined),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(controller: concepto, decoration: const InputDecoration(labelText: 'Concepto (nº de factura, qué es…)')),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(controller: importe, decoration: const InputDecoration(labelText: 'Importe con IVA', suffixText: '€')),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(context: ctx, initialDate: fecha, firstDate: DateTime(2023), lastDate: DateTime.now());
                      if (d != null) setD(() => fecha = d);
                    },
                    icon: const Icon(Icons.calendar_today_outlined, size: 18),
                    label: Text('${fecha.day}/${fecha.month}/${fecha.year}'),
                  ),
                ]),
                const SizedBox(height: 16),
                const Text('Categoría'),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: [for (final e in categorias.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                  selected: {categoria},
                  onSelectionChanged: (s) => setD(() => categoria = s.first),
                ),
                const SizedBox(height: 16),
                const Text('IVA de la factura'),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: [for (final t in tiposIva) ButtonSegment(value: t, label: Text(t == 'mixto' ? 'Mixto' : '$t %'))],
                  selected: {iva},
                  onSelectionChanged: (s) => setD(() => iva = s.first),
                ),
                if (iva == 'mixto') ...[
                  const SizedBox(height: 12),
                  TextField(controller: ivaImp, decoration: const InputDecoration(labelText: 'IVA total que pone la factura', suffixText: '€')),
                ],
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'registrado', label: Text('Pagada')),
                    ButtonSegment(value: 'pendiente', label: Text('Por pagar')),
                  ],
                  selected: {estado},
                  onSelectionChanged: (s) => setD(() => estado = s.first),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ],
              ]),
            ),
          ),
          actions: [
            if (g != null) TextButton(onPressed: () => Navigator.pop(ctx, 'borrar'), child: const Text('Borrar')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                final imp = leerImporte(importe.text);
                if (concepto.text.trim().isEmpty || imp == null || imp < 0) {
                  setD(() => error = 'Escribe el concepto y el importe');
                  return;
                }
                final vi = leerImporte(ivaImp.text);
                if (iva == 'mixto' && (vi == null || vi < 0 || vi >= imp)) {
                  setD(() => error = 'Escribe el IVA total que aparece al pie de la factura');
                  return;
                }
                Navigator.pop(ctx, 'guardar');
              },
              child: const Text('Guardar'),
            ),
          ],
        );
      }),
    );
    try {
      if (r == 'borrar') {
        await supabase.from('gastos').delete().eq('id', g!['id']);
      } else if (r == 'guardar') {
        final datos = {
          'proveedor_id': proveedor,
          'fecha': iso(fecha),
          'concepto': concepto.text.trim(),
          'importe': leerImporte(importe.text),
          'categoria': categoria,
          'iva_tipo': iva,
          'iva_importe': iva == 'mixto' ? leerImporte(ivaImp.text) : null,
          'estado': estado,
        };
        g == null
            ? await supabase.from('gastos').insert(datos)
            : await supabase.from('gastos').update(datos).eq('id', g['id']);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
    await _cargar();
  }

  Future<void> _pagado(Map<String, dynamic> g) async {
    await supabase.from('gastos').update({'estado': 'registrado'}).eq('id', g['id']);
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final total = _gastos.fold(0.0, (s, g) => s + (g['importe'] as num).toDouble());
    final iva = _gastos.fold(0.0, (s, g) => s + ivaGasto(g));
    final pendiente = _gastos.where((g) => g['estado'] == 'pendiente').fold(0.0, (s, g) => s + (g['importe'] as num).toDouble());
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (!_soloPendientes)
            SelectorMes(mes: _mes, onCambio: (m) {
              _mes = m;
              _cargar();
            }),
          FilterChip(
            label: const Text('Solo por pagar (todos los meses)'),
            selected: _soloPendientes,
            onSelected: (v) {
              _soloPendientes = v;
              _cargar();
            },
          ),
          FilledButton.icon(onPressed: () => _editar(), icon: const Icon(Icons.add), label: const Text('Nuevo gasto')),
        ]),
        const SizedBox(height: 20),
        Wrap(spacing: 14, runSpacing: 14, children: [
          Cifra(_soloPendientes ? 'Total por pagar' : 'Gastos del mes', euros(total), detalle: '${_gastos.length} facturas', destacada: true),
          Cifra('IVA soportado', euros(iva)),
          if (!_soloPendientes) Cifra('Por pagar', euros(pendiente), color: pendiente > 0 ? C.naranja : null),
        ]),
        const SizedBox(height: 24),
        if (_cargando) const Center(child: CircularProgressIndicator()),
        if (!_cargando && _gastos.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('Sin gastos.', style: TextStyle(color: C.gris))),
        for (final g in _gastos)
          Card(
            elevation: 0,
            color: C.blanco,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: C.borde)),
            child: ListTile(
              onTap: () => _editar(g),
              leading: CircleAvatar(
                radius: 8,
                backgroundColor: coloresCategoria[g['categoria']] ?? C.gris,
              ),
              title: Text('${(g['proveedores'] as Map?)?['nombre'] ?? 'Sin proveedor'} · ${g['concepto']}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${fechaCorta(g['fecha'] as String)} · ${categorias[g['categoria']]} · '
                  'IVA ${g['iva_tipo'] == 'mixto' ? 'mixto' : '${g['iva_tipo']} %'}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (g['estado'] == 'pendiente')
                  TextButton(onPressed: () => _pagado(g), child: const Text('Marcar pagada')),
                Text(euros(g['importe'] as num), style: titulo(18, color: g['estado'] == 'pendiente' ? C.naranja : C.tinta)),
              ]),
            ),
          ),
      ],
    );
  }
}
