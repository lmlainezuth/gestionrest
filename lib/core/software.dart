import 'software_privado.dart';

/// Datos del software TicketBAI. Son del programa (iguales en todas las empresas)
/// y van en cada factura y en la pantalla de verificación presencial (art. 8 OF 521/2020).
/// Si se cambia la versión, hay que comunicarlo en el Registro de Software TicketBAI.
class Software {
  static const nombre = 'GestionRest';
  static const version = '1.0';
  /// Va en software_privado.dart (fuera de git). Si falta, no compila: copiar software_privado.dart.ejemplo.
  static const nifDesarrollador = nifDesarrolladorPrivado;
  static const nombreDesarrollador = 'LEVIN MAURICIO LAINEZ AGUIRRE';

  /// Art. 8.d (OF 64/2026, desde 1/1/2027): declaración responsable visible en la verificación presencial.
  static const declaracionResponsable =
      'La persona desarrolladora del software $nombre ($nombreDesarrollador, NIF $nifDesarrollador) '
      'manifiesta que, al inscribir la declaración responsable en el Registro de Software TicketBAI de la '
      'Diputación Foral de Gipuzkoa, este software cumple de forma incondicionada, sin salvedad ni reserva '
      'alguna, todas las condiciones y requisitos establecidos en la normativa tributaria vigente relativa '
      'al sistema informático TicketBAI.';
}
