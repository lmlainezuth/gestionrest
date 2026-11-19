import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/envio_red.dart' if (dart.library.io) '../../core/envio_red_io.dart' show buscarRed;
import '../../core/escpos.dart';
import '../../core/impresion.dart';
import '../../core/tema.dart';
import '../../main.dart';

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get _windows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Panel de impresoras: qué impresora usa este equipo para tickets, Cocina y Barra, dónde está
/// el cajón, y las impresoras guardadas en la empresa para que otros equipos las elijan sin configurar nada.
class ImpresorasTab extends StatefulWidget {
  const ImpresorasTab({super.key});

  @override
  State<ImpresorasTab> createState() => _ImpresorasTabState();
}

class _ImpresorasTabState extends State<ImpresorasTab> {
  static const _usos = {
    Impresion.ticket: ('Tickets y precuentas', 'Al cobrar sale el ticket y se abre el cajón'),
    'Cocina': ('Comandas de cocina', 'Se imprimen solas al enviar una comanda'),
    'Barra': ('Comandas de barra', 'Se imprimen solas al enviar una comanda'),
  };
  List<Printer> _sistema = [];
  final Map<String, String?> _valor = {};
  String? _cajon;
  List<Map<String, dynamic>> _empresa = [];
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
    _cajon = await Impresion.cajon();
    await _cargarEmpresa();
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _cargarEmpresa() async {
    try {
      final r = await supabase.from('impresoras').select().order('nombre');
      _empresa = [for (final m in r) Map<String, dynamic>.from(m)];
    } catch (_) {
      _empresa = []; // sin internet o sin la migración 0023
    }
  }

