import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import 'envio_red.dart' if (dart.library.io) 'envio_red_io.dart';

/// Cómo habla cada modelo de impresora: página de caracteres, cajón, corte y QR.
/// Equivale a los "códigos de escape" de otros programas de TPV.
class PerfilImpresora {
  const PerfilImpresora({
    required this.id,
    required this.nombre,
    this.pagina = 1252,
    this.chino = true,
    this.cajon = const [0, 224, 240],
    this.corteTotal = false,
    this.qrNativo = true,
  });

  final String id;
  final String nombre;
  final int pagina; // 1252, 858, 850 o 437
  final bool chino; // mandar FS . para salir del modo chino (TPV chinos)
  final List<int> cajon; // ESC p m t1 t2
  final bool corteTotal; // GS V 0 (total) o GS V B (parcial con avance)
  final bool qrNativo; // false = el QR se manda como imagen (vale para todas)

  static const generico = PerfilImpresora(id: 'generico', nombre: 'Genérica ESC/POS');
  static const lista = [
    generico,
    PerfilImpresora(id: 'wintec', nombre: 'WINTEC (red, 58 mm)', cajon: [0, 25, 250]),
    PerfilImpresora(id: 'pt80km3', nombre: 'PT80KM3 (TPV AIO Android, USB)'),
    PerfilImpresora(id: 'epson', nombre: 'Epson TM-T20 / T88', chino: false, pagina: 858, cajon: [0, 25, 250]),
    PerfilImpresora(id: 'sin_qr', nombre: 'Básica (QR como imagen)', qrNativo: false),
  ];

  static const paginas = {1252: 'WPC1252 (recomendada)', 858: 'PC858 (con €)', 850: 'PC850', 437: 'PC437'};

  /// Número de tabla para ESC t n (estándar Epson)
  int get tablaEscT => switch (pagina) { 1252 => 16, 858 => 19, 850 => 2, _ => 0 };

  static PerfilImpresora porId(String? id) => lista.firstWhere((p) => p.id == id, orElse: () => generico);

  PerfilImpresora copia({int? pagina, bool? chino, List<int>? cajon, bool? corteTotal, bool? qrNativo}) => PerfilImpresora(
        id: id,
        nombre: nombre,
        pagina: pagina ?? this.pagina,
        chino: chino ?? this.chino,
        cajon: cajon ?? this.cajon,
        corteTotal: corteTotal ?? this.corteTotal,
        qrNativo: qrNativo ?? this.qrNativo,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'pagina': pagina, 'chino': chino, 'cajon': cajon, 'corte_total': corteTotal, 'qr_nativo': qrNativo};

  static PerfilImpresora fromJson(Map<String, dynamic>? m) {
    final base = porId(m?['id'] as String?);
    if (m == null) return base;
    return base.copia(
      pagina: (m['pagina'] as num?)?.toInt(),
      chino: m['chino'] as bool?,
      cajon: (m['cajon'] as List?)?.map((e) => (e as num).toInt()).toList(),
      corteTotal: m['corte_total'] as bool?,
      qrNativo: m['qr_nativo'] as bool?,
    );
  }
}

/// Impresora que recibe los bytes ESC/POS directamente (imprime al instante, corta y abre el cajón):
///  - red:   IP + puerto (9100)
///  - usb:   impresora USB interna de un TPV Android (vid/pid; 0 = la primera que encuentre)
///  - serie: puerto /dev/ttyS* de un TPV Android (+ baudios; 0 = los del sistema)
///  - win:   impresora instalada en Windows, en modo directo (RAW) en vez de PDF
class ImpresoraDirecta {
  const ImpresoraDirecta({
    required this.tipo,
    required this.direccion,
    this.numero = 0,
    this.ancho = 80,
    this.perfil = PerfilImpresora.generico,
    this.nombre,
  });

  final String tipo; // red, usb, serie, win
  final String direccion; // IP · vid · /dev/ttyS1 · nombre de la impresora de Windows
  final int numero; // puerto · pid · baudios
  final int ancho; // 58 u 80 mm
  final PerfilImpresora perfil;
  final String? nombre; // nombre en las impresoras de la empresa (Barra, Cocina…)

