import 'envio_red.dart' if (dart.library.io) 'envio_red_io.dart';

/// Impresora térmica de red con ESC/POS. Se guarda como "red:IP:puerto:ancho".
class ImpresoraRed {
  const ImpresoraRed(this.ip, {this.puerto = 9100, this.ancho = 80});
  final String ip;
  final int puerto;
  final int ancho; // 58 u 80 mm

  int get columnas => ancho == 58 ? 32 : 48;

  static ImpresoraRed? desde(String? valor) {
    if (valor == null || !valor.startsWith('red:')) return null;
    final p = valor.split(':');
    return ImpresoraRed(p[1], puerto: int.tryParse(p.elementAtOrNull(2) ?? '') ?? 9100, ancho: int.tryParse(p.elementAtOrNull(3) ?? '') ?? 80);
  }

  String get valor => 'red:$ip:$puerto:$ancho';

  Future<void> enviar(EscPos t) => enviarBytes(ip, puerto, t.bytes);
}

/// Construye un ticket ESC/POS (página de códigos CP850, para tildes y ñ).
class EscPos {
  EscPos(this.columnas) {
    _b.addAll([0x1B, 0x40, 0x1B, 0x74, 2]); // inicializar + CP850
  }
  final int columnas;
  final _b = <int>[];
  List<int> get bytes => _b;

  static const _cp850 = {
    'á': 0xA0, 'é': 0x82, 'í': 0xA1, 'ó': 0xA2, 'ú': 0xA3, 'ñ': 0xA4, 'Ñ': 0xA5, 'ü': 0x81, 'Ü': 0x9A,
    'Á': 0xB5, 'É': 0x90, 'Í': 0xD6, 'Ó': 0xE0, 'Ú': 0xE9, '¿': 0xA8, '¡': 0xAD, 'º': 0xA7, 'ª': 0xA6,
    'ç': 0x87, 'Ç': 0x80, '·': 0xFA, '€': 0xD5,
  };

  void _txt(String s) {
    for (final r in s.replaceAll('€', 'EUR').runes) {
      final c = String.fromCharCode(r);
      _b.add(r < 128 ? r : (_cp850[c] ?? 0x3F));
    }
  }

  void alinear(int n) => _b.addAll([0x1B, 0x61, n]); // 0 izq, 1 centro, 2 der
  void negrita(bool on) => _b.addAll([0x1B, 0x45, on ? 1 : 0]);
  void tamano(int n) => _b.addAll([0x1D, 0x21, n]); // 0 normal, 0x11 doble, 0x01 doble alto

  void linea(String s, {bool centro = false, bool grande = false, bool fuerte = false}) {
    if (centro) alinear(1);
    if (grande) tamano(0x11);
    if (fuerte) negrita(true);
    _txt(s);
    _b.add(0x0A);
    if (fuerte) negrita(false);
    if (grande) tamano(0);
    if (centro) alinear(0);
  }

  /// Texto a la izquierda e importe a la derecha; si no cabe, el texto pasa de línea.
  void fila(String a, String b, {bool fuerte = false, bool alto = false}) {
    final cols = columnas;
    if (alto) tamano(0x01);
    if (fuerte) negrita(true);
    if (a.length + b.length + 1 > cols) {
      _txt(a.substring(0, a.length.clamp(0, cols)));
      _b.add(0x0A);
      a = '';
    }
    _txt(a.padRight(cols - b.length) + b);
    _b.add(0x0A);
    if (fuerte) negrita(false);
    if (alto) tamano(0);
  }

  void raya() => linea('-' * columnas);
  void saltos(int n) => _b.addAll(List.filled(n, 0x0A));

  void qr(String datos, {int modulo = 6}) {
    final d = datos.codeUnits;
    final n = d.length + 3;
    alinear(1);
    _b.addAll([0x1D, 0x28, 0x6B, 4, 0, 0x31, 0x41, 0x32, 0]); // modelo 2
    _b.addAll([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x43, modulo]); // tamaño
    _b.addAll([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x45, 0x31]); // corrección M
    _b.addAll([0x1D, 0x28, 0x6B, n & 0xFF, n >> 8, 0x31, 0x50, 0x30, ...d]);
    _b.addAll([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x51, 0x30]); // imprimir
    _b.add(0x0A);
    alinear(0);
  }

  void abrirCajon() => _b.addAll([0x1B, 0x70, 0x00, 0x19, 0xFA]);
  void cortar() {
    saltos(4);
    _b.addAll([0x1D, 0x56, 0x42, 0x00]);
  }
}
