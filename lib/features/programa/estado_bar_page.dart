import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../control/control_comun.dart' show rojo;
import 'alta_bar_servicio.dart';

/// Lista de bares (solo programadores). Cada uno abre su «Estado del bar».
class EstadoBaresPage extends StatefulWidget {
  const EstadoBaresPage({super.key});

  @override
  State<EstadoBaresPage> createState() => _EstadoBaresPageState();
}

class _EstadoBaresPageState extends State<EstadoBaresPage> {
  List<Map<String, dynamic>>? _bares;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final r = await llamarAltaBar({'accion': 'bares'});
      setState(() {
        _bares = List<Map<String, dynamic>>.from((r['bares'] as List).map((b) => Map<String, dynamic>.from(b as Map)));
        _error = null;
      });
    } catch (e) {
      setState(() => _error = textoAltaBar(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Estado de los bares')),
        body: _error != null
            ? Center(child: Text(_error!))
            : _bares == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final b in _bares!)
                        Card(
                          child: ListTile(
                            title: Text('${b['nombre']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('NIF ${b['nif'] ?? '—'} · ${_entorno(b['entorno'] as String?)}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              await Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => EstadoBarPage(empresaId: b['id'] as String, nombre: b['nombre'] as String)));
                              _cargar();
                            },
                          ),
                        ),
                    ],
                  ),
      );
}

String _entorno(String? e) => switch (e) {
      'produccion' => 'Producción',
      'pruebas' => 'Pruebas de Hacienda',
      'simulado' => 'Simulado',
      _ => 'Sin configurar',
    };

/// Todo en verde o en rojo: certificado, entorno, envíos, ventas en espera y qué falta para
/// producción. Desde aquí se sustituye el certificado y se pasa el bar a producción.
class EstadoBarPage extends StatefulWidget {
  const EstadoBarPage({super.key, required this.empresaId, required this.nombre});
  final String empresaId;
  final String nombre;

  @override
  State<EstadoBarPage> createState() => _EstadoBarPageState();
}

