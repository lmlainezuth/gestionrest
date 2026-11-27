import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/panel_lateral.dart';
import '../../core/red.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../gestion/comun.dart' show SelectorMes, meses;
import 'fichajes_comun.dart';

const _dias = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
const _rojo = Color(0xFFB3261E);

String _fechaDia(String clave) {
  final d = DateTime.parse(clave);
  return '${_dias[d.weekday - 1]} ${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

/// Registro de jornada: horas de cada empleado, correcciones con motivo e informe para Inspección.
class FichajesPage extends StatefulWidget {
  const FichajesPage({super.key});

  @override
  State<FichajesPage> createState() => _FichajesPageState();
}

class _FichajesPageState extends State<FichajesPage> {
  DateTime _mes = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> _todos = [];
  List<Map<String, dynamic>> _equipo = [];
  bool _cargando = true;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await online(() async {
        // Un día de margen por los turnos que pasan de medianoche
        final desde = DateTime(_mes.year, _mes.month, 1).subtract(const Duration(days: 1));
        final hasta = DateTime(_mes.year, _mes.month + 1, 2);
        final r = await Future.wait<dynamic>([
          supabase
              .from('fichajes')
              .select()
              .gte('momento', desde.toUtc().toIso8601String())
              .lt('momento', hasta.toUtc().toIso8601String())
              .order('momento'),
          supabase.rpc('equipo_empresa'),
        ]);
        _todos = List<Map<String, dynamic>>.from(r[0] as List);
        _equipo = List<Map<String, dynamic>>.from(r[1] as List);
      });
      if (mounted) {
        setState(() {
          _cargando = false;
          _errorCarga = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorCarga = textoError(e);
          _cargando = false;
        });
      }
    }
  }

  bool _delMes(Jornada j) {
    final d = DateTime.parse(j.dia);
    return d.year == _mes.year && d.month == _mes.month;
  }

  /// Por persona: sus jornadas del mes.
  Map<String, ({String nombre, List<Jornada> js})> _porPersona() {
    final vig = vigentes(_todos);
    final ids = <String, String>{};
    for (final f in vig) {
      ids[(f['usuario_id'] ?? f['nombre']) as String] = f['nombre'] as String;
    }
    return {
      for (final e in ids.entries)
        e.key: (
          nombre: e.value,
          js: jornadas([for (final f in vig) if ((f['usuario_id'] ?? f['nombre']) == e.key) f], ahora: DateTime.now())
              .where(_delMes)
              .toList(),
        ),
    };
  }

  bool _corregido(Jornada j) => j.registros.any((f) => f['origen'] == 'correccion');
  bool _sinInternet(Jornada j) => j.registros.any((f) => f['origen'] == 'sin_conexion');

  Future<void> _abrirJornada(String usuario, String nombre, Jornada? j) async {
    try {
      exigirConexion();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
      return;
    }
    final cambiado = await mostrarPanel<bool>(
      context,
      (_) => _PanelJornada(usuario: usuario, nombre: nombre, jornada: j, equipo: _equipo, mes: _mes),
    );
    if (cambiado == true) await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCarga != null) return AvisoSinConexion(_errorCarga!, onReintentar: _cargar);
    final personas = _porPersona();
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SelectorMes(
            mes: _mes,
            onCambio: (m) {
              setState(() {
                _mes = m;
                _cargando = true;
              });
              _cargar();
            },
          ),
          FilledButton.icon(
            onPressed: personas.isEmpty ? null : () => _pdf(personas),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Informe del mes (PDF)'),
          ),
          OutlinedButton.icon(
            onPressed: () => _abrirJornada('', '', null),
            icon: const Icon(Icons.add),
            label: const Text('Añadir fichaje olvidado'),
          ),
        ]),
        const SizedBox(height: 8),
        const Text('Los fichajes no se borran: cada cambio queda guardado con su motivo, como pide la ley. '
            'Conservar 4 años.', style: TextStyle(color: C.gris, fontSize: 13)),
        const SizedBox(height: 16),
        if (_cargando)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (personas.isEmpty)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Center(
              child: Text('Nadie ha fichado este mes.\nSe ficha desde la pantalla de entrada: nombre → PIN → "Fichar".',
                  textAlign: TextAlign.center, style: TextStyle(color: C.gris)),
            ),
          ),
        for (final p in personas.entries) _persona(p.key, p.value.nombre, p.value.js),
      ],
    );
  }

  Widget _persona(String usuario, String nombre, List<Jornada> js) {
    final total = js.fold(0, (s, j) => s + j.minutos);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
      color: C.blanco,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: C.borde)),
      child: ExpansionTile(
        shape: const Border(),
        leading: CircleAvatar(backgroundColor: C.verde, child: Text(nombre[0].toUpperCase(), style: const TextStyle(color: Colors.white))),
        title: Text(nombre, style: titulo(17)),
        subtitle: Text('${js.length} jornadas · ${horasMin(total)}', style: const TextStyle(color: C.gris)),
        children: [
          for (final j in js.reversed)
            ListTile(
              onTap: () => _abrirJornada(usuario, nombre, j),
              title: Text(_fechaDia(j.dia), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([
                '${j.entrada == null ? '¿?' : hora(j.entrada!)} → ${j.salida == null ? (j.abierta ? 'sin salida' : '¿?') : hora(j.salida!)}',
                if (j.pausa > 0) 'pausa ${j.pausa} min',
                if (_corregido(j)) 'corregido',
                if (_sinInternet(j)) 'fichado sin internet',
              ].join(' · ')),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (j.abierta || j.entrada == null) const Icon(Icons.warning_amber_rounded, color: C.naranja),
                const SizedBox(width: 6),
                Text(horasMin(j.minutos), style: titulo(15)),
                const Icon(Icons.chevron_right, color: C.gris),
              ]),
            ),
        ],
      ),
      )
    );
  }

  Future<void> _pdf(Map<String, ({String nombre, List<Jornada> js})> personas) async {
    pw.ThemeData tema;
    try {
      tema = pw.ThemeData.withFont(base: await PdfGoogleFonts.robotoRegular(), bold: await PdfGoogleFonts.robotoBold());
    } catch (_) {
      tema = pw.ThemeData.base();
    }
    final empresa = Perfil.cache?.empresaNombre ?? '';
    final periodo = '${meses[_mes.month - 1]} ${_mes.year}';
    final doc = pw.Document();
    for (final p in personas.values) {
      final js = [...p.js]..sort((a, b) => a.dia.compareTo(b.dia));
      final total = js.fold(0, (s, j) => s + j.minutos);
      final correcciones = [
        for (final j in js)
          for (final f in j.registros)
            if (f['origen'] == 'correccion')
              '${_fechaDia(j.dia)} ${hora(momento(f))} ${nombresFichaje[f['tipo']]}: ${f['motivo'] ?? ''}',
      ];
      doc.addPage(pw.MultiPage(
        theme: tema,
        pageFormat: PdfPageFormat.a4,
        build: (_) => [
          pw.Text('Registro de jornada', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.Text('Empresa: $empresa · Trabajador/a: ${p.nombre} · Periodo: $periodo'),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: ['Día', 'Entrada', 'Salida', 'Pausas', 'Horas'],
            data: [
              for (final j in js)
                [
                  _fechaDia(j.dia),
                  j.entrada == null ? '-' : hora(j.entrada!),
                  j.salida == null ? '-' : hora(j.salida!),
                  j.pausa == 0 ? '-' : '${j.pausa} min',
                  horasMin(j.minutos),
                ],
            ],
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.Text('Total del mes: ${horasMin(total)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          if (correcciones.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text('Correcciones (registro original conservado)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            for (final c in correcciones) pw.Text('· $c', style: const pw.TextStyle(fontSize: 9)),
          ],
          pw.SizedBox(height: 40),
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('Firma de la empresa: ____________________'),
            pw.Text('Firma del trabajador/a: ____________________'),
          ]),
        ],
      ));
    }
    await Printing.layoutPdf(name: 'Registro de jornada $periodo', onLayout: (_) async => doc.save());
  }
}

