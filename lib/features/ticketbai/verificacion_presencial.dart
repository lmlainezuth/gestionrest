import 'package:flutter/material.dart';

import '../../core/software.dart';
import '../../core/tema.dart';
import 'cadena_equipo.dart';

/// Verificación presencial (art. 8 OF 521/2020): en una sola pantalla del equipo,
/// desarrollador, nombre y versión del software, nº de serie del equipo y declaración responsable.
/// Funciona sin internet y sin iniciar sesión.
Future<void> mostrarVerificacionPresencial(BuildContext context) async {
  final serie = await CadenaEquipo.serie();
  if (!context.mounted) return;
  Widget fila(String etiqueta, String valor) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(etiqueta, style: const TextStyle(color: C.gris, fontSize: 13)),
          SelectableText(valor, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        ]),
      );
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('TicketBAI · Verificación presencial'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            fila('Persona desarrolladora', '${Software.nombreDesarrollador}\nNIF ${Software.nifDesarrollador}'),
            fila('Software', Software.nombre),
            fila('Versión', Software.version),
            if (serie != null && serie.isNotEmpty) fila('Nº de serie del dispositivo (serie de facturas)', serie),
            const SizedBox(height: 6),
            Text('Declaración responsable', style: titulo(16)),
            const SizedBox(height: 6),
            SelectableText(Software.declaracionResponsable, style: const TextStyle(fontSize: 14, height: 1.4)),
          ]),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
    ),
  );
}

/// Botón pequeño para la pantalla de entrada y los ajustes.
class BotonVerificacionTbai extends StatelessWidget {
  const BotonVerificacionTbai({super.key});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => mostrarVerificacionPresencial(context),
        icon: const Icon(Icons.verified_outlined, size: 18),
        label: const Text('TicketBAI · datos del software'),
      );
}