class _EstadoBarPageState extends State<EstadoBarPage> {
  Map<String, dynamic>? _estado;
  String? _error;
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final r = await llamarAltaBar({'accion': 'estado', 'empresa_id': widget.empresaId});
      setState(() {
        _estado = r;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = textoAltaBar(e));
    }
  }

  void _aviso(String texto) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto), duration: const Duration(seconds: 8)));
  }

  Future<void> _hacer(Future<String> Function() accion) async {
    setState(() => _ocupado = true);
    try {
      _aviso(await accion());
      await _cargar();
    } catch (e) {
      _aviso(textoAltaBar(e));
    }
    if (mounted) setState(() => _ocupado = false);
  }

  Future<void> _sustituir() async {
    final CertificadoElegido? cert;
    try {
      cert = await CertificadoElegido.elegir();
    } catch (e) {
      _aviso(textoAltaBar(e));
      return;
    }
    if (cert == null || !mounted) return;
    final ctrl = TextEditingController();
    final clave = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Contraseña del certificado'),
        content: TextField(controller: ctrl, obscureText: true, autofocus: true,
            decoration: InputDecoration(labelText: 'Contraseña de ${cert!.nombre}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Subir')),
        ],
      ),
    );
    if (clave == null) return;
    await _hacer(() async {
      final r = await llamarAltaBar(
          {'accion': 'certificado', 'empresa_id': widget.empresaId, 'p12': cert!.base64, 'clave': clave});
      return 'Certificado guardado: ${r['titular']} · caduca el ${r['caduca']}${r['aviso'] != null ? '. ${r['aviso']}' : ''}';
    });
  }

  Future<void> _importar() => _hacer(() async {
        final r = await llamarAltaBar({'accion': 'importar_secreto', 'empresa_id': widget.empresaId});
        return 'Certificado en el almacén. ${r['recuerda'] ?? ''}';
      });

  Future<void> _produccion() async {
    final comprobaciones = List<Map<String, dynamic>>.from(
        (_estado!['comprobaciones'] as List).map((c) => Map<String, dynamic>.from(c as Map)));
    final falta = comprobaciones.where((c) => c['ok'] != true).toList();
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(falta.isEmpty ? '¿Pasar ${widget.nombre} a producción?' : 'Todavía no se puede'),
          content: SizedBox(
            width: 480,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (falta.isNotEmpty) ...[
                const Text('Falta:'),
                const SizedBox(height: 6),
                for (final c in falta) _linea(c),
              ] else ...[
                const Text(
                  'Las facturas se enviarán de verdad a la Hacienda Foral de Gipuzkoa, con efectos fiscales. '
                  'NO se puede volver a pruebas. La caja recibe una serie nueva y los TPV con serie propia '
                  'piden la suya solos.',
                  style: TextStyle(color: rojo, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                Text('Para confirmar, escribe el nombre del bar: ${widget.nombre}'),
                TextField(controller: ctrl, autofocus: true, onChanged: (_) => setD(() {})),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(falta.isEmpty ? 'Cancelar' : 'Cerrar')),
            if (falta.isEmpty)
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: rojo),
                onPressed: ctrl.text.trim() == widget.nombre.trim() ? () => Navigator.pop(ctx, true) : null,
                child: const Text('Pasar a producción'),
              ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _hacer(() async {
      final r = await llamarAltaBar({'accion': 'produccion', 'empresa_id': widget.empresaId, 'confirmacion': ctrl.text});
      return '${widget.nombre} ya está en producción. Serie nueva de la caja: ${r['serie']}';
    });
  }

  Widget _linea(Map<String, dynamic> c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(c['ok'] == true ? Icons.check_circle : Icons.cancel, size: 18, color: c['ok'] == true ? C.verde : rojo),
          const SizedBox(width: 8),
          Expanded(child: Text('${c['texto']}')),
        ]),
      );

  Widget _tarjeta(String titulo_, List<Widget> hijos) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo_, style: titulo(16)),
            const SizedBox(height: 8),
            ...hijos,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final e = _estado;
    Widget cuerpo;
    if (_error != null) {
      cuerpo = Center(child: Text(_error!));
    } else if (e == null) {
      cuerpo = const Center(child: CircularProgressIndicator());
    } else {
      final bar = Map<String, dynamic>.from(e['bar'] as Map);
      final cert = Map<String, dynamic>.from(e['certificado'] as Map);
      final fac = Map<String, dynamic>.from(e['facturas'] as Map);
      final comprobaciones = List<Map<String, dynamic>>.from(
          (e['comprobaciones'] as List).map((c) => Map<String, dynamic>.from(c as Map)));
      final enProduccion = bar['entorno'] == 'produccion';
      final caduca = DateTime.tryParse('${cert['caduca']}');
      final certOk = cert['origen'] != null && cert['error'] == null && caduca != null && caduca.isAfter(DateTime.now());
      final espera = e['en_espera'] as int? ?? 0;
      final pendientes = fac['pendientes'] as int? ?? 0;
      final rechazadas = fac['rechazadas'] as int? ?? 0;
      cuerpo = ListView(padding: const EdgeInsets.all(16), children: [
        _tarjeta('Bar', [
          _linea({'ok': true, 'texto': '${bar['nombre']} · ${bar['razon']} · NIF ${bar['nif']}'}),
          _linea({'ok': enProduccion, 'texto': 'Entorno: ${_entorno(bar['entorno'] as String?)}'}),
        ]),
        _tarjeta('Certificado del titular', [
          _linea({
            'ok': certOk,
            'texto': switch (cert['origen']) {
              'almacen' => '${cert['titular']}\nCaduca el ${cert['caduca']} · subido el ${cert['subido']}',
              'secreto' => cert['error'] != null
                  ? 'En los secretos del panel (antiguo), pero no se abre: ${cert['error']}'
                  : 'En los secretos del panel (antiguo): ${cert['titular']}\nCaduca el ${cert['caduca']}'
                      '${cert['del_nif'] == false ? ' · NO es del NIF del bar' : ''}',
              _ => 'Sin certificado: no se puede firmar ni enviar',
            },
          }),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: _ocupado ? null : _sustituir,
              icon: const Icon(Icons.upload_file),
              label: Text(cert['origen'] == 'almacen' ? 'Sustituir por uno nuevo' : 'Subir certificado'),
            ),
            if (cert['origen'] == 'secreto' && cert['error'] == null)
              OutlinedButton.icon(
                onPressed: _ocupado ? null : _importar,
                icon: const Icon(Icons.move_down),
                label: const Text('Pasar al almacén'),
              ),
          ]),
        ]),
        _tarjeta('Envíos a Hacienda', [
          _linea({'ok': pendientes == 0, 'texto': pendientes == 0 ? 'Nada pendiente de enviar' : '$pendientes factura(s) pendientes de enviar'}),
          _linea({'ok': rechazadas == 0, 'texto': rechazadas == 0 ? 'Ninguna rechazada' : '$rechazadas factura(s) rechazadas por Hacienda'}),
          _linea({'ok': espera == 0, 'texto': espera == 0 ? 'Ninguna venta en espera' : '$espera venta(s) en espera sin resolver'}),
          const SizedBox(height: 6),
          const Text('Últimas aceptadas por Hacienda:', style: TextStyle(color: C.gris, fontSize: 13)),
          if ((fac['ultimas'] as List).isEmpty) const Text('— ninguna todavía', style: TextStyle(color: C.gris, fontSize: 13)),
          for (final f in (fac['ultimas'] as List).cast<Map>())
            Text('${f['serie']}-${f['numero']} · ${'${f['fecha']}'.replaceFirst('T', ' ').substring(0, 16)}',
                style: const TextStyle(fontSize: 13)),
        ]),
        _tarjeta(enProduccion ? 'Producción' : 'Para pasar a producción', [
          if (enProduccion)
            _linea({'ok': true, 'texto': 'El bar ya factura en producción'})
          else ...[
            for (final c in comprobaciones) _linea(c),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _ocupado ? null : _produccion,
              icon: const Icon(Icons.rocket_launch_outlined),
              label: const Text('Pasar a producción'),
            ),
          ],
        ]),
      ]);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('Estado · ${widget.nombre}'),
        actions: [IconButton(onPressed: _ocupado ? null : _cargar, icon: const Icon(Icons.refresh))],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: cuerpo),
      ),
    );
  }
}