  void _avisar(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _guardar(String uso, String? v) async {
    await Impresion.guardar(uso, v);
    setState(() => _valor[uso] = v);
  }

  Future<void> _configurar(String uso) async {
    final v = await editarImpresora(context, titulo: _usos[uso]!.$1, previa: _valor[uso], sistema: _sistema);
    if (v != null) await _guardar(uso, v);
  }

  Future<void> _configurarCajon() async {
    final v = await editarImpresora(context, titulo: 'Conexión del cajón', previa: _cajon, sistema: _sistema, soloDirecta: true);
    if (v == null) return;
    await Impresion.guardarCajon(v);
    setState(() => _cajon = v);
  }

  Future<void> _ponerCajon(String? v) async {
    await Impresion.guardarCajon(v);
    setState(() => _cajon = v);
  }

  Future<void> _guardarEnEmpresa(String uso) async {
    final imp = ImpresoraDirecta.desde(_valor[uso]);
    if (imp == null) return;
    final nombre = TextEditingController(text: imp.nombre ?? _usos[uso]!.$1.split(' ').last);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guardar en la empresa'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nombre, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre (Barra, Cocina…)')),
            const SizedBox(height: 10),
            const Text('Los demás equipos podrán elegirla sin configurar nada.', style: TextStyle(fontSize: 12, color: C.gris)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true || nombre.text.trim().isEmpty) return;
    try {
      final conNombre = imp.conNombre(nombre.text.trim());
      await supabase.from('impresoras').insert({'nombre': conNombre.nombre, 'config': conNombre.toJson()});
      await _guardar(uso, conNombre.valor);
      await _cargarEmpresa();
      if (mounted) setState(() {});
    } catch (e) {
      _avisar('No se pudo guardar (hace falta internet y ser administrador): $e');
    }
  }

  Future<void> _borrarDeEmpresa(Map<String, dynamic> m) async {
    try {
      await supabase.from('impresoras').delete().eq('id', m['id']);
      await _cargarEmpresa();
      if (mounted) setState(() {});
    } catch (e) {
      _avisar('No se pudo borrar: $e');
    }
  }

  Future<void> _probar(String? valor, {bool cajon = false}) async {
    try {
      if (cajon) {
        await Impresion.abrirCajon();
        return;
      }
      final imp = ImpresoraDirecta.desde(valor);
      if (imp != null) {
        await imprimirPrueba(imp);
      } else {
        await Impresion.imprimirComanda(Impresion.ticket, 'PRUEBA', [
          {'cantidad': 1, 'descripcion': 'Prueba de impresión ñ á é í ó ú', 'curso': 'ya', 'nota': 'GestiónRest'},
        ]);
      }
    } catch (e) {
      if (mounted) _avisar('No responde la impresora: $e');
    }
  }

  String _descripcion(String? v) {
    final r = ImpresoraDirecta.desde(v);
    if (r != null) return r.descripcion;
    if (v == null) return 'Ninguna';
    return 'Del sistema (PDF) · ${_sistema.where((p) => p.url == v).firstOrNull?.name ?? v}';
  }

  String get _descripcionCajon => switch (_cajon) {
        null => 'En la impresora de tickets (se abre en el mismo envío)',
        'ninguno' => 'No hay cajón',
        final v => 'Conexión propia · ${ImpresoraDirecta.desde(v)?.descripcion ?? v}',
      };

  Widget _tarjeta({required String nombre, required String texto, required String estado, required List<Widget> botones}) =>
      Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.borde)),
        child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 360,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(nombre, style: titulo(18)),
              Text(texto, style: const TextStyle(color: C.gris, fontSize: 13)),
              const SizedBox(height: 6),
              Text(estado, style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
          ...botones,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        const Text(
            'Configuración de este equipo. Lo mejor es una impresora directa (red, USB del TPV o Windows directa): '
            'imprime al instante, corta el papel y abre el cajón. Si la impresora ya está guardada en la empresa, elígela de la lista.',
            style: TextStyle(color: C.gris)),
        const SizedBox(height: 20),
        for (final e in _usos.entries)
          _tarjeta(
            nombre: e.value.$1,
            texto: e.value.$2,
            estado: _descripcion(_valor[e.key]),
            botones: [
              FilledButton.icon(onPressed: () => _configurar(e.key), icon: const Icon(Icons.tune), label: const Text('Configurar')),
              if (_empresa.isNotEmpty)
                PopupMenuButton<Map<String, dynamic>>(
                  tooltip: 'Impresoras de la empresa',
                  onSelected: (m) => _guardar(
                      e.key, ImpresoraDirecta.fromJson(Map<String, dynamic>.from(m['config'] as Map)).conNombre(m['nombre'] as String).valor),
                  itemBuilder: (_) => [for (final m in _empresa) PopupMenuItem(value: m, child: Text('${m['nombre']}'))],
                  child: const Chip(avatar: Icon(Icons.business_outlined, size: 18), label: Text('De la empresa')),
                ),
              if (_valor[e.key] != null) ...[
                IconButton(tooltip: 'Imprimir prueba', onPressed: () => _probar(_valor[e.key]), icon: const Icon(Icons.receipt_long)),
                if (ImpresoraDirecta.desde(_valor[e.key]) != null)
                  IconButton(tooltip: 'Guardar en la empresa', onPressed: () => _guardarEnEmpresa(e.key), icon: const Icon(Icons.cloud_upload_outlined)),
                IconButton(tooltip: 'Quitar', onPressed: () => _guardar(e.key, null), icon: const Icon(Icons.close)),
              ],
            ],
          ),
        _tarjeta(
          nombre: 'Cajón',
          texto: 'Normalmente va enchufado a la impresora de tickets. En algunos TPV va en la propia torre (por ejemplo /dev/ttyS1).',
          estado: _descripcionCajon,
          botones: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ticket', label: Text('En la impresora')),
                ButtonSegment(value: 'propia', label: Text('Otra conexión')),
                ButtonSegment(value: 'ninguno', label: Text('No hay')),
              ],
              selected: {_cajon == null ? 'ticket' : _cajon == 'ninguno' ? 'ninguno' : 'propia'},
              onSelectionChanged: (s) => switch (s.first) {
                'ticket' => _ponerCajon(null),
                'ninguno' => _ponerCajon('ninguno'),
                _ => _configurarCajon(),
              },
            ),
            if (_cajon != null && _cajon != 'ninguno')
              IconButton(tooltip: 'Cambiar conexión', onPressed: _configurarCajon, icon: const Icon(Icons.tune)),
            if (_cajon != 'ninguno')
              OutlinedButton.icon(
                onPressed: () => _probar(null, cajon: true),
                icon: const Icon(Icons.point_of_sale),
                label: const Text('Probar cajón'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text('Impresoras de la empresa', style: titulo(18)),
        const SizedBox(height: 4),
        const Text('Guárdalas con el botón de la nube y en los demás equipos solo hay que elegirlas.',
            style: TextStyle(color: C.gris, fontSize: 13)),
        const SizedBox(height: 10),
        if (_empresa.isEmpty) const Text('Todavía no hay ninguna (o no hay conexión).', style: TextStyle(color: C.gris)),
        for (final m in _empresa)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: C.borde)),
            child: ListTile(
              leading: const Icon(Icons.print_outlined),
              title: Text('${m['nombre']}'),
              subtitle: Text(ImpresoraDirecta.fromJson(Map<String, dynamic>.from(m['config'] as Map)).descripcion),
              trailing: IconButton(tooltip: 'Borrar', onPressed: () => _borrarDeEmpresa(m), icon: const Icon(Icons.delete_outline)),
            ),
          ),
      ],
    );
  }
}

