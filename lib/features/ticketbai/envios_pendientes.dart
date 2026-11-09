import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/conexion.dart';
import '../../main.dart';
import '../barra/venta_offline.dart';
import 'facturacion_service.dart';

/// Estado TicketBAI que se avisa en todas las pantallas.
class EstadoTbai {
  final int pendientes; // sin enviar a Hacienda (sin conexión, Hacienda caída…)
  final int rechazadas; // Hacienda las rechazó: hay que revisarlas
  final String entorno; // simulado | pruebas | produccion
  final int locales; // ventas hechas sin internet en este equipo, aún sin subir
  final String? errorLocal; // por qué no se pudieron subir (si no es la falta de conexión)
  const EstadoTbai(this.pendientes, this.rechazadas, this.entorno, [this.locales = 0, this.errorLocal]);
  static const vacio = EstadoTbai(0, 0, 'produccion');
}

/// Reenvía solo, cada pocos minutos, los tickets y anulaciones que quedaron sin enviar.
/// La norma exige enviarlos "en cuanto se restablezca la conexión": no depende de que
/// alguien se acuerde de pulsar un botón.
class EnviosPendientes {
  EnviosPendientes._();
  static final estado = ValueNotifier<EstadoTbai>(EstadoTbai.vacio);
  static Timer? _timer;
  static bool _enMarcha = false;

  static void iniciar() {
    _timer ??= Timer.periodic(const Duration(minutes: 2), (_) => revisar());
    // Al volver internet se sube todo en el momento, sin esperar a la siguiente vuelta
    Conexion.enLinea.addListener(() {
      if (Conexion.enLinea.value) revisar();
    });
    revisar();
  }

  static Future<void> revisar() async {
    if (_enMarcha || supabase.auth.currentSession == null) return;
    if (!Conexion.enLinea.value) {
      // Sin conexión no se intenta nada: solo se cuenta lo guardado en el equipo
      final locales = (await VentaOffline.cola()).length;
      estado.value = EstadoTbai(estado.value.pendientes, estado.value.rechazadas, estado.value.entorno, locales,
          VentaOffline.ultimoError);
      return;
    }
    _enMarcha = true;
    try {
      // Antes que nada, subir las ventas hechas sin internet (en orden de su cadena)
      await VentaOffline.sincronizar();
      // Copia de mesas y cuentas abiertas al día por si se va internet
      try {
        await VentaOffline.refrescarCopia();
      } catch (_) {}
      final locales = (await VentaOffline.cola()).length;
      if (locales > 0) {
        estado.value = EstadoTbai(estado.value.pendientes, estado.value.rechazadas, estado.value.entorno, locales,
            VentaOffline.ultimoError);
      }
      final config = await supabase.from('tbai_config').select('entorno').limit(1).maybeSingle();
      final entorno = (config?['entorno'] as String?) ?? 'simulado';
      // De la más antigua a la más reciente (orden de la cadena)
      final pendientes = List<Map<String, dynamic>>.from(await supabase
          .from('facturas')
          .select()
          .eq('estado_envio', 'pendiente')
          .order('fecha')
          .order('creado_en')
          .limit(100));
      final servicio = FacturacionService();
      for (final f in pendientes) {
        try {
          final r = await servicio.reenviar(f);
          // Sigue sin conexión: no insiste con las demás hasta la próxima vuelta
          if (r['estado_envio'] == 'pendiente') break;
        } catch (_) {
          break;
        }
      }
      final anulaciones = List<Map<String, dynamic>>.from(
          await supabase.from('tbai_anulaciones').select().eq('estado_envio', 'pendiente').order('fecha'));
      for (final a in anulaciones) {
        try {
          if ((await servicio.reenviarAnulacion(a))['estado_envio'] == 'pendiente') break;
        } catch (_) {
          break;
        }
      }
      final quedan = await supabase.from('facturas').select('id').eq('estado_envio', 'pendiente');
      final quedanAnul = await supabase.from('tbai_anulaciones').select('id').eq('estado_envio', 'pendiente');
      // Las de antes de la migración 0015 (pruebas ya conocidas) no se avisan
      final rechazadas =
          await supabase.from('facturas').select('id').eq('estado_envio', 'error').eq('legado', false);
      final rechAnul = await supabase
          .from('tbai_anulaciones')
          .select('id, facturas!inner(legado)')
          .eq('estado_envio', 'error')
          .eq('facturas.legado', false);
      estado.value = EstadoTbai(
        (quedan as List).length + (quedanAnul as List).length,
        (rechazadas as List).length + (rechAnul as List).length,
        entorno,
        locales,
        VentaOffline.ultimoError,
      );
    } catch (_) {
      // Sin conexión con el servidor: se reintenta en la próxima vuelta
      final locales = (await VentaOffline.cola()).length;
      estado.value = EstadoTbai(estado.value.pendientes, estado.value.rechazadas, estado.value.entorno, locales,
          VentaOffline.ultimoError);
    } finally {
      _enMarcha = false;
    }
  }
}

/// Franja de aviso arriba de todas las pantallas (va en MaterialApp.builder).
class AvisoTbai extends StatefulWidget {
  const AvisoTbai({super.key, required this.child});
  final Widget child;

  @override
  State<AvisoTbai> createState() => _AvisoTbaiState();
}

class _AvisoTbaiState extends State<AvisoTbai> {
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    EnviosPendientes.iniciar();
    _sub = supabase.auth.onAuthStateChange.listen((e) {
      if (e.session == null) {
        EnviosPendientes.estado.value = EstadoTbai.vacio;
      } else {
        EnviosPendientes.revisar();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: Conexion.enLinea,
      builder: (context, enLinea, _) => ValueListenableBuilder<EstadoTbai>(
      valueListenable: EnviosPendientes.estado,
      builder: (context, e, _) {
        final textos = <String>[
          if (!enLinea) 'SIN INTERNET',
          if (e.entorno == 'simulado') 'MODO SIMULADO: los tickets NO se envían a Hacienda',
          if (e.entorno == 'pruebas') 'ENTORNO DE PRUEBAS: los tickets no tienen validez fiscal',
          if (e.rechazadas > 0) '${e.rechazadas} rechazada${e.rechazadas == 1 ? '' : 's'} por Hacienda: revisa Facturas',
          if (e.locales > 0) '${e.locales} venta${e.locales == 1 ? '' : 's'} sin internet guardada${e.locales == 1 ? '' : 's'} en este equipo (se suben solas)',
          if (e.errorLocal != null) 'No se pudieron subir: ${e.errorLocal}',
          if (e.pendientes > 0) '${e.pendientes} sin enviar a Hacienda (se reintenta solo)',
        ];
        if (textos.isEmpty) return widget.child;
        final grave = e.entorno != 'produccion' || e.rechazadas > 0 || e.errorLocal != null;
        return Column(children: [
          Material(
            color: grave ? const Color(0xFFB3261E) : const Color(0xFFB45309),
            child: SafeArea(
              bottom: false,
              child: InkWell(
                onTap: () async {
                  await Conexion.comprobar();
                  await EnviosPendientes.revisar();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(textos.join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: widget.child)),
        ]);
      },
      ),
    );
  }
}