// =====================================================================
// Corregir una jornada (o añadir un fichaje olvidado)
// =====================================================================

class _PanelJornada extends StatefulWidget {
  const _PanelJornada({required this.usuario, required this.nombre, required this.jornada, required this.equipo, required this.mes});
  final String usuario, nombre;
  final Jornada? jornada;
  final List<Map<String, dynamic>> equipo;
  final DateTime mes;

  @override
  State<_PanelJornada> createState() => _PanelJornadaState();
}

class _PanelJornadaState extends State<_PanelJornada> {
  late String? _usuario = widget.usuario.isEmpty ? null : widget.usuario;
  late String _nombre = widget.nombre;
  late DateTime _fecha = widget.jornada == null ? DateTime.now() : DateTime.parse(widget.jornada!.dia);
  String _tipo = 'entrada';
  TimeOfDay _hora = TimeOfDay.now();
  final _motivo = TextEditingController();
  bool _guardando = false;
  String? _err;

  Future<String?> _pedirMotivo(String que) => showDialog<String>(
        context: context,
        builder: (ctx) {
          final c = TextEditingController();
          return AlertDialog(
            title: Text(que),
            content: TextField(
              controller: c,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Motivo (obligatorio)', hintText: 'Se olvidó de fichar la salida'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Guardar')),
            ],
          );
        },
      );

  Future<void> _insertar(Map<String, dynamic> fila) async {
    setState(() {
      _guardando = true;
      _err = null;
    });
    try {
      await supabase.from('fichajes').insert({
        ...fila,
        'origen': 'correccion',
        'hecho_por': supabase.auth.currentUser!.id,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _err = textoError(e);
        _guardando = false;
      });
    }
  }

  Future<void> _cambiarHora(Map<String, dynamic> f) async {
    final m = momento(f);
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(m));
    if (t == null || !mounted) return;
    final motivo = await _pedirMotivo('Cambiar ${nombresFichaje[f['tipo']]!.toLowerCase()} a las ${t.format(context)}');
    if (motivo == null || motivo.isEmpty) return;
    final nuevo = DateTime(m.year, m.month, m.day, t.hour, t.minute);
    await _insertar({
      'usuario_id': f['usuario_id'],
      'nombre': f['nombre'],
      'tipo': f['tipo'],
      'momento': nuevo.toUtc().toIso8601String(),
      'corrige_id': f['id'],
      'motivo': motivo,
    });
  }

  Future<void> _anular(Map<String, dynamic> f) async {
    final motivo = await _pedirMotivo('Anular ${nombresFichaje[f['tipo']]!.toLowerCase()} de las ${hora(momento(f))}');
    if (motivo == null || motivo.isEmpty) return;
    await _insertar({
      'usuario_id': f['usuario_id'],
      'nombre': f['nombre'],
      'tipo': f['tipo'],
      'momento': f['momento'],
      'corrige_id': f['id'],
      'anula': true,
      'motivo': motivo,
    });
  }

  Future<void> _anadir() async {
    if (_usuario == null) return setState(() => _err = 'Elige la persona');
    if (_motivo.text.trim().isEmpty) return setState(() => _err = 'Escribe el motivo');
    await _insertar({
      'usuario_id': _usuario,
      'nombre': _nombre,
      'tipo': _tipo,
      'momento': DateTime(_fecha.year, _fecha.month, _fecha.day, _hora.hour, _hora.minute).toUtc().toIso8601String(),
      'motivo': _motivo.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final j = widget.jornada;
    return PanelLateral(
      encabezado: j == null ? 'Añadir fichaje' : '${widget.nombre} · ${_fechaDia(j.dia)}',
      boton: _guardando ? 'Guardando…' : 'Añadir este fichaje',
      onBoton: _guardando ? null : _anadir,
      cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (j != null) ...[
          for (final f in j.registros)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              decoration: BoxDecoration(border: Border.all(color: C.borde), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${nombresFichaje[f['tipo']]} · ${hora(momento(f))}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      switch (f['origen']) {
                        'correccion' => 'Corregido: ${f['motivo']}',
                        'sin_conexion' => _textoSinInternet(f),
                        _ => 'Fichado en el TPV',
                      },
                      style: const TextStyle(color: C.gris, fontSize: 12),
                    ),
                  ]),
                ),
                IconButton(tooltip: 'Cambiar hora', onPressed: _guardando ? null : () => _cambiarHora(f), icon: const Icon(Icons.schedule)),
                IconButton(tooltip: 'Anular', onPressed: _guardando ? null : () => _anular(f), icon: const Icon(Icons.block, color: _rojo)),
              ]),
            ),
          const SizedBox(height: 10),
          Text('Añadir un fichaje olvidado a este día', style: titulo(17)),
        ] else ...[
          const EtiquetaCampo('Persona'),
          DropdownButtonFormField<String>(
            initialValue: _usuario,
            isExpanded: true,
            items: [
              for (final p in widget.equipo) DropdownMenuItem(value: p['id'] as String, child: Text(p['nombre'] as String)),
            ],
            onChanged: (v) => setState(() {
              _usuario = v;
              _nombre = widget.equipo.firstWhere((p) => p['id'] == v)['nombre'] as String;
            }),
          ),
          const EtiquetaCampo('Día'),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _fecha,
                firstDate: DateTime.now().subtract(const Duration(days: 365)),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _fecha = d);
            },
            icon: const Icon(Icons.calendar_today),
            label: Text('${_fecha.day}/${_fecha.month}/${_fecha.year}'),
          ),
        ],
        const EtiquetaCampo('Tipo'),
        Segmentos(
          opciones: const {'entrada': 'Entrada', 'pausa': 'Pausa', 'vuelta': 'Vuelta', 'salida': 'Salida'},
          actual: _tipo,
          onCambio: (v) => setState(() => _tipo = v),
        ),
        const EtiquetaCampo('Hora'),
        OutlinedButton.icon(
          onPressed: () async {
            final t = await showTimePicker(context: context, initialTime: _hora);
            if (t != null) setState(() => _hora = t);
          },
          icon: const Icon(Icons.schedule),
          label: Text(_hora.format(context)),
        ),
        const EtiquetaCampo('Motivo'),
        TextField(controller: _motivo, decoration: const InputDecoration(hintText: 'Se olvidó de fichar')),
        if (_err != null) ...[
          const SizedBox(height: 12),
          Text(_err!, style: const TextStyle(color: _rojo, fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }
}

/// Un fichaje sin internet lleva la hora que dijo el equipo; si llegó mucho más tarde se ve
/// cuándo, para poder revisarlo (la hora fichada la pone el equipo, no el servidor).
String _textoSinInternet(Map<String, dynamic> f) {
  final llego = f['registrado_en'] == null ? null : DateTime.parse(f['registrado_en'] as String).toLocal();
  if (llego == null || llego.difference(momento(f)).inMinutes < 10) return 'Fichado sin internet';
  final d = '${llego.day.toString().padLeft(2, '0')}/${llego.month.toString().padLeft(2, '0')}';
  return 'Fichado sin internet · llegó el $d a las ${hora(llego)}: revísalo';
}