/// Ticket de prueba: tildes, €, QR y corte. Sirve para elegir el perfil correcto.
Future<void> imprimirPrueba(ImpresoraDirecta imp) {
  final t = imp.ticket()
    ..linea('PRUEBA', centro: true, grande: true)
    ..linea('GestiónRest', centro: true, fuerte: true)
    ..raya()
    ..linea(imp.descripcion)
    ..raya()
    ..linea('Tildes: á é í ó ú Á É Í Ó Ú')
    ..linea('Eñes: ñ Ñ · ¿? ¡! · ü')
    ..fila('Euro', '12,50 €')
    ..raya()
    ..linea('QR (debe verse un cuadrado):', centro: true)
    ..qr('https://gestionrest.netlify.app', modulo: 5)
    ..linea('Si todo se lee bien, el perfil es correcto', centro: true);
  t.cortar();
  return imp.enviar(t);
}

/// Editor de una impresora. Devuelve lo que hay que guardar (JSON de impresora directa o url del sistema).
Future<String?> editarImpresora(BuildContext context,
    {required String titulo, String? previa, List<Printer> sistema = const [], bool soloDirecta = false}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _EditorImpresora(titulo: titulo, previa: previa, sistema: sistema, soloDirecta: soloDirecta),
  );
}

class _EditorImpresora extends StatefulWidget {
  const _EditorImpresora({required this.titulo, required this.previa, required this.sistema, required this.soloDirecta});
  final String titulo;
  final String? previa;
  final List<Printer> sistema;
  final bool soloDirecta;

  @override
  State<_EditorImpresora> createState() => _EditorImpresoraState();
}

class _EditorImpresoraState extends State<_EditorImpresora> {
  late String _tipo;
  final _ip = TextEditingController(text: '192.168.1.');
  final _puertoRed = TextEditingController(text: '9100');
  final _serie = TextEditingController(text: '/dev/ttyS1');
  final _m = TextEditingController();
  final _t1 = TextEditingController();
  final _t2 = TextEditingController();
  int _vid = 0, _pid = 0, _baudios = 0, _ancho = 80;
  String? _win, _url;
  PerfilImpresora _perfil = PerfilImpresora.generico;
  List<Map<String, dynamic>> _usb = [];
  List<String> _puertos = [], _red = [];
  bool _buscando = false, _probando = false;
  String? _mensaje;

  List<(String, String)> get _tipos => [
        if (!kIsWeb) ('red', 'Red'),
        if (_android) ('usb', 'USB del TPV'),
        if (_android) ('serie', 'Puerto serie'),
        if (_windows) ('win', 'Windows directa'),
        if (!widget.soloDirecta && widget.sistema.isNotEmpty) ('sistema', 'Del sistema (PDF)'),
      ];

  @override
  void initState() {
    super.initState();
    final imp = ImpresoraDirecta.desde(widget.previa);
    if (imp != null) {
      _tipo = imp.tipo;
      _ancho = imp.ancho;
      _perfil = imp.perfil;
      switch (imp.tipo) {
        case 'red':
          _ip.text = imp.direccion;
          _puertoRed.text = '${imp.numero}';
        case 'usb':
          _vid = int.tryParse(imp.direccion) ?? 0;
          _pid = imp.numero;
        case 'serie':
          _serie.text = imp.direccion;
          _baudios = imp.numero;
        case 'win':
          _win = imp.direccion;
      }
    } else if (widget.previa != null && widget.previa != 'ninguno' && !widget.soloDirecta) {
      _tipo = 'sistema';
      _url = widget.previa;
    } else {
      _tipo = _android ? 'usb' : (_windows ? 'win' : 'red');
    }
    if (!_tipos.any((t) => t.$1 == _tipo)) _tipo = _tipos.isEmpty ? 'red' : _tipos.first.$1;
    _ponerCajonTextos();
    if (_android) _cargarAndroid();
  }

  void _ponerCajonTextos() {
    _m.text = '${_perfil.cajon[0]}';
    _t1.text = '${_perfil.cajon[1]}';
    _t2.text = '${_perfil.cajon[2]}';
  }

