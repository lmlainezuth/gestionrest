import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/tema.dart';
import '../../main.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _correo = TextEditingController();
  final _clave = TextEditingController();
  bool _cargando = false;
  bool _verClave = false;
  String? _error;

  Future<void> _entrar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      await supabase.auth.signInWithPassword(
        email: _correo.text.trim(),
        password: _clave.text,
      );
    } on AuthException catch (e) {
      setState(() => _error = e.message == 'Invalid login credentials'
          ? 'Correo o contraseña incorrectos'
          : e.message);
    } catch (e) {
      setState(() => _error = 'Sin conexión con el servidor');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  void dispose() {
    _correo.dispose();
    _clave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ancho = MediaQuery.sizeOf(context).width;
    final formulario = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (ancho < 900) ...[
                const _Marca(oscura: false),
                const SizedBox(height: 40),
              ],
              Text('Inicia sesión', style: titulo(32)),
              const SizedBox(height: 6),
              const Text('Entra con el usuario que te dio el administrador.',
                  style: TextStyle(color: C.gris)),
              const SizedBox(height: 32),
              TextField(
                controller: _correo,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Correo',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _clave,
                obscureText: !_verClave,
                onSubmitted: (_) => _entrar(),
                decoration: InputDecoration(
                  labelText: 'Contraseña',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    tooltip: _verClave ? 'Ocultar' : 'Mostrar',
                    icon: Icon(_verClave ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _verClave = !_verClave),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFBE4DA),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFF8A2E0C))),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _cargando ? null : _entrar,
                child: _cargando
                    ? const SizedBox(
                        height: 22, width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : const Text('Entrar'),
              ),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      body: ancho < 900
          ? formulario
          : Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Container(
                    color: C.tinta,
                    padding: const EdgeInsets.all(56),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Marca(oscura: true),
                        const Spacer(),
                        Text('Comandas, cocina y caja\nen un solo sistema.',
                            style: titulo(44, color: Colors.white)),
                        const SizedBox(height: 20),
                        const Text(
                          'Del pedido en la mesa a la factura TicketBAI, '
                          'sincronizado entre el móvil, la cocina y el TPV.',
                          style: TextStyle(color: Color(0xFFB5B0A5), fontSize: 16, height: 1.5),
                        ),
                        const SizedBox(height: 40),
                        const Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _Etiqueta('Mesas y comandas'),
                            _Etiqueta('Pantalla de cocina'),
                            _Etiqueta('TPV y caja'),
                            _Etiqueta('TicketBAI'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(flex: 4, child: formulario),
              ],
            ),
    );
  }
}

class _Marca extends StatelessWidget {
  const _Marca({required this.oscura});
  final bool oscura;

  @override
  Widget build(BuildContext context) {
    final color = oscura ? Colors.white : C.tinta;
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: C.naranja, borderRadius: BorderRadius.circular(12)),
          alignment: Alignment.center,
          child: Text('GR', style: titulo(18, color: C.tinta)),
        ),
        const SizedBox(width: 12),
        Text('GestiónRest', style: titulo(24, color: color)),
      ],
    );
  }
}

class _Etiqueta extends StatelessWidget {
  const _Etiqueta(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF3A3934)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(texto, style: const TextStyle(color: Color(0xFFF3F1EC), fontWeight: FontWeight.w600)),
      );
}
