/// En web no hay sockets ni acceso a impresoras: la impresión directa no está disponible.
Future<void> enviarRed(String ip, int puerto, List<int> bytes) async =>
    throw UnsupportedError('La impresión por red no funciona en la versión web');

Future<List<String>> buscarRed({int puerto = 9100}) async => [];

Future<void> enviarWindows(String impresora, List<int> bytes) async =>
    throw UnsupportedError('La impresión directa solo funciona en la app de Windows');