  Future<void> _cargarAndroid() async {
    try {
      _usb = await ImpresoraDirecta.listarUsb();
      _puertos = await ImpresoraDirecta.listarSerie();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _buscarRed() async {
    setState(() => _buscando = true);
    try {
      _red = await buscarRed();
      _mensaje = _red.isEmpty ? 'No se encontró ninguna impresora de red (puerto 9100)' : null;
    } catch (e) {
      _mensaje = 'Error al buscar: $e';
    }
    if (mounted) setState(() => _buscando = false);
  }

  PerfilImpresora get _perfilEditado => _perfil.copia(cajon: [
        int.tryParse(_m.text) ?? _perfil.cajon[0],
        int.tryParse(_t1.text) ?? _perfil.cajon[1],
        int.tryParse(_t2.text) ?? _perfil.cajon[2],
      ]);

  ImpresoraDirecta? get _impresora => switch (_tipo) {
        'red' => ImpresoraDirecta(
            tipo: 'red', direccion: _ip.text.trim(), numero: int.tryParse(_puertoRed.text) ?? 9100, ancho: _ancho, perfil: _perfilEditado),
        'usb' => ImpresoraDirecta(tipo: 'usb', direccion: '$_vid', numero: _pid, ancho: _ancho, perfil: _perfilEditado),
        'serie' => ImpresoraDirecta(tipo: 'serie', direccion: _serie.text.trim(), numero: _baudios, ancho: _ancho, perfil: _perfilEditado),
        'win' => _win == null ? null : ImpresoraDirecta(tipo: 'win', direccion: _win!, ancho: _ancho, perfil: _perfilEditado),
        _ => null,
      };

  Future<void> _probar({bool cajon = false}) async {
    final imp = _impresora;
    if (imp == null) return;
    setState(() {
      _probando = true;
      _mensaje = null;
    });
    try {
      if (cajon) {
        await imp.abrirCajon();
      } else {
        await imprimirPrueba(imp);
      }
      _mensaje = cajon ? 'Orden de abrir el cajón enviada' : 'Prueba enviada: revisa tildes, € y QR';
    } catch (e) {
      _mensaje = 'No responde: $e';
    }
    if (mounted) setState(() => _probando = false);
  }

  void _aceptar() {
    if (_tipo == 'sistema') {
      if (_url != null) Navigator.pop(context, _url);
      return;
    }
    final imp = _impresora;
    if (imp == null || imp.direccion.isEmpty) return;
    Navigator.pop(context, imp.valor);
  }

  Widget _opcion(String texto, String? sub, bool sel, VoidCallback onTap) => ListTile(
        dense: true,
        selected: sel,
        leading: Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off),
        title: Text(texto),
        subtitle: sub == null ? null : Text(sub),
        onTap: onTap,
      );

  List<Widget> _conexion() => switch (_tipo) {
        'red' => [
            Row(children: [
              Expanded(flex: 3, child: TextField(controller: _ip, decoration: const InputDecoration(labelText: 'IP de la impresora'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _puertoRed, decoration: const InputDecoration(labelText: 'Puerto'), keyboardType: TextInputType.number)),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _buscando ? null : _buscarRed,
                icon: _buscando ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.search),
                label: Text(_buscando ? 'Buscando en la red…' : 'Buscar impresoras en la red'),
              ),
            ),
            for (final ip in _red)
              _opcion(ip, 'Responde en el puerto 9100', _ip.text == ip, () => setState(() {
                    _ip.text = ip;
                    _puertoRed.text = '9100';
                  })),
          ],
        'usb' => [
            _opcion('Buscarla sola', 'La primera impresora USB que encuentre', _vid == 0 && _pid == 0, () => setState(() => _vid = _pid = 0)),
            for (final d in _usb)
              _opcion('${d['nombre']}', 'vid ${d['vid']} · pid ${d['pid']}${d['impresora'] == true ? '' : ' · no parece impresora'}',
                  _vid == d['vid'] && _pid == d['pid'], () => setState(() {
                        _vid = d['vid'] as int;
                        _pid = d['pid'] as int;
                      })),
            const Text('La primera vez Android pide permiso: marca "Usar siempre" y acepta.', style: TextStyle(fontSize: 12, color: C.gris)),
          ],
        'serie' => [
            TextField(controller: _serie, decoration: const InputDecoration(labelText: 'Puerto (ej. /dev/ttyS1)')),
            if (_puertos.isNotEmpty)
              Wrap(spacing: 6, children: [
                for (final p in _puertos)
                  ChoiceChip(label: Text(p), selected: _serie.text == p, onSelected: (_) => setState(() => _serie.text = p)),
              ]),
            const SizedBox(height: 8),
            DropdownButton<int>(
              value: _baudios,
              isExpanded: true,
              items: [
                for (final b in [0, 9600, 19200, 38400, 57600, 115200])
                  DropdownMenuItem(value: b, child: Text(b == 0 ? 'Velocidad: la del sistema' : 'Velocidad: $b')),
              ],
              onChanged: (v) => setState(() => _baudios = v ?? 0),
            ),
          ],
        'win' => [
            if (widget.sistema.isEmpty) const Text('No hay impresoras instaladas en Windows.', style: TextStyle(color: C.gris)),
            for (final p in widget.sistema) _opcion(p.name, null, _win == p.name, () => setState(() => _win = p.name)),
            const Text('Manda el ticket directo (sin PDF): corta el papel y abre el cajón.', style: TextStyle(fontSize: 12, color: C.gris)),
          ],
        _ => [
            for (final p in widget.sistema) _opcion(p.name, null, _url == p.url, () => setState(() => _url = p.url)),
            const Text('Imprime como PDF: vale cualquier impresora, pero no abre el cajón.', style: TextStyle(fontSize: 12, color: C.gris)),
          ],
      };

  @override
  Widget build(BuildContext context) {
    final directa = _tipo != 'sistema';
    return AlertDialog(
      title: Text(widget.titulo),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (id, texto) in _tipos)
                ChoiceChip(label: Text(texto), selected: _tipo == id, onSelected: (_) => setState(() => _tipo = id)),
            ]),
            const SizedBox(height: 14),
            ..._conexion(),
            if (directa) ...[
              const SizedBox(height: 14),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 58, label: Text('Papel 58 mm')),
                  ButtonSegment(value: 80, label: Text('Papel 80 mm')),
                ],
                selected: {_ancho},
                onSelectionChanged: (s) => setState(() => _ancho = s.first),
              ),
              const SizedBox(height: 10),
              DropdownButton<String>(
                value: _perfil.id,
                isExpanded: true,
                items: [
                  for (final p in PerfilImpresora.lista) DropdownMenuItem(value: p.id, child: Text('Modelo: ${p.nombre}')),
                ],
                onChanged: (id) => setState(() {
                  _perfil = PerfilImpresora.porId(id);
                  _ponerCajonTextos();
                }),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Avanzado (si salen símbolos raros, no corta o no abre el cajón)'),
                children: [
                  DropdownButton<int>(
                    value: _perfil.pagina,
                    isExpanded: true,
                    items: [
                      for (final e in PerfilImpresora.paginas.entries)
                        DropdownMenuItem(value: e.key, child: Text('Caracteres: ${e.value}')),
                    ],
                    onChanged: (v) => setState(() => _perfil = _perfil.copia(pagina: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _perfil.chino,
                    onChanged: (v) => setState(() => _perfil = _perfil.copia(chino: v)),
                    title: const Text('Quitar modo chino (TPV chinos)'),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _perfil.qrNativo,
                    onChanged: (v) => setState(() => _perfil = _perfil.copia(qrNativo: v)),
                    title: const Text('QR con el comando de la impresora'),
                    subtitle: const Text('Desactívalo si el QR no sale: se manda como imagen'),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _perfil.corteTotal,
                    onChanged: (v) => setState(() => _perfil = _perfil.copia(corteTotal: v)),
                    title: const Text('Corte total del papel'),
                  ),
                  const Align(alignment: Alignment.centerLeft, child: Text('Cajón (ESC p m t1 t2):')),
                  Row(children: [
                    for (final (c, l) in [(_m, 'm (0 o 1)'), (_t1, 't1'), (_t2, 't2')])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: TextField(controller: c, decoration: InputDecoration(labelText: l), keyboardType: TextInputType.number),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 8),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: _probando ? null : () => _probar(),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Imprimir prueba'),
                ),
                OutlinedButton.icon(
                  onPressed: _probando ? null : () => _probar(cajon: true),
                  icon: const Icon(Icons.point_of_sale),
                  label: const Text('Probar cajón'),
                ),
              ]),
            ],
            if (_mensaje != null) ...[
              const SizedBox(height: 8),
              Text(_mensaje!, style: const TextStyle(color: C.naranja, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _aceptar, child: const Text('Guardar')),
      ],
    );
  }
}