  int get columnas => ancho == 58 ? 32 : 48;

  static const _canal = MethodChannel('gestionrest/impresora');

  /// Lee lo guardado: JSON (formato nuevo) o "red:IP:puerto:ancho" / "usb:…" / "serie:…" (antiguo).
  static ImpresoraDirecta? desde(String? valor) {
    if (valor == null) return null;
    if (valor.startsWith('{')) {
      try {
        return fromJson(jsonDecode(valor) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    }
    final p = valor.split(':');
    if (!const ['red', 'usb', 'serie'].contains(p.first) || p.length < 2) return null;
    return ImpresoraDirecta(
      tipo: p.first,
      direccion: p[1],
      numero: int.tryParse(p.elementAtOrNull(2) ?? '') ?? (p.first == 'red' ? 9100 : 0),
      ancho: int.tryParse(p.elementAtOrNull(3) ?? '') ?? 80,
    );
  }

  static ImpresoraDirecta fromJson(Map<String, dynamic> m) => ImpresoraDirecta(
        tipo: m['tipo'] as String,
        direccion: '${m['direccion']}',
        numero: (m['numero'] as num?)?.toInt() ?? 0,
        ancho: (m['ancho'] as num?)?.toInt() ?? 80,
        perfil: PerfilImpresora.fromJson((m['perfil'] as Map?)?.cast<String, dynamic>()),
        nombre: m['nombre'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'tipo': tipo,
        'direccion': direccion,
        'numero': numero,
        'ancho': ancho,
        'perfil': perfil.toJson(),
        if (nombre != null) 'nombre': nombre,
      };

  String get valor => jsonEncode(toJson());

  ImpresoraDirecta conNombre(String? n) =>
      ImpresoraDirecta(tipo: tipo, direccion: direccion, numero: numero, ancho: ancho, perfil: perfil, nombre: n);

  String get descripcion {
    final donde = switch (tipo) {
      'usb' => 'USB del TPV${direccion == '0' ? '' : ' · vid $direccion'}',
      'serie' => 'Puerto serie $direccion${numero > 0 ? ' · $numero' : ''}',
      'win' => 'Windows directa · $direccion',
      _ => 'Red · $direccion:$numero',
    };
    return '${nombre != null ? '$nombre · ' : ''}$donde · $ancho mm · ${perfil.nombre}';
  }

  /// Ticket vacío con la configuración de esta impresora.
  EscPos ticket() => EscPos(columnas, perfil: perfil);

  Future<void> enviar(EscPos t) => enviarBytes(t.bytes);

  Future<void> enviarBytes(List<int> bytes) {
    final datos = Uint8List.fromList(bytes);
    return switch (tipo) {
      'usb' => _canal.invokeMethod('usb', {'vid': int.tryParse(direccion) ?? 0, 'pid': numero, 'datos': datos}),
      'serie' => _canal.invokeMethod('serie', {'puerto': direccion, 'baudios': numero, 'datos': datos}),
      'win' => enviarWindows(direccion, datos),
      _ => enviarRed(direccion, numero, datos),
    };
  }

  /// Solo el impulso del cajón (sin imprimir nada).
  Future<void> abrirCajon() => enviar(ticket()..abrirCajon());

  /// Dispositivos USB del TPV (solo Android).
  static Future<List<Map<String, dynamic>>> listarUsb() async {
    final l = await _canal.invokeListMethod<Map>('listarUsb') ?? [];
    return [for (final m in l) Map<String, dynamic>.from(m)];
  }

  /// Puertos serie que la app puede usar (solo Android).
  static Future<List<String>> listarSerie() async => await _canal.invokeListMethod<String>('listarSerie') ?? [];
}

/// Construye un ticket ESC/POS según el perfil de la impresora.
class EscPos {
  EscPos(this.columnas, {this.perfil = PerfilImpresora.generico}) {
    _b.addAll([0x1B, 0x40]); // inicializar
    if (perfil.chino) _b.addAll([0x1C, 0x2E]); // salir del modo chino
    _b.addAll([0x1B, 0x74, perfil.tablaEscT]); // página de caracteres
  }
  final int columnas;
  final PerfilImpresora perfil;
  final _b = <int>[];
  List<int> get bytes => _b;

  static const _cp850 = {
    'á': 0xA0, 'é': 0x82, 'í': 0xA1, 'ó': 0xA2, 'ú': 0xA3, 'ñ': 0xA4, 'Ñ': 0xA5, 'ü': 0x81, 'Ü': 0x9A,
    'Á': 0xB5, 'É': 0x90, 'Í': 0xD6, 'Ó': 0xE0, 'Ú': 0xE9, '¿': 0xA8, '¡': 0xAD, 'º': 0xA7, 'ª': 0xA6,
    'ç': 0x87, 'Ç': 0x80, '·': 0xFA,
  };
  static const _sinTilde = {'Á': 'A', 'É': 'E', 'Í': 'I', 'Ó': 'O', 'Ú': 'U'};

  void _txt(String s) {
    for (final r in s.runes) {
      if (r < 128) {
        _b.add(r);
        continue;
      }
      final c = String.fromCharCode(r);
      switch (perfil.pagina) {
        case 1252:
          _b.add(c == '€' ? 0x80 : (r <= 0xFF ? r : 0x3F));
        case 858:
          _b.add(c == '€' ? 0xD5 : (_cp850[c] ?? 0x3F));
        case 850:
          if (c == '€') {
            _b.addAll('EUR'.codeUnits);
          } else {
            _b.add(_cp850[c] ?? 0x3F);
          }
        default: // 437: sin mayúsculas con tilde ni €
          if (c == '€') {
            _b.addAll('EUR'.codeUnits);
          } else if (_sinTilde[c] != null) {
            _b.addAll(_sinTilde[c]!.codeUnits);
          } else {
            _b.add(c == '·' ? 0xFA : (_cp850[c] ?? 0x3F));
          }
      }
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

  /// QR de 30 a 40 mm: con el comando de la impresora o, si no lo tiene, como imagen.
  void qr(String datos, {int modulo = 6}) {
    alinear(1);
    if (perfil.qrNativo) {
      final d = utf8.encode(datos);
      final n = d.length + 3;
      _b.addAll([0x1D, 0x28, 0x6B, 4, 0, 0x31, 0x41, 0x32, 0]); // modelo 2
      _b.addAll([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x43, modulo]); // tamaño
      _b.addAll([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x45, 0x31]); // corrección M
      _b.addAll([0x1D, 0x28, 0x6B, n & 0xFF, n >> 8, 0x31, 0x50, 0x30, ...d]);
      _b.addAll([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x51, 0x30]); // imprimir
    } else {
      _qrImagen(datos, modulo);
    }
    _b.add(0x0A);
    alinear(0);
  }

  /// QR como imagen de puntos (GS v 0): lo imprime cualquier térmica.
  void _qrImagen(String datos, int modulo) {
    final img = QrImage(QrCode.fromData(data: datos, errorCorrectLevel: QrErrorCorrectLevel.M));
    final n = img.moduleCount;
    final ancho = n * modulo;
    final bytesFila = (ancho + 7) ~/ 8;
    _b.addAll([0x1D, 0x76, 0x30, 0, bytesFila & 0xFF, bytesFila >> 8, ancho & 0xFF, ancho >> 8]);
    for (var y = 0; y < ancho; y++) {
      final fila = List<int>.filled(bytesFila, 0);
      for (var x = 0; x < ancho; x++) {
        if (img.isDark(y ~/ modulo, x ~/ modulo)) fila[x >> 3] |= 0x80 >> (x & 7);
      }
      _b.addAll(fila);
    }
  }

  void abrirCajon() => _b.addAll([0x1B, 0x70, ...perfil.cajon.take(3)]);

  void cortar() {
    // El corte normal (GS V B) ya avanza el papel hasta la cuchilla: sin líneas de más no se
    // desperdicia papel. El corte total (GS V 0) no avanza y las necesita para no cortar el QR.
    if (perfil.corteTotal) saltos(4);
    _b.addAll(perfil.corteTotal ? [0x1D, 0x56, 0x00] : [0x1D, 0x56, 0x42, 0x00]);
  }
}
