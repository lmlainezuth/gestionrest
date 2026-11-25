import 'package:flutter/material.dart';

import '../../core/red.dart';
import '../../core/software.dart';
import '../../core/tema.dart';
import '../../main.dart';

/// Datos del programador y del software: iguales para todos los bares. Solo la ve el programador
/// (tabla programadores, migración 0030). Cuando Hacienda inscriba el software, aquí se pone la
/// licencia definitiva, una sola vez para todos.
class ProgramaTab extends StatefulWidget {
  const ProgramaTab({super.key});

  @override
  State<ProgramaTab> createState() => _ProgramaTabState();
}

class _ProgramaTabState extends State<ProgramaTab> {
  final _form = GlobalKey<FormState>();
  final _nombre = TextEditingController(text: Software.nombreDesarrollador);
  final _nif = TextEditingController(text: Software.nifDesarrollador);
  final _pruebas = TextEditingController(text: Software.licenciaPruebas);
  final _produccion = TextEditingController(text: Software.licenciaProduccion);
  bool _guardando = false;

  Future<void> _guardar() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _guardando = true);
    try {
      await supabase.from('programa').upsert({
        'id': true,
        'nombre_desarrollador': _nombre.text.trim().toUpperCase(),
        'nif_desarrollador': _nif.text.trim().toUpperCase(),
        'licencia_pruebas': _pruebas.text.trim(),
        'licencia_produccion': _produccion.text.trim().isEmpty ? null : _produccion.text.trim(),
        'actualizado_en': DateTime.now().toUtc().toIso8601String(),
      });
      await Software.cargar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Guardado. Vale para todos los bares; cada equipo lo coge al volver a entrar')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(textoError(e))));
    }
    if (mounted) setState(() => _guardando = false);
  }

  @override
  Widget build(BuildContext context) {
    Widget campo(TextEditingController c, String etiqueta, {String? ayuda, String? Function(String?)? validar}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextFormField(
            controller: c,
            validator: validar,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(labelText: etiqueta, helperText: ayuda, helperMaxLines: 3),
          ),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Datos del programador', style: titulo(20)),
              const SizedBox(height: 4),
              const Text(
                'Son del programa, no de cada bar: van en todas las facturas de todos los bares y en la '
                'pantalla de verificación presencial. Solo tú ves esta pestaña.',
                style: TextStyle(color: C.gris, fontSize: 13),
              ),
              const SizedBox(height: 16),
              campo(_nombre, 'Nombre y apellidos del desarrollador',
                  validar: (v) => (v ?? '').trim().isEmpty ? 'Obligatorio' : null),
              campo(_nif, 'NIF del desarrollador',
                  validar: (v) => (v ?? '').trim().length == 9 ? null : 'El NIF tiene 9 caracteres'),
              const SizedBox(height: 8),
              Text('Licencias TicketBAI', style: titulo(20)),
              const SizedBox(height: 12),
              campo(_pruebas, 'Licencia de pruebas',
                  ayuda: 'La que dio Hacienda para el entorno de pruebas',
                  validar: (v) => (v ?? '').trim().isEmpty ? 'Obligatorio' : null),
              campo(_produccion, 'Licencia definitiva (producción)',
                  ayuda: 'La que da Hacienda al inscribir el software. Mientras esté vacía, ningún bar '
                      'puede pasar a producción'),
              Text('Software: ${Software.nombre} ${Software.version}', style: const TextStyle(color: C.gris, fontSize: 13)),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _guardando ? null : _guardar,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(_guardando ? 'Guardando…' : 'Guardar'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
