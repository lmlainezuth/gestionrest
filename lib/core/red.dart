import 'dart:async';

/// ¿El fallo es por falta de conexión (y no un error de datos)?
bool esErrorDeRed(Object e) {
  if (e is TimeoutException) return true;
  final t = '$e';
  return t.contains('SocketException') ||
      t.contains('ClientException') ||
      t.contains('Failed host lookup') ||
      t.contains('Connection refused') ||
      t.contains('Connection reset') ||
      t.contains('Connection closed') ||
      t.contains('Network is unreachable') ||
      t.contains('No address associated') ||
      t.contains('HandshakeException') ||
      t.contains('XMLHttpRequest error') ||
      t.contains('AuthRetryableFetchException');
}

/// Texto para enseñar un error: claro si es falta de conexión.
String textoError(Object? e) => e != null && esErrorDeRed(e)
    ? 'Sin internet: esta pantalla necesita conexión. Se cargará sola cuando vuelva.'
    : 'Error: $e';
