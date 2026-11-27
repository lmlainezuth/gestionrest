import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/nif.dart';
import '../../core/tema.dart';
import 'alta_bar_servicio.dart';

/// Alta de un bar entero desde la app (solo programadores, Ajustes › Programa): datos del bar,
/// certificado del titular, primer administrador con su PIN y, al final, todo de una vez en el
/// servidor (función alta-bar, migración 0054). El bar nace en entorno "pruebas".
class AltaBarPage extends StatefulWidget {
  const AltaBarPage({super.key});

  @override
  State<AltaBarPage> createState() => _AltaBarPageState();
}

class _AltaBarPageState extends State<AltaBarPage> {
  final _formBar = GlobalKey<FormState>();
  final _formAdmin = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _razon = TextEditingController();
  final _nif = TextEditingController();
  final _clave = TextEditingController();
  final _adminNombre = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();

  int _paso = 0;
  bool _ocupado = false;
  CertificadoElegido? _cert;
  String? _certOk; // titular y caducidad, cuando el servidor lo ha dado por bueno
  String? _certAviso;
  String? _error;

  String get _nifLimpio => _nif.text.trim().toUpperCase();

  @override
  void dispose() {
    for (final c in [_nombre, _razon, _nif, _clave, _adminNombre, _pin, _pin2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _elegirCertificado() async {
    try {
      final c = await CertificadoElegido.elegir();
      if (c == null) return;
      setState(() {
        _cert = c;
        _certOk = null;
        _certAviso = null;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = textoAltaBar(e));
    }
  }

  Future<void> _comprobarCertificado() async {
    if (_cert == null) {
      setState(() => _error = 'Elige el fichero del certificado (.p12 o .pfx)');
      return;
    }
    setState(() {
      _ocupado = true;
      _error = null;
    });
    try {
      final r = await llamarAltaBar(
          {'accion': 'comprobar_certificado', 'nif': _nifLimpio, 'p12': _cert!.base64, 'clave': _clave.text});
      setState(() {
        _certOk = '${r['titular']} · caduca el ${r['caduca']}';
        _certAviso = r['aviso'] as String?;
      });
    } catch (e) {
      setState(() => _error = textoAltaBar(e));
    }
    if (mounted) setState(() => _ocupado = false);
  }

  Future<void> _crear() async {
    setState(() {
      _ocupado = true;
      _error = null;
    });
    try {
      final r = await llamarAltaBar({
        'accion': 'crear',
        'nombre': _nombre.text.trim(),
        'razon': _razon.text.trim(),
        'nif': _nifLimpio,
        'p12': _cert!.base64,
        'clave': _clave.text,
        'admin_nombre': _adminNombre.text.trim(),
        'pin': _pin.text,
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Bar dado de alta'),
          content: Text('${_nombre.text.trim()} está en entorno de PRUEBAS.\n\n'
              'Serie de la caja: ${r['serie']}\n'
              'Certificado: ${r['titular']} · caduca el ${r['caduca']}\n\n'
              'Para cobrar en el TPV del bar: entra allí una vez con tu cuenta de programador y elige este bar. '
              'Desde entonces ${_adminNombre.text.trim()} entra con su PIN. La carta la mete el bar '
              '(Ajustes y Carta).'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Entendido'))],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = textoAltaBar(e));
    }
    if (mounted) setState(() => _ocupado = false);
  }

  void _siguiente() {
    setState(() => _error = null);
    switch (_paso) {
      case 0:
        if (!_formBar.currentState!.validate()) return;
      case 1:
        if (_certOk == null) {
          setState(() => _error = 'Comprueba antes el certificado');
          return;
        }
      case 2:
        if (!_formAdmin.currentState!.validate()) return;
      case 3:
        _crear();
        return;
    }
    setState(() => _paso++);
  }

  @override
  Widget build(BuildContext context) {
    final pinFormato = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)];
    return Scaffold(
      appBar: AppBar(title: const Text('Alta de bar')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Stepper(
            currentStep: _paso,
            onStepContinue: _ocupado ? null : _siguiente,
            onStepCancel: _ocupado || _paso == 0 ? null : () => setState(() => _paso--),
            controlsBuilder: (context, d) => Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(children: [
                FilledButton(
                  onPressed: d.onStepContinue,
                  child: Text(_paso == 3 ? (_ocupado ? 'Creando…' : 'Crear el bar') : 'Siguiente'),
                ),
                const SizedBox(width: 8),
                if (_paso > 0) TextButton(onPressed: d.onStepCancel, child: const Text('Atrás')),
              ]),
            ),
            steps: [
              Step(
                title: const Text('Bar'),
                isActive: _paso >= 0,
                state: _paso > 0 ? StepState.complete : StepState.indexed,
                content: Form(
                  key: _formBar,
                  child: Column(children: [
                    TextFormField(
                      controller: _nombre,
                      decoration: const InputDecoration(labelText: 'Nombre comercial', helperText: 'Como se conoce el bar'),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Obligatorio' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _razon,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                          labelText: 'Titular (nombre o razón social)', helperText: 'El que sale en las facturas'),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Obligatorio' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _nif,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'NIF del titular'),
                      onChanged: (_) => setState(() => _certOk = null),
                      validator: (v) {
                        final n = (v ?? '').trim().toUpperCase();
                        if (n == nifDeRelleno) return 'Ese es el NIF de relleno: pon el del titular';
                        return nifValido(n) ? null : 'NIF no válido (revisa la letra o el dígito de control)';
                      },
                    ),
                  ]),
                ),
              ),
              Step(
                title: const Text('Certificado del titular'),
                isActive: _paso >= 1,
                state: _paso > 1 ? StepState.complete : StepState.indexed,
                content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text(
                      'Se guarda cifrado en el servidor. Desde la app no se puede volver a descargar ni ver, '
                      'tampoco tú. Con él firma el servidor y se envía a Hacienda.',
                      style: TextStyle(color: C.gris, fontSize: 13)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    OutlinedButton.icon(
                      onPressed: _ocupado ? null : _elegirCertificado,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Elegir .p12 / .pfx'),
                    ),
                    Text(_cert?.nombre ?? 'Ningún fichero', style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _clave,
                    obscureText: true,
                    onChanged: (_) => setState(() => _certOk = null),
                    decoration: const InputDecoration(labelText: 'Contraseña del certificado'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _ocupado ? null : _comprobarCertificado,
                    icon: const Icon(Icons.verified_user_outlined),
                    label: Text(_ocupado ? 'Comprobando…' : 'Comprobar'),
                  ),
                  if (_certOk != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text('Correcto: $_certOk', style: const TextStyle(color: C.verde, fontWeight: FontWeight.w600)),
                    ),
                  if (_certAviso != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_certAviso!, style: const TextStyle(color: C.naranja)),
                    ),
                ]),
              ),
              Step(
                title: const Text('Primer administrador'),
                isActive: _paso >= 2,
                state: _paso > 2 ? StepState.complete : StepState.indexed,
                content: Form(
                  key: _formAdmin,
                  child: Column(children: [
                    TextFormField(
                      controller: _adminNombre,
                      decoration: const InputDecoration(labelText: 'Nombre', helperText: 'El dueño o encargado del bar'),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Obligatorio' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: pinFormato,
                      decoration: const InputDecoration(labelText: 'PIN de 6 cifras'),
                      validator: (v) => RegExp(r'^\d{6}$').hasMatch(v ?? '') ? null : 'Tienen que ser 6 cifras',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _pin2,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: pinFormato,
                      decoration: const InputDecoration(labelText: 'Repite el PIN'),
                      validator: (v) => v == _pin.text ? null : 'No coincide',
                    ),
                  ]),
                ),
              ),
              Step(
                title: const Text('Crear'),
                isActive: _paso >= 3,
                content: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Bar: ${_nombre.text.trim()}\n'
                    'Titular: ${_razon.text.trim().toUpperCase()} · NIF $_nifLimpio\n'
                    'Certificado: ${_certOk ?? '—'}\n'
                    'Administrador: ${_adminNombre.text.trim()}\n\n'
                    'Se crea en entorno de PRUEBAS (Hacienda lo recibe sin efectos fiscales), con la caja '
                    'principal y su serie. El paso a producción se hace después, en Estado de los bares.',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _error == null
          ? null
          : Container(
              color: const Color(0xFFFBEBEB),
              padding: const EdgeInsets.all(14),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
            ),
    );
  }
}
