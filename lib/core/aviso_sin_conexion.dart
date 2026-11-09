import 'package:flutter/material.dart';

import '../main.dart';
import 'conexion.dart';
import 'tema.dart';

/// Aviso de pantalla que no ha podido cargar (normalmente por falta de internet).
/// Se reintenta solo cuando vuelve la conexión.
class AvisoSinConexion extends StatefulWidget {
  const AvisoSinConexion(this.mensaje, {super.key, required this.onReintentar});
  final String mensaje;
  final VoidCallback onReintentar;

  @override
  State<AvisoSinConexion> createState() => _AvisoSinConexionState();
}

class _AvisoSinConexionState extends State<AvisoSinConexion> {
  @override
  void initState() {
    super.initState();
    Conexion.enLinea.addListener(_vuelve);
  }

  @override
  void dispose() {
    Conexion.enLinea.removeListener(_vuelve);
    super.dispose();
  }

  void _vuelve() {
    if (Conexion.enLinea.value) widget.onReintentar();
  }

  @override
  Widget build(BuildContext context) {
    final sinRed = widget.mensaje.startsWith('Sin internet');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(sinRed ? Icons.wifi_off : Icons.error_outline, size: 40, color: C.gris),
          const SizedBox(height: 12),
          Text(widget.mensaje, textAlign: TextAlign.center),
          if (sinRed)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Para cobrar sin internet usa Barra o Mesas.', style: TextStyle(color: C.gris)),
            ),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: widget.onReintentar, child: const Text('Reintentar')),
        ]),
      ),
    );
  }
}

/// Cerrar sesión. Sin internet avisa antes: no se podría volver a entrar hasta que vuelva.
Future<void> cerrarSesion(BuildContext context) async {
  if (!Conexion.enLinea.value) {
    final si = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sin internet'),
        content: const Text('Si sales ahora no se podrá volver a entrar (ni cobrar) hasta que vuelva la conexión.\n\n'
            '¿Seguro que quieres salir?'),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No, seguir')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salir igualmente')),
        ],
      ),
    );
    if (si != true) return;
  }
  await supabase.auth.signOut();
}
