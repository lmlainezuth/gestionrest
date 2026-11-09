import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/tema.dart';
import '../../main.dart';

/// Zonas (salones) y sus mesas: crear, renombrar, capacidad y desactivar.
class SalonesTab extends StatefulWidget {
  const SalonesTab({super.key});

  @override
  State<SalonesTab> createState() => _SalonesTabState();
}

class _SalonesTabState extends State<SalonesTab> {
  List<Map<String, dynamic>> _salones = [];
  List<Map<String, dynamic>> _mesas = [];
  String? _salonId;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      _salones = List<Map<String, dynamic>>.from(await supabase.from('salones').select().order('orden').order('nombre'));
      if (_salonId == null || !_salones.any((s) => s['id'] == _salonId)) {
        _salonId = _salones.isEmpty ? null : _salones.first['id'] as String;
      }
      _mesas = _salonId == null
          ? []
          : List<Map<String, dynamic>>.from(await supabase.from('mesas').select().eq('salon_id', _salonId!));
      _mesas.sort((a, b) => _clave(a['nombre'] as String).compareTo(_clave(b['nombre'] as String)));
    } catch (e) {
      _avisar('Error: $e');
    }
    if (mounted) setState(() => _cargando = false);
  }

  static String _clave(String n) {
    final d = RegExp(r'\d+').firstMatch(n)?.group(0);
    return d == null ? n : n.replaceFirst(d, d.padLeft(4, '0'));
  }

  void _avisar(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _hacer(Future<dynamic> Function() f, [String? ok]) async {
    try {
      await f();
      if (ok != null) _avisar(ok);
    } on PostgrestException catch (e) {
      _avisar(e.message);
    }
    await _cargar();
  }

  // ---------- Salones ----------

  Future<void> _editarSalon([Map<String, dynamic>? s]) async {
    final ctrl = TextEditingController(text: s?['nombre'] as String?);
    var activo = (s?['activo'] as bool?) ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(s == null ? 'Nueva zona' : 'Editar zona'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre (Comedor, Terraza…)')),
                if (s != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Activa'),
                    value: activo,
                    onChanged: (v) => setD(() => activo = v),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    final nombre = ctrl.text.trim();
    if (ok != true || nombre.isEmpty) return;
    await _hacer(() => s == null
        ? supabase.from('salones').insert({'nombre': nombre, 'orden': _salones.length + 1})
        : supabase.from('salones').update({'nombre': nombre, 'activo': activo}).eq('id', s['id']));
  }

  // ---------- Mesas ----------

  Future<void> _editarMesa([Map<String, dynamic>? m]) async {
    final nombre = TextEditingController(text: m?['nombre'] as String?);
    final capacidad = TextEditingController(text: '${m?['capacidad'] ?? 4}');
    var activa = (m?['activo'] as bool?) ?? true;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(m == null ? 'Nueva mesa' : 'Mesa ${m['nombre']}'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nombre, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre o número')),
                const SizedBox(height: 12),
                TextField(controller: capacidad, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Comensales')),
                if (m != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('En uso'),
                    value: activa,
                    onChanged: (v) => setD(() => activa = v),
                  ),
              ],
            ),
          ),
          actions: [
            if (m != null) TextButton(onPressed: () => Navigator.pop(ctx, 'borrar'), child: const Text('Borrar')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'guardar'), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (r == 'borrar') {
      try {
        await supabase.from('mesas').delete().eq('id', m!['id']);
        _avisar('Mesa borrada');
      } on PostgrestException catch (e) {
        if (e.code == '23503') {
          // Tiene pedidos en el historial: se retira en lugar de borrarse
          await supabase.from('mesas').update({'activo': false}).eq('id', m!['id']);
          _avisar('La mesa tiene historial: se ha retirado (no se borra)');
        } else {
          _avisar(e.message);
        }
      }
      await _cargar();
      return;
    }
    if (r != 'guardar' || nombre.text.trim().isEmpty) return;
    final datos = {
      'nombre': nombre.text.trim(),
      'capacidad': int.tryParse(capacidad.text.trim()),
      'activo': activa,
    };
    await _hacer(() => m == null
        ? supabase.from('mesas').insert({...datos, 'salon_id': _salonId})
        : supabase.from('mesas').update(datos).eq('id', m['id']));
  }

  Future<void> _variasMesas() async {
    final prefijo = TextEditingController(text: 'M');
    final desde = TextEditingController(text: '1');
    final hasta = TextEditingController(text: '10');
    final capacidad = TextEditingController(text: '4');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Añadir varias mesas'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: prefijo, decoration: const InputDecoration(labelText: 'Prefijo (M, T, B…)')),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: TextField(controller: desde, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Desde'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: hasta, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Hasta'))),
              ]),
              const SizedBox(height: 12),
              TextField(controller: capacidad, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Comensales por mesa')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Crear')),
        ],
      ),
    );
    final a = int.tryParse(desde.text), b = int.tryParse(hasta.text);
    if (ok != true || a == null || b == null || b < a || b - a > 99) return;
    final existentes = _mesas.map((m) => m['nombre']).toSet();
    final nuevas = [
      for (var n = a; n <= b; n++)
        if (!existentes.contains('${prefijo.text.trim()}$n'))
          {'salon_id': _salonId, 'nombre': '${prefijo.text.trim()}$n', 'capacidad': int.tryParse(capacidad.text)},
    ];
    if (nuevas.isEmpty) return;
    await _hacer(() => supabase.from('mesas').insert(nuevas), '${nuevas.length} mesas creadas');
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    final salon = _salones.where((s) => s['id'] == _salonId).firstOrNull;
    return Row(
      children: [
        SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(children: [
                  Expanded(child: Text('Zonas', style: titulo(20))),
                  IconButton(tooltip: 'Nueva zona', onPressed: _editarSalon, icon: const Icon(Icons.add)),
                ]),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final s in _salones)
                      ListTile(
                        selected: s['id'] == _salonId,
                        title: Text(s['nombre'] as String,
                            style: TextStyle(decoration: s['activo'] == true ? null : TextDecoration.lineThrough)),
                        trailing: IconButton(
                          tooltip: 'Editar zona',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _editarSalon(s),
                        ),
                        onTap: () {
                          _salonId = s['id'] as String;
                          _cargar();
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: salon == null
              ? const Center(child: Text('Crea la primera zona'))
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Row(children: [
                      Expanded(child: Text('${salon['nombre']} · ${_mesas.length} mesas', style: titulo(20))),
                      OutlinedButton.icon(onPressed: _variasMesas, icon: const Icon(Icons.library_add_outlined), label: const Text('Varias')),
                      const SizedBox(width: 8),
                      FilledButton.icon(onPressed: _editarMesa, icon: const Icon(Icons.add), label: const Text('Nueva mesa')),
                    ]),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final m in _mesas)
                          Opacity(
                            opacity: m['activo'] == true ? 1 : 0.4,
                            child: Material(
                              color: C.blanco,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: const BorderSide(color: C.bordeFuerte),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => _editarMesa(m),
                                child: SizedBox(
                                  width: 120,
                                  height: 90,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(m['nombre'] as String, style: titulo(24)),
                                      Text('${m['capacidad'] ?? '—'} pax', style: const TextStyle(color: C.gris)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
