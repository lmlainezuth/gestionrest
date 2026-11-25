import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';

/// Copia de seguridad: descarga todas las tablas en un archivo JSON.
class CopiasTab extends StatefulWidget {
  const CopiasTab({super.key});

  @override
  State<CopiasTab> createState() => _CopiasTabState();
}

class _CopiasTabState extends State<CopiasTab> {
  static const _tablas = [
    'empresa', 'tbai_config', 'perfiles', 'salones', 'mesas', 'areas_preparacion', 'grupos_productos',
    'productos', 'modificadores', 'producto_modificadores', 'clientes', 'cajas', 'turnos_caja',
    'conceptos_gasto', 'movimientos_caja', 'pedidos', 'pedido_detalle', 'pagos', 'facturas', 'tbai_anulaciones',
    'proveedores', 'gastos', 'cajas_diarias',
    // Añadidas en 0016-0020
    'articulos_stock', 'escandallos', 'movimientos_stock', 'pedidos_proveedor', 'pedido_proveedor_lineas',
    'cuadrante', 'reservas', 'fichajes', 'registro_anulaciones',
    'tbai_subsanaciones', // 0025
  ];
  bool _trabajando = false;
  String _estado = '';

  /// Orden de restauración (primero lo que otros referencian). Los usuarios
  /// (perfiles) no se restauran: dependen de las cuentas de acceso.
  static const _ordenRestaurar = [
    'tbai_config', 'salones', 'mesas', 'areas_preparacion', 'grupos_productos', 'productos',
    'modificadores', 'producto_modificadores', 'clientes', 'cajas', 'conceptos_gasto', 'turnos_caja',
    'movimientos_caja', 'pedidos', 'pedido_detalle', 'pagos', 'facturas', 'tbai_anulaciones', 'proveedores', 'gastos',
    'cajas_diarias', 'articulos_stock', 'escandallos', 'movimientos_stock', 'pedidos_proveedor', 'pedido_proveedor_lineas',
    'cuadrante', 'reservas',
    // fichajes y registro_anulaciones van en la copia pero NO se restauran: la base de datos
    // no deja reescribirlos (registro legal). Siguen estando en el servidor y en la copia de Drive.
  ];

  /// Tablas que no se pueden modificar: solo se añade lo que falte, lo que ya existe no se toca.
  /// En movimientos_stock además evita contar dos veces (cada movimiento nuevo suma al stock).
  static const _soloAnadir = {'facturas', 'tbai_anulaciones', 'turnos_caja', 'movimientos_stock'};

  /// Columnas que no se envían al restaurar.
  static const _quitar = {
    'pedidos': ['numero'], // lo genera la base de datos
    'pedidos_proveedor': ['numero'],
    'articulos_stock': ['stock'], // el stock sale de los movimientos, no se escribe
  };
  static const _claves = {
    'producto_modificadores': 'producto_id,modificador_id',
    'tbai_config': 'empresa_id',
    'cajas_diarias': 'empresa_id,fecha',
  };

