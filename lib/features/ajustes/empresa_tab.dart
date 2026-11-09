import 'package:flutter/material.dart';

import '../../core/tema.dart';
import '../../main.dart';
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
                Container(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(color: C.blanco, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.borde)),
                  child: Text('Entorno: ${_tbai!['entorno']}. En modo simulado no se envía nada a Hacienda.',
                      style: const TextStyle(color: C.gris)),
                ),
                campo(_licencia, 'Licencia TicketBAI (la da la Hacienda Foral)', ayuda: 'Opcional en modo simulado'),
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
