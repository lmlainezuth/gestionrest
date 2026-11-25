import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/aviso_sin_conexion.dart';
import '../../core/conexion.dart';
import '../../core/red.dart';
import '../../core/certificado_equipo.dart';
import '../../core/firma_equipo.dart' if (dart.library.io) '../../core/firma_equipo_io.dart';

import '../../core/tema.dart';
import '../barra/venta_offline.dart' show VentaOffline;
import '../ticketbai/cadena_equipo.dart';
import '../ticketbai/caducidad_certificados.dart';
import '../../main.dart';
import '../ticketbai/tbai_proveedor.dart' show probarCertificado;
import '../ticketbai/facturacion_service.dart' show FacturacionService;
import '../ticketbai/verificacion_presencial.dart';
import '../../core/software.dart';

/// Datos fiscales y comerciales del negocio (empresa + TicketBAI + serie de caja).
class EmpresaTab extends StatefulWidget {
  const EmpresaTab({super.key});

  @override
  State<EmpresaTab> createState() => _EmpresaTabState();
}

class _EmpresaTabState extends State<EmpresaTab> {
  final _form = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _razon = TextEditingController();
  final _nif = TextEditingController();
  final _direccion = TextEditingController();
  final _telefono = TextEditingController();
  String? _serieEquipo; // serie propia de este equipo (cobro sin internet); la asigna la base de datos
  bool _asignando = false;
  String _entorno = 'simulado';
  String? _certificado;
  bool _probando = false;
  String? _certEquipo; // nombre del .pfx guardado en este equipo
  Map<String, dynamic>? _empresa, _tbai, _caja;
  bool _cargando = true, _guardando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      _empresa = await supabase.from('empresa').select().limit(1).single();
      _tbai = await supabase.from('tbai_config').select().limit(1).single();
      _caja = await supabase.from('cajas').select().eq('activo', true).limit(1).single();
      _nombre.text = _empresa!['nombre'] as String? ?? '';
      _razon.text = _tbai!['razon_social'] as String? ?? '';
      _nif.text = _tbai!['nif'] as String? ?? '';
      _direccion.text = _empresa!['direccion'] as String? ?? '';
      _telefono.text = _empresa!['telefono'] as String? ?? '';
      _entorno = _tbai!['entorno'] as String? ?? 'simulado';
      _certEquipo = (await CertificadoEquipo.leer())?.nombre;
      _serieEquipo = await CadenaEquipo.serie();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _guardar() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _guardando = true);
    final nif = _nif.text.trim().toUpperCase();
    // Titular nuevo o paso a producción: la caja recibe serie nueva (no se encadena con lo anterior)
    // y la de este equipo hay que volver a asignarla
    final serieNueva = nif != _tbai!['nif'] || (_entorno == 'produccion' && _tbai!['entorno'] != 'produccion');
    try {
      if (_entorno == 'produccion' && _tbai!['entorno'] != 'produccion') {
        FacturacionService.comprobarConfig({
          'entorno': 'produccion',
          'nif': nif,
        });
      }
      // Desde producción no se vuelve a pruebas/simulado: los tickets dejarían de llegar a Hacienda
      if (_tbai!['entorno'] == 'produccion' && _entorno != 'produccion') {
        throw 'El bar ya factura en producción: no se puede volver a pruebas ni a simulado';
      }
      if (serieNueva && (await VentaOffline.cola()).isNotEmpty) {
        throw 'Hay ventas sin internet pendientes de subir: espera a que se suban antes de cambiar el titular o pasar a producción';
      }
      await supabase.from('empresa').update({
        'nombre': _nombre.text.trim(),
        'documento_fiscal': nif,
        'direccion': _direccion.text.trim(),
        'telefono': _telefono.text.trim(),
      }).eq('id', _empresa!['id']);
      await supabase.from('tbai_config').update({
        'nif': nif,
        'razon_social': _razon.text.trim(),
        'entorno': _entorno,
      }).eq('id', _tbai!['id']);
      var aviso = 'Datos guardados';
      if (serieNueva) {
        final s = await supabase.rpc('tbai_asignar_serie', params: {'p_tipo': 'caja', 'p_descripcion': _caja!['nombre']}) as String;
        _caja!['serie_factura'] = s;
        aviso = 'Datos guardados. Serie nueva de la caja: $s';
        if (_serieEquipo != null) {
          await CadenaEquipo.guardarSerie(null);
          _serieEquipo = null;
          aviso += '. Vuelve a asignar la serie de este equipo';
        }
      }
      _tbai!['entorno'] = _entorno;
      _tbai!['nif'] = nif;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(aviso)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
    if (mounted) setState(() => _guardando = false);
  }

  /// Pide a la base de datos una serie libre para este equipo (no se repite nunca para el titular).
  Future<void> _asignarSerieEquipo() async {
    final ctrl = TextEditingController(text: 'TPV barra');
    final nombre = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Asignar serie a este equipo'),
        content: TextField(controller: ctrl, autofocus: true,
            decoration: const InputDecoration(labelText: 'Nombre del equipo', helperText: 'Para saber de quién es cada serie')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Asignar')),
        ],
      ),
    );
    if (nombre == null) return;
    setState(() => _asignando = true);
    try {
      final s = await supabase.rpc('tbai_asignar_serie',
          params: {'p_tipo': 'equipo', 'p_descripcion': nombre.isEmpty ? null : nombre}) as String;
      await CadenaEquipo.guardarSerie(s);
      await VentaOffline.guardarContexto();
      _serieEquipo = s;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Serie de este equipo: $s')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
    if (mounted) setState(() => _asignando = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AvisoSinConexion(textoError(_error), onReintentar: () {
        setState(() {
          _error = null;
          _cargando = true;
        });
        _cargar();
      });
    }
    Widget campo(TextEditingController c, String etiqueta, {String? Function(String?)? validar, String? ayuda, int lineas = 1}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextFormField(
            controller: c,
            validator: validar,
            minLines: 1,
            maxLines: lineas,
            decoration: InputDecoration(labelText: etiqueta, helperText: ayuda),
          ),
        );
    String? obligatorio(String? v) => (v == null || v.trim().isEmpty) ? 'Obligatorio' : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Negocio', style: titulo(20)),
                const SizedBox(height: 12),
                campo(_nombre, 'Nombre comercial', validar: obligatorio),
                campo(_direccion, 'Dirección', lineas: 3, ayuda: 'Un renglón por línea del ticket: calle · barrio · código postal y localidad'),
                campo(_telefono, 'Teléfono'),
                const SizedBox(height: 8),
                Text('Datos fiscales', style: titulo(20)),
                const SizedBox(height: 12),
                campo(_razon, 'Razón social', validar: obligatorio, ayuda: 'Sale en los tickets y facturas'),
                campo(_nif, 'NIF', validar: (v) => (v ?? '').trim().length == 9 ? null : 'El NIF tiene 9 caracteres'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Serie de facturas de esta caja',
                      helperText: 'La asigna el programa y no se repite nunca para este titular. Con NIF: serie + "F"; '
                          'rectificativas: serie + "R". Cambia sola si cambias el NIF o pasas a producción',
                      helperMaxLines: 3,
                    ),
                    child: Text('${_caja!['serie_factura'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(height: 8),
                Text('TicketBAI', style: titulo(20)),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'simulado', label: Text('Simulado')),
                    ButtonSegment(value: 'pruebas', label: Text('Pruebas Hacienda')),
                    ButtonSegment(value: 'produccion', label: Text('Producción')),
                  ],
                  selected: {_entorno},
                  onSelectionChanged: (s) async {
                    final v = s.first;
                    if (v == 'produccion') {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('¿Pasar a producción?'),
                          content: const Text('Las facturas se enviarán de verdad a la Hacienda Foral de Gipuzkoa y tendrán '
                              'efectos fiscales. Necesitas la licencia TicketBAI definitiva del software.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sí, producción')),
                          ],
                        ),
                      );
                      if (ok != true) return;
                    }
                    setState(() => _entorno = v);
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  switch (_entorno) {
                    'pruebas' => 'Se firma con tu certificado y se envía al entorno de pruebas de Gipuzkoa. Sin efectos fiscales.',
                    'produccion' => 'Se firma y se envía a la Hacienda Foral de Gipuzkoa. Con efectos fiscales.',
                    _ => 'No se envía nada a Hacienda (para probar la app y para la tesis).',
                  },
                  style: const TextStyle(color: C.gris, fontSize: 13),
                ),
                const SizedBox(height: 14),
                // Licencia y desarrollador son del programa: iguales en todos los bares (Ajustes › Programa)
                Text(
                  'Software: ${Software.nombre} ${Software.version} · desarrollador ${Software.nifDesarrollador}\n'
                  'Licencia TicketBAI: ${switch (_entorno) {
                    'produccion' => Software.licenciaProduccion.isEmpty
                        ? 'pendiente (se pone en el programa cuando Hacienda lo inscriba)'
                        : Software.licenciaProduccion,
                    _ => Software.licenciaPruebas,
                  }}\n'
                  'Son del programa, iguales en todos los bares: se cambian en Ajustes › Programa',
                  style: const TextStyle(color: C.gris, fontSize: 13),
                ),
                const Align(alignment: Alignment.centerLeft, child: BotonVerificacionTbai()),
                const SizedBox(height: 8),
                Row(children: [
                  OutlinedButton.icon(
                    onPressed: _probando
                        ? null
                        : () async {
                            setState(() => _probando = true);
                            try {
                              final r = await probarCertificado();
                              _certificado = r['error'] != null
                                  ? '${r['error']}'
                                  : 'Certificado correcto: ${r['titular']} · caduca ${(r['caduca'] as String).substring(0, 10)}';
                            } catch (e) {
                              _certificado = 'No se pudo comprobar: $e';
                            }
                            if (mounted) setState(() => _probando = false);
                          },
                    icon: const Icon(Icons.verified_user_outlined),
                    label: Text(_probando ? 'Comprobando…' : 'Comprobar certificado'),
                  ),
                ]),
                if (_certificado != null)
                  Padding(padding: const EdgeInsets.only(top: 8), child: Text(_certificado!, style: const TextStyle(fontSize: 13))),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.borde)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Certificado de este equipo', style: titulo(16)),
                    const SizedBox(height: 4),
                    const Text(
                        'Con el certificado instalado, este TPV o PC firma los tickets él mismo y puede cobrar aunque se '
                        'caiga internet (se envían solos a Hacienda al volver la conexión). Sin él, firma el servidor y '
                        'sin internet no se puede cobrar.',
                        style: TextStyle(color: C.gris, fontSize: 13)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(_certEquipo == null ? 'Sin certificado en este equipo' : 'Instalado: $_certEquipo',
                          style: TextStyle(fontWeight: FontWeight.w600, color: _certEquipo == null ? C.naranja : C.verde)),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final f = await FilePicker.pickFile();
                          if (f == null || !context.mounted) return;
                          final ctrl = TextEditingController();
                          final clave = await showDialog<String>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Contraseña del certificado'),
                              content: TextField(controller: ctrl, obscureText: true, autofocus: true,
                                  decoration: const InputDecoration(labelText: 'La que pusiste al exportarlo')),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
                                FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Instalar')),
                              ],
                            ),
                          );
                          if (clave == null) return;
                          final bytes = await f.readAsBytes();
                          try {
                            // Comprueba contraseña y clave privada antes de guardarlo
                            final c = await FirmaEquipo.certificado(bytes, clave);
                            await CertificadoEquipo.guardar(bytes, clave, f.name);
                            CaducidadCertificados.olvidar();
                            await CaducidadCertificados.registrarEquipo();
                            if (!context.mounted) return;
                            setState(() => _certEquipo = f.name);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text('Certificado instalado: ${c.titular} · caduca ${c.caduca.toLocal().toString().substring(0, 10)}')));
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(content: Text('No se pudo abrir el certificado (¿contraseña?): $e')));
                            }
                          }
                        },
                        icon: const Icon(Icons.key_outlined),
                        label: Text(_certEquipo == null ? 'Instalar certificado (.pfx)' : 'Cambiar'),
                      ),
                      if (_certEquipo != null)
                        TextButton(
                          onPressed: () async {
                            await CertificadoEquipo.quitar();
                            CaducidadCertificados.olvidar();
                            if (mounted) setState(() => _certEquipo = null);
                          },
                          child: const Text('Quitar'),
                        ),
                    ]),
                  const SizedBox(height: 12),
                  Text('Serie propia de este equipo (para cobrar sin internet)', style: titulo(14)),
                  const SizedBox(height: 4),
                  const Text(
                      'Solo en los equipos que cobran sin internet (y con certificado). El programa le da una serie '
                      'que no usa nadie más. Si el equipo se estropea, el de repuesto recibe una nueva.',
                      style: TextStyle(color: C.gris, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(_serieEquipo == null ? 'Sin serie propia' : 'Serie: $_serieEquipo',
                        style: TextStyle(fontWeight: FontWeight.w600, color: _serieEquipo == null ? C.gris : C.verde)),
                    if (_serieEquipo == null)
                      OutlinedButton.icon(
                        onPressed: _asignando ? null : _asignarSerieEquipo,
                        icon: const Icon(Icons.confirmation_number_outlined),
                        label: Text(_asignando ? 'Asignando…' : 'Asignar serie'),
                      ),
                    if (_serieEquipo != null && _tbai!['entorno'] != 'produccion')
                      TextButton(
                        onPressed: () async {
                          if ((await VentaOffline.cola()).isNotEmpty) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Hay ventas sin internet pendientes de subir')));
                            }
                            return;
                          }
                          await CadenaEquipo.guardarSerie(null);
                          if (mounted) setState(() => _serieEquipo = null);
                        },
                        child: const Text('Quitar'),
                      ),
                  ]),
                  ]),
                ),
                const SizedBox(height: 14),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _guardando ? null : _guardar,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_guardando ? 'Guardando…' : 'Guardar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