  Future<void> _restaurar() async {
    final f = await FilePicker.pickFile();
    if (f == null) return;
    Map<String, dynamic> datos;
    try {
      datos = jsonDecode(utf8.decode(await f.readAsBytes())) as Map<String, dynamic>;
      if (datos['app'] != 'GestiónRest') throw 'No es una copia de GestiónRest';
    } catch (e) {
      setState(() => _estado = 'Archivo no válido: $e');
      return;
    }
    if (!mounted) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restaurar copia'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Copia del ${datos['fecha']}'),
            const SizedBox(height: 8),
            const Text(
              'Se recuperan los datos de la copia: lo que falte se vuelve a crear y lo que exista se deja '
              'como estaba en la copia. No se borra nada de lo que hayas añadido después. '
              'Las facturas, turnos cerrados y movimientos de stock que ya existen no se tocan. '
              'Los usuarios y sus PIN no se restauran; los fichajes y el registro de anulaciones tampoco '
              '(la ley no deja reescribirlos).',
              style: TextStyle(color: C.gris),
            ),
            const SizedBox(height: 12),
            TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Escribe RESTAURAR para confirmar')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim().toUpperCase() == 'RESTAURAR'), child: const Text('Restaurar')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _trabajando = true);
    final resumen = <String>[];
    try {
      for (final t in _ordenRestaurar) {
        final filas = ((datos[t] as List?) ?? []).cast<Map<String, dynamic>>();
        if (filas.isEmpty) continue;
        setState(() => _estado = 'Restaurando $t (${filas.length})…');
        // El número de pedido lo genera la base de datos
        // La empresa es siempre la actual; el número de pedido lo genera la base de datos
        final limpias = [
          for (final f in filas)
            {...f}
              ..remove('empresa_id')
              ..removeWhere((k, _) => _quitar[t]?.contains(k) ?? false),
        ];
        for (var i = 0; i < limpias.length; i += 500) {
          final lote = limpias.sublist(i, i + 500 > limpias.length ? limpias.length : i + 500);
          await supabase.from(t).upsert(lote, onConflict: _claves[t] ?? 'id', ignoreDuplicates: _soloAnadir.contains(t));
        }
        resumen.add('$t: ${filas.length}');
      }
      setState(() => _estado = 'Copia restaurada\n${resumen.join(' · ')}');
    } catch (e) {
      setState(() => _estado = 'Se detuvo en la restauración: $e\nRestaurado hasta ahora: ${resumen.join(' · ')}');
    }
    if (mounted) setState(() => _trabajando = false);
  }

  /// Lee una tabla entera en bloques de 1000 filas.
  Future<List<Map<String, dynamic>>> _leer(String tabla) async {
    final filas = <Map<String, dynamic>>[];
    for (var desde = 0;; desde += 1000) {
      final bloque = await supabase.from(tabla).select().range(desde, desde + 999);
      filas.addAll(List<Map<String, dynamic>>.from(bloque));
      if (bloque.length < 1000) break;
    }
    return filas;
  }

  Future<void> _copia() async {
    setState(() {
      _trabajando = true;
      _estado = 'Preparando…';
    });
    try {
      final datos = <String, dynamic>{
        'app': 'GestiónRest',
        'version_copia': 2,
        'fecha': DateTime.now().toIso8601String(),
      };
      final cuentas = <String>[];
      for (final t in _tablas) {
        setState(() => _estado = 'Leyendo $t…');
        final filas = await _leer(t);
        datos[t] = filas;
        cuentas.add('$t: ${filas.length}');
      }
      final bytes = utf8.encode(const JsonEncoder.withIndent(' ').convert(datos));
      final h = DateTime.now();
      String d(int n) => n.toString().padLeft(2, '0');
      final ruta = await FilePicker.saveFile(
        dialogTitle: 'Guardar copia de seguridad',
        fileName: 'gestionrest_copia_${h.year}-${d(h.month)}-${d(h.day)}_${d(h.hour)}${d(h.minute)}.json',
        bytes: bytes,
      );
      if (ruta == null) {
        setState(() => _estado = 'Cancelado');
      } else {
        setState(() => _estado = 'Copia guardada\n${cuentas.join(' · ')}');
      }
    } catch (e) {
      setState(() => _estado = 'Error: $e');
    }
    if (mounted) setState(() => _trabajando = false);
  }

  /// Importa la copia de seguridad de Yitso (caja diaria, gastos y proveedores).
  Future<void> _importarYitso() async {
    final f = await FilePicker.pickFile();
    if (f == null) return;
    Map<String, dynamic> d;
    try {
      d = jsonDecode(utf8.decode(await f.readAsBytes())) as Map<String, dynamic>;
      if (d['cajas'] is! List || d['gastos'] is! List || d['proveedores'] is! List) throw 'No es una copia de Yitso';
    } catch (e) {
      setState(() => _estado = 'Archivo no válido: $e');
      return;
    }
    setState(() {
      _trabajando = true;
      _estado = 'Importando Yitso…';
    });
    final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);
    String? idOk(Object? id) => id is String && uuid.hasMatch(id) ? id : null;
    String ivaTxt(Object? v) => v == 'mixto' ? 'mixto' : '${(v as num?)?.toInt() ?? 10}';
    try {
      final provs = [
        for (final p in (d['proveedores'] as List).cast<Map<String, dynamic>>())
          {
            if (idOk(p['id']) != null) 'id': p['id'],
            'nombre': p['nombre'],
            'suministra': p['suministra'] ?? '',
            'telefono': p['telefono'] ?? '',
            'iva_habitual': ivaTxt(p['ivaHabitual']),
            'icono': p['icono'] ?? 'box',
          },
      ];
      final idsProv = provs.map((p) => p['id']).whereType<String>().toSet();
      final cajas = [
        for (final c in (d['cajas'] as List).cast<Map<String, dynamic>>())
          {
            'fecha': c['fecha'],
            'total': c['total'] ?? 0,
            'efectivo': c['efectivo'],
            'tarjeta': c['tarjeta'],
            'estado': c['estado'] == 'pendiente' ? 'pendiente' : 'cerrada',
            'notas': c['notas'],
          },
      ];
      final gastos = [
        for (final g in (d['gastos'] as List).cast<Map<String, dynamic>>())
          {
            if (idOk(g['id']) != null) 'id': g['id'],
            'proveedor_id': idsProv.contains(g['proveedorId']) ? g['proveedorId'] : null,
            'fecha': g['fecha'],
            'concepto': g['concepto'] ?? '',
            'importe': g['importe'] ?? 0,
            'categoria': ['fijos', 'materia', 'otros'].contains(g['categoria']) ? g['categoria'] : 'otros',
            'iva_tipo': ivaTxt(g['ivaTipo']),
            'iva_importe': g['ivaTipo'] == 'mixto' ? g['ivaImporte'] : null,
            'estado': g['estado'] == 'pendiente' ? 'pendiente' : 'registrado',
          },
      ];
      Future<void> subir(String tabla, List<Map<String, dynamic>> filas, String clave) async {
        for (var i = 0; i < filas.length; i += 500) {
          await supabase.from(tabla).upsert(filas.sublist(i, i + 500 > filas.length ? filas.length : i + 500), onConflict: clave);
        }
      }
      await subir('proveedores', provs, 'id');
      await subir('cajas_diarias', cajas, 'empresa_id,fecha');
      await subir('gastos', gastos, 'id');
      setState(() => _estado = 'Yitso importado: ${provs.length} proveedores · ${cajas.length} cajas · ${gastos.length} gastos');
    } catch (e) {
      setState(() => _estado = 'Error al importar Yitso: $e');
    }
    if (mounted) setState(() => _trabajando = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Text('Copia de seguridad', style: titulo(22)),
        const SizedBox(height: 8),
        const Text(
          'Descarga todos los datos (carta, mesas, pedidos, caja, facturas…) en un archivo. '
          'Guárdalo fuera del ordenador, por ejemplo en un pendrive o en tu nube. '
          'Se recomienda hacerlo al menos una vez por semana y siempre antes de cambios importantes.',
          style: TextStyle(color: C.gris, height: 1.5),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _trabajando ? null : _copia,
            icon: const Icon(Icons.download_outlined),
            label: Text(_trabajando ? 'Trabajando…' : 'Descargar copia completa'),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _trabajando ? null : _restaurar,
            icon: const Icon(Icons.restore),
            label: const Text('Restaurar una copia…'),
          ),
        ),
        const SizedBox(height: 28),
        Text('Traer datos de Yitso', style: titulo(22)),
        const SizedBox(height: 8),
        const Text(
          'En Yitso ve a Mi empresa → Copia de seguridad → Exportar, y elige aquí ese archivo. '
          'Se añaden la caja diaria, los gastos y los proveedores a la empresa actual.',
          style: TextStyle(color: C.gris, height: 1.5),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _trabajando ? null : _importarYitso,
            icon: const Icon(Icons.move_down),
            label: const Text('Importar copia de Yitso…'),
          ),
        ),
        const SizedBox(height: 16),
        if (_estado.isNotEmpty) SelectableText(_estado, style: const TextStyle(color: C.gris)),
      ],
    );
  }
}
