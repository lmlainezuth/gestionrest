/// En web no hay sockets: la impresión por red no está disponible.
Future<void> enviarBytes(String ip, int puerto, List<int> bytes) async =>
    throw UnsupportedError('La impresión por red no funciona en la versión web');
