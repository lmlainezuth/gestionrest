import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/conexion.dart';
import '../../core/hora_equipo.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import '../barra/venta_offline.dart';
import 'cadena_equipo.dart';
import 'caducidad_certificados.dart';
import 'facturacion_service.dart';

/// Estado TicketBAI que se avisa en todas las pantallas.
class EstadoTbai {
  final int pendientes; // sin enviar a Hacienda (sin conexión, Hacienda caída…)
  final int rechazadas; // Hacienda las rechazó: hay que revisarlas
  final String entorno; // simulado | pruebas | produccion
  final int locales; // ventas hechas sin internet en este equipo, aún sin subir
  final String? errorLocal; // por qué no se pudieron subir (si no es la falta de conexión)
  final DateTime? localesDesde; // la más antigua de esas ventas
  final int? certDias; // días que le quedan al certificado de este equipo (null: no tiene)
  final Duration? horaDesfase; // hora del equipo − hora del servidor (null: no se sabe)
  const EstadoTbai(this.pendientes, this.rechazadas, this.entorno,
      [this.locales = 0, this.errorLocal, this.localesDesde, this.certDias, this.horaDesfase]);
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

  /// El bar ha pasado a producción y este equipo sigue con su serie de pruebas: pide una nueva él
  /// solo (migración 0054), cuando ya no le queda nada sin subir de la serie anterior.
  static Future<void> _renovarSerieEquipo() async {
    try {
      final serie = await CadenaEquipo.serie();
      if (serie == null || (await VentaOffline.cola()).isNotEmpty) return;
      final fila = await supabase.from('tbai_series').select('entorno').eq('serie', serie).eq('tipo', 'equipo')
          .order('creada_en', ascending: false).limit(1).maybeSingle();
      if (fila == null || fila['entorno'] == 'produccion') return;
      final nueva = await supabase.rpc('tbai_renovar_serie_equipo', params: {'p_anterior': serie}) as String;
      await CadenaEquipo.guardarSerie(nueva);
      await VentaOffline.guardarContexto();
    } catch (_) {
      // Si no se puede, el administrador le asigna una en Ajustes › Empresa, como siempre
    }
  }

  static Future<void> revisar() async {
    if (_enMarcha || supabase.auth.currentSession == null) return;
    if (!Conexion.enLinea.value) {
      // Sin conexión no se intenta nada: solo se cuenta lo guardado en el equipo
      estado.value = await estadoLocal(estado.value.pendientes, estado.value.rechazadas, estado.value.entorno);
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
      if ((await VentaOffline.cola()).isNotEmpty) {
        estado.value = await estadoLocal(estado.value.pendientes, estado.value.rechazadas, estado.value.entorno);
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
      // Cocina no firma ni envía (el servidor se lo niega): solo cuenta lo pendiente
      final envia = Perfil.cache?.rol != Rol.cocinero;
      if (entorno == 'produccion' && envia) await _renovarSerieEquipo();
      for (final f in envia ? pendientes : const <Map<String, dynamic>>[]) {
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
      // Las anulaciones solo las envía un administrador (el servidor se lo niega a los demás)
      final enviaAnulaciones = Perfil.cache?.rol == Rol.admin;
      for (final a in enviaAnulaciones ? anulaciones : const <Map<String, dynamic>>[]) {
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
      estado.value = await estadoLocal(
        (quedan as List).length + (quedanAnul as List).length,
        (rechazadas as List).length + (rechAnul as List).length,
        entorno,
      );
    } catch (_) {
      // Sin conexión con el servidor: se reintenta en la próxima vuelta
      estado.value = await estadoLocal(estado.value.pendientes, estado.value.rechazadas, estado.value.entorno);
    } finally {
      _enMarcha = false;
    }
  }

  /// Estado con lo que solo sabe este equipo: ventas sin subir (y desde cuándo) y certificado.
  static Future<EstadoTbai> estadoLocal(int pendientes, int rechazadas, String entorno) async {
    final c = await VentaOffline.resumenCola();
    return EstadoTbai(pendientes, rechazadas, entorno, c.n, VentaOffline.ultimoError, c.desde,
        await CaducidadCertificados.diasEquipo(), await HoraEquipo.desfase());
  }
}

String _desde(DateTime? d) {
  if (d == null) return '';
  final ahora = DateTime.now();
  String dos(int n) => n.toString().padLeft(2, '0');
  final hora = '${dos(d.hour)}:${dos(d.minute)}';
  final hoy = d.year == ahora.year && d.month == ahora.month && d.day == ahora.day;
  return hoy ? ' desde las $hora' : ' desde el ${dos(d.day)}/${dos(d.month)} a las $hora';
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
        // Sin sesión se sigue avisando de lo guardado en el equipo: no se pierde al cerrar sesión
        EnviosPendientes.estadoLocal(0, 0, 'produccion').then((v) => EnviosPendientes.estado.value = v);
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
          if (e.locales > 0)
            '${e.locales} venta${e.locales == 1 ? '' : 's'} sin subir en este equipo${_desde(e.localesDesde)} '
                '(se suben solas al volver internet): no desinstales la app ni borres sus datos',
          if (HoraEquipo.mal(e.horaDesfase))
            'La hora de este equipo va ${HoraEquipo.texto(e.horaDesfase!)}: corrígela (fecha y hora automáticas)',
          if (e.certDias != null && e.certDias! < 0) 'CERTIFICADO DE ESTE EQUIPO CADUCADO: no puede firmar',
          if (e.certDias != null && e.certDias! >= 0 && e.certDias! <= CaducidadCertificados.diasAviso)
            'El certificado de este equipo caduca en ${e.certDias} día${e.certDias == 1 ? '' : 's'}: avisa al encargado',
          if (e.errorLocal != null) 'No se pudieron subir: ${e.errorLocal}',
          if (e.pendientes > 0) '${e.pendientes} sin enviar a Hacienda (se reintenta solo)',
        ];
        if (textos.isEmpty) return widget.child;
        final grave = e.entorno != 'produccion' || e.rechazadas > 0 || e.errorLocal != null || HoraEquipo.mal(e.horaDesfase) ||
            (e.certDias != null && e.certDias! <= 7) ||
            (e.localesDesde != null && DateTime.now().difference(e.localesDesde!) > const Duration(hours: 12));
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
