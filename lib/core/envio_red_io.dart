import 'dart:io';

/// Envía bytes en crudo a una impresora de red (puerto 9100 normalmente).
Future<void> enviarBytes(String ip, int puerto, List<int> bytes) async {
  final s = await Socket.connect(ip, puerto, timeout: const Duration(seconds: 5));
  try {
    s.add(bytes);
    await s.flush();
  } finally {
    await s.close();
  }
}
