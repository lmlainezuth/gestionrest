import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/tema.dart';
import '../../main.dart';
import '../../core/empresa_dispositivo.dart';
import 'pin.dart';

/// Entrada: eliges tu nombre y marcas tu PIN. El correo queda como opción.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  List<Map<String, dynamic>> _equipo = [];
  bool _cargando = true;
  Map<String, dynamic>? _elegido;
  String _pin = '';
  bool _entrando = false;
  bool _modoCorreo = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargarEquipo();
  }

  Future<void> _cargarEquipo() async {
    try {
      final empresa = await EmpresaDispositivo.leer();
      _equipo = empresa == null
          ? []
          : List<Map<String, dynamic>>.from(await supabase.rpc('equipo_login', params: {'p_empresa': empresa}));
    } catch (_) {
      _equipo = [];
    }
    if (mounted) setState(() => _cargando = false);
  }

  void _tecla(String t) {
    if (_entrando) return;
    setState(() {
      _error = null;
      if (t == '⌫') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (t != 'OK' && _pin.length < 8) {
        _pin += t;
      }
    });
    if (t == 'OK' && _pin.isNotEmpty) _entrarConPin();
  }

  Future<void> _entrarConPin() async {
    setState(() => _entrando = true);
    final correo = _elegido!['correo'] as String;
    try {
      await supabase.auth.signInWithPassword(email: correo, password: claveDePin(_pin, correo));
    } on AuthException catch (e) {
      setState(() {
        _error = e.message == 'Invalid login credentials' ? 'PIN incorrecto' : e.message;
        _pin = '';
        _entrando = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Sin conexión con el servidor';
        _pin = '';
        _entrando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ancho = MediaQuery.sizeOf(context).width;
    final contenido = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: _cargando
              ? const CircularProgressIndicator()
              : _modoCorreo || _equipo.isEmpty
                  ? _FormularioCorreo(
                      volver: _equipo.isEmpty ? null : () => setState(() => _modoCorreo = false),
                    )
                  : _elegido == null
                      ? _quienEres(ancho)
                      : _tecladoPin(),
        ),
      ),
    );

    return Scaffold(
      body: ancho < 900
          ? contenido
          : Row(
              children: [
                Expanded(flex: 5, child: _PanelMarca()),
                Expanded(flex: 4, child: contenido),
              ],
            ),
    );
  }

  Widget _quienEres(double ancho) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ancho < 900) ...[const _Marca(oscura: false), const SizedBox(height: 32)],
        Text('¿Quién eres?', style: titulo(32)),
        const SizedBox(height: 6),
        const Text('Toca tu nombre y marca tu PIN.', style: TextStyle(color: C.gris)),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final p in _equipo)
              _TarjetaPersona(
                persona: p,
                onTap: () => setState(() {
                  _elegido = p;
                  _pin = '';
                  _error = null;
                }),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _modoCorreo = true),
            child: const Text('Entrar con correo (administración)'),
          ),
        ),
      ],
    );
  }

  Widget _tecladoPin() {
    final nombre = _elegido!['nombre'] as String;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _entrando ? null : () => setState(() => _elegido = null),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Cambiar de persona'),
          ),
        ),
        const SizedBox(height: 8),
        CircleAvatar(
          radius: 36,
          backgroundColor: C.verde,
          child: Text(nombre.isEmpty ? '?' : nombre[0].toUpperCase(), style: titulo(30, color: C.sobreAccion)),
        ),
        const SizedBox(height: 12),
        Text('Hola, $nombre', style: titulo(28)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_pin.isEmpty)
              const Text('Marca tu PIN', style: TextStyle(color: C.gris, fontSize: 16)),
            for (var i = 0; i < _pin.length; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 7),
                width: 18,
                height: 18,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: C.tinta),
              ),
          ],
        ),
        SizedBox(
          height: 36,
          child: Center(
            child: _entrando
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(_error ?? '', style: const TextStyle(color: Color(0xFF8A2E0C), fontWeight: FontWeight.w600)),
          ),
        ),
        SizedBox(
          width: 300,
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.3,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final t in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '⌫', '0', 'OK'])
                t == 'OK'
                    ? FilledButton(
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: _pin.isEmpty || _entrando ? null : () => _tecla('OK'),
                        child: Text('OK', style: titulo(22, color: C.sobreAccion)),
                      )
                    : Material(
                        color: C.blanco,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: C.borde),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _tecla(t),
                          child: Center(
                            child: t == '⌫'
                                ? const Icon(Icons.backspace_outlined, semanticLabel: 'Borrar')
                                : Text(t, style: titulo(28)),
                          ),
                        ),
                      ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TarjetaPersona extends StatelessWidget {
  const _TarjetaPersona({required this.persona, required this.onTap});
  final Map<String, dynamic> persona;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nombre = persona['nombre'] as String;
    final rol = switch (persona['rol']) { 'admin' => 'Administración', 'cocinero' => 'Cocina', _ => 'Sala' };
    final color = switch (persona['rol']) { 'admin' => C.tinta, 'cocinero' => C.naranja, _ => C.verde };
    return Material(
      color: C.blanco,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: C.borde)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          width: 132,
          height: 132,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: color,
                child: Text(nombre.isEmpty ? '?' : nombre[0].toUpperCase(), style: titulo(24, color: C.sobreAccion)),
              ),
              const SizedBox(height: 10),
              Text(nombre, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(rol, style: const TextStyle(fontSize: 12, color: C.gris)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Acceso con correo y contraseña (administración / configuración inicial).
class _FormularioCorreo extends StatefulWidget {
  const _FormularioCorreo({required this.volver});
  final VoidCallback? volver;

  @override
  State<_FormularioCorreo> createState() => _FormularioCorreoState();
}

class _FormularioCorreoState extends State<_FormularioCorreo> {
  final _correo = TextEditingController();
  final _clave = TextEditingController();
  bool _cargando = false;
  String? _error;

  Future<void> _entrar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      await supabase.auth.signInWithPassword(email: _correo.text.trim(), password: _clave.text);
    } on AuthException catch (e) {
      setState(() => _error = e.message == 'Invalid login credentials' ? 'Correo o contraseña incorrectos' : e.message);
    } catch (_) {
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.volver != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: widget.volver, icon: const Icon(Icons.arrow_back), label: const Text('Volver')),
          ),
        Text('Administración', style: titulo(32)),
        const SizedBox(height: 24),
        TextField(
          controller: _correo,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Correo', prefixIcon: Icon(Icons.mail_outline)),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _clave,
          obscureText: true,
          onSubmitted: (_) => _entrar(),
          decoration: const InputDecoration(labelText: 'Contraseña', prefixIcon: Icon(Icons.lock_outline)),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Color(0xFF8A2E0C))),
        ],
        const SizedBox(height: 20),
        FilledButton(onPressed: _cargando ? null : _entrar, child: Text(_cargando ? 'Entrando…' : 'Entrar')),
      ],
    );
  }
}

class _PanelMarca extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        color: C.panel,
        padding: const EdgeInsets.all(56),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Marca(oscura: true),
            const Spacer(),
            Text('Comandas, cocina y caja\nen un solo sistema.', style: titulo(44, color: Colors.white)),
            const SizedBox(height: 20),
            const Text(
              'Del pedido en la mesa a la factura TicketBAI, '
              'sincronizado entre el móvil, la cocina y el TPV.',
              style: TextStyle(color: C.gris, fontSize: 16, height: 1.5),
            ),
          ],
        ),
      );
}

class _Marca extends StatelessWidget {
  const _Marca({required this.oscura});
  final bool oscura;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: C.naranja, borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            child: Text('GR', style: titulo(18)),
          ),
          const SizedBox(width: 12),
          Text('GestiónRest', style: titulo(24, color: oscura ? Colors.white : C.tinta)),
        ],
      );
}
