import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/certificado_equipo.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../ticketbai/tbai_proveedor.dart' show probarCertificado;
import '../carta/colores.dart' show leerImporte;

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
  final _iva = TextEditingController();
  final _serie = TextEditingController();
  final _licencia = TextEditingController();
  final _nifDesarrollador = TextEditingController();
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
      _iva.text = (_tbai!['tipo_iva'] as num).toStringAsFixed(0);
      _serie.text = _caja!['serie_factura'] as String? ?? '';
      _licencia.text = _tbai!['licencia_tbai'] as String? ?? '';
      _nifDesarrollador.text = _tbai!['nif_desarrollador'] as String? ?? '';
      _entorno = _tbai!['entorno'] as String? ?? 'simulado';
      _certEquipo = (await CertificadoEquipo.leer())?.nombre;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _guardar() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _guardando = true);
    final nif = _nif.text.trim().toUpperCase();
    final iva = leerImporte(_iva.text)!;
    try {
      await supabase.from('empresa').update({
        'nombre': _nombre.text.trim(),
        'documento_fiscal': nif,
        'direccion': _direccion.text.trim(),
        'telefono': _telefono.text.trim(),
        'impuesto_porcentaje': iva,
      }).eq('id', _empresa!['id']);
      await supabase.from('tbai_config').update({
        'nif': nif,
        'razon_social': _razon.text.trim(),
        'tipo_iva': iva,
        'licencia_tbai': _licencia.text.trim().isEmpty ? null : _licencia.text.trim(),
        'nif_desarrollador': _nifDesarrollador.text.trim().isEmpty ? null : _nifDesarrollador.text.trim().toUpperCase(),
        'entorno': _entorno,
      }).eq('id', _tbai!['id']);
      await supabase.from('cajas').update({'serie_factura': _serie.text.trim().toUpperCase()}).eq('id', _caja!['id']);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Datos guardados')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
    if (mounted) setState(() => _guardando = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Error: $_error'));
    Widget campo(TextEditingController c, String etiqueta, {String? Function(String?)? validar, String? ayuda}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextFormField(
            controller: c,
            validator: validar,
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
                campo(_direccion, 'Dirección'),
                campo(_telefono, 'Teléfono'),
                const SizedBox(height: 8),
                Text('Datos fiscales', style: titulo(20)),
                const SizedBox(height: 12),
                campo(_razon, 'Razón social', validar: obligatorio, ayuda: 'Sale en los tickets y facturas'),
                campo(_nif, 'NIF', validar: (v) => (v ?? '').trim().length == 9 ? null : 'El NIF tiene 9 caracteres'),
                campo(_iva, 'IVA de hostelería (%)', validar: (v) => leerImporte(v ?? '') == null ? 'Número no válido' : null),
                campo(_serie, 'Serie de facturas de esta caja', validar: obligatorio, ayuda: 'Ejemplo: T1. Las facturas con NIF usan la serie + "F"'),
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
                    setState(() {
                      _entorno = v;
                      // Licencia de pruebas que publica Gipuzkoa para su entorno de pruebas
                      if (v == 'pruebas' && _licencia.text.trim().isEmpty) _licencia.text = 'TBAIGIPRE00000000001';
                    });
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
                campo(_licencia, 'Licencia TicketBAI', ayuda: 'En pruebas: TBAIGIPRE00000000001. En producción, la que da Hacienda al registrar el software'),
                campo(_nifDesarrollador, 'NIF del desarrollador del software', ayuda: 'El NIF de quien hace la app (va en cada factura)'),
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
                        'Para enviar las facturas a Hacienda desde este TPV o PC. Se instala una vez en cada equipo que cobra. '
                        'La firma la sigue haciendo el servidor.',
                        style: TextStyle(color: C.gris, fontSize: 13)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(_certEquipo == null ? 'Sin certificado en este equipo' : 'Instalado: $_certEquipo',
                          style: TextStyle(fontWeight: FontWeight.w600, color: _certEquipo == null ? C.naranja : C.verde)),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final f = await FilePicker.pickFile();
                          if (f == null || !mounted) return;
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
                          await CertificadoEquipo.guardar(await f.readAsBytes(), clave, f.name);
                          if (mounted) setState(() => _certEquipo = f.name);
                        },
                        icon: const Icon(Icons.key_outlined),
                        label: Text(_certEquipo == null ? 'Instalar certificado (.pfx)' : 'Cambiar'),
                      ),
                      if (_certEquipo != null)
                        TextButton(
                          onPressed: () async {
                            await CertificadoEquipo.quitar();
                            if (mounted) setState(() => _certEquipo = null);
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
