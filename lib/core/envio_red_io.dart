import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Envía bytes en crudo a una impresora de red (puerto 9100 normalmente).
Future<void> enviarRed(String ip, int puerto, List<int> bytes) async {
  final s = await Socket.connect(ip, puerto, timeout: const Duration(seconds: 5));
  try {
    s.add(bytes);
    await s.flush();
  } finally {
    await s.close();
  }
}

/// Busca impresoras de red: equipos de la red local con el puerto 9100 abierto.
Future<List<String>> buscarRed({int puerto = 9100}) async {
  final prefijos = <String>{};
  for (final itf in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in itf.addresses) {
      final p = a.address.split('.').map(int.parse).toList();
      final privada = p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] >= 16 && p[1] <= 31);
      if (privada && !a.isLoopback) prefijos.add('${p[0]}.${p[1]}.${p[2]}');
    }
  }
  final encontradas = <String>[];
  for (final pre in prefijos) {
    for (var desde = 1; desde < 255; desde += 64) {
      await Future.wait([
        for (var i = desde; i < desde + 64 && i < 255; i++)
          Socket.connect('$pre.$i', puerto, timeout: const Duration(milliseconds: 600)).then((s) {
            s.destroy();
            encontradas.add('$pre.$i');
          }).catchError((_) {}),
      ]);
    }
  }
  encontradas.sort((a, b) => int.parse(a.split('.').last).compareTo(int.parse(b.split('.').last)));
  return encontradas;
}

// ----- Windows: impresión directa (RAW) a una impresora instalada, sin pasar por PDF -----

final class _DocInfo1 extends Struct {
  external Pointer<Utf16> pDocName;
  external Pointer<Utf16> pOutputFile;
  external Pointer<Utf16> pDatatype;
}

typedef _OpenC = Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>);
typedef _OpenD = int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>);
typedef _StartDocC = Uint32 Function(IntPtr, Uint32, Pointer<_DocInfo1>);
typedef _StartDocD = int Function(int, int, Pointer<_DocInfo1>);
typedef _HandleC = Int32 Function(IntPtr);
typedef _HandleD = int Function(int);
typedef _WriteC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _WriteD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>);

/// Manda los bytes ESC/POS tal cual a una impresora de Windows (así corta el papel y abre el cajón).
Future<void> enviarWindows(String impresora, List<int> bytes) async {
  if (!Platform.isWindows) throw UnsupportedError('La impresión directa a Windows solo funciona en Windows');
  final lib = DynamicLibrary.open('winspool.drv');
  final abrir = lib.lookupFunction<_OpenC, _OpenD>('OpenPrinterW');
  final empezarDoc = lib.lookupFunction<_StartDocC, _StartDocD>('StartDocPrinterW');
  final empezarPag = lib.lookupFunction<_HandleC, _HandleD>('StartPagePrinter');
  final escribir = lib.lookupFunction<_WriteC, _WriteD>('WritePrinter');
  final acabarPag = lib.lookupFunction<_HandleC, _HandleD>('EndPagePrinter');
  final acabarDoc = lib.lookupFunction<_HandleC, _HandleD>('EndDocPrinter');
  final cerrar = lib.lookupFunction<_HandleC, _HandleD>('ClosePrinter');

  final nombre = impresora.toNativeUtf16();
  final h = calloc<IntPtr>();
  final doc = calloc<_DocInfo1>();
  final docNombre = 'GestionRest'.toNativeUtf16();
  final tipo = 'RAW'.toNativeUtf16();
  final datos = calloc<Uint8>(bytes.length);
  final escritos = calloc<Uint32>();
  try {
    if (abrir(nombre, h, nullptr) == 0) throw Exception('No se pudo abrir la impresora "$impresora"');
    final handle = h.value;
    try {
      doc.ref
        ..pDocName = docNombre
        ..pOutputFile = nullptr
        ..pDatatype = tipo;
      if (empezarDoc(handle, 1, doc) == 0) throw Exception('La impresora "$impresora" no acepta el trabajo');
      empezarPag(handle);
      datos.asTypedList(bytes.length).setAll(0, bytes);
      final ok = escribir(handle, datos, bytes.length, escritos);
      acabarPag(handle);
      acabarDoc(handle);
      if (ok == 0 || escritos.value != bytes.length) throw Exception('No se enviaron todos los datos a "$impresora"');
    } finally {
      cerrar(handle);
    }
  } finally {
    calloc.free(nombre);
    calloc.free(h);
    calloc.free(doc);
    calloc.free(docNombre);
    calloc.free(tipo);
    calloc.free(datos);
    calloc.free(escritos);
  }
}
