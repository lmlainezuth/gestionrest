import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/tema.dart';
import '../../main.dart';
import 'pin.dart';

/// ¿Tiene que cambiar el PIN? Las cuentas de PIN con menos de 6 cifras (perfiles.pin_seguro =
/// false) no tienen rol en la base hasta cambiarlo (migración 0048). Sin conexión, no se pregunta.
Future<bool> debeCambiarPin() async {
  final uid = supabase.auth.currentUser?.id;
  if (uid == null) return false;
  try {
    final m = await supabase.from('perfiles').select('correo, pin_seguro').eq('id', uid).maybeSingle();
    return m != null && esUsuarioPin(m['correo'] as String?) && m['pin_seguro'] != true;
  } catch (_) {
    return false;
  }
}

/// Pantalla obligatoria al entrar con un PIN corto: hay que poner uno de 6 a 8 cifras.
class CambiarPinPage extends StatefulWidget {
  const CambiarPinPage({super.key});

  @override
  State<CambiarPinPage> createState() => _CambiarPinPageState();
}

class _CambiarPinPageState extends State<CambiarPinPage> {
  final _actual = TextEditingController();
  final _nuevo = TextEditingController();
  final _repetir = TextEditingController();
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _actual.dispose();
    _nuevo.dispose();
    _repetir.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    final nuevo = _nuevo.text.trim();
    if (!RegExp(r'^\d{6,8}$').hasMatch(nuevo)) {
      setState(() => _error = 'El PIN nuevo debe tener entre 6 y 8 cifras');
      return;
    }
    if (nuevo != _repetir.text.trim()) {
      setState(() => _error = 'Los dos PIN nuevos no coinciden');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await supabase.functions.invoke('crear-usuario',
          body: {'accion': 'mi_pin', 'actual': _actual.text.trim(), 'pin': nuevo});
      recargaApp.value++;
    } on FunctionException catch (e) {
      final d = e.details;
      setState(() => _error = d is Map && d['error'] != null ? '${d['error']}' : 'Error ${e.status}');
    } catch (e) {
      setState(() => _error = 'No se pudo cambiar el PIN: $e');
    }
    if (mounted) setState(() => _guardando = false);
  }

  Widget _campo(TextEditingController c, String texto, {bool foco = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          autofocus: foco,
          obscureText: true,
          maxLength: 8,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 10),
          decoration: InputDecoration(labelText: texto, counterText: ''),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Cambia tu PIN', style: titulo(28)),
                const SizedBox(height: 6),
                const Text('Tu PIN es demasiado corto. Para seguir trabajando pon uno de 6 a 8 cifras.',
                    style: TextStyle(color: C.gris)),
                const SizedBox(height: 20),
                _campo(_actual, 'PIN actual', foco: true),
                _campo(_nuevo, 'PIN nuevo (6 a 8 cifras)'),
                _campo(_repetir, 'Repite el PIN nuevo'),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                FilledButton(
                  onPressed: _guardando ? null : _guardar,
                  child: Text(_guardando ? 'Guardando…' : 'Guardar PIN'),
                ),
                TextButton(onPressed: () => supabase.auth.signOut(), child: const Text('Cerrar sesión')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
