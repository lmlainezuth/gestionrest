import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SignedUrlSuccess;

import '../main.dart';

/// Fotos de los productos. El bucket 'productos' es privado (migración 0047): solo las ve quien
/// tiene sesión en el bar, con una dirección firmada que caduca. En productos.imagen_url se guarda
/// la ruta `<empresa>/<fichero>`; las filas antiguas guardaban la dirección pública entera y de ahí
/// se saca la ruta. Cualquier otra dirección (de fuera del bucket) no se muestra.
String? rutaFoto(String? valor) {
  if (valor == null || valor.isEmpty) return null;
  const marca = '/object/public/productos/';
  final i = valor.indexOf(marca);
  if (i >= 0) return Uri.decodeComponent(valor.substring(i + marca.length).split('?').first);
  if (valor.contains('://')) return null;
  return valor;
}

const _vida = Duration(hours: 1);
final _firmadas = <String, ({String url, DateTime caduca})>{};

String? _enCache(String ruta) {
  final c = _firmadas[ruta];
  return c != null && DateTime.now().isBefore(c.caduca) ? c.url : null;
}

void _guardar(String ruta, String url) =>
    _firmadas[ruta] = (url: url, caduca: DateTime.now().add(_vida - const Duration(minutes: 5)));

/// Dirección firmada de una foto (de la caché si aún vale). Null si no hay foto o no se puede.
Future<String?> urlFoto(String? valor) async {
  final ruta = rutaFoto(valor);
  if (ruta == null) return null;
  final hay = _enCache(ruta);
  if (hay != null) return hay;
  try {
    final url = await supabase.storage.from('productos').createSignedUrl(ruta, _vida.inSeconds);
    _guardar(ruta, url);
    return url;
  } catch (_) {
    return null; // sin internet, sin permiso o foto borrada: se queda el hueco
  }
}

/// Firma de una vez las fotos de una lista de productos, para no pedirlas una a una.
Future<void> precargarFotos(Iterable<Map<String, dynamic>> productos) async {
  final rutas = <String>{};
  for (final p in productos) {
    final r = rutaFoto(p['imagen_url'] as String?);
    if (r != null && _enCache(r) == null) rutas.add(r);
  }
  if (rutas.isEmpty) return;
  try {
    final firmadas = await supabase.storage.from('productos').createSignedUrlsResult(rutas.toList(), _vida.inSeconds);
    for (final f in firmadas) {
      if (f is SignedUrlSuccess) _guardar(f.path, f.signedUrl);
    }
  } catch (_) {
    // Cada foto lo intentará luego por su cuenta
  }
}

/// Al cerrar sesión: las direcciones firmadas eran de ese usuario.
void olvidarFotos() => _firmadas.clear();

/// Foto de un producto con la sesión del bar. Mientras carga, o si no hay, muestra [hueco].
class FotoProducto extends StatefulWidget {
  const FotoProducto(this.valor, {super.key, required this.ancho, required this.alto, this.hueco});

  final String? valor; // productos.imagen_url
  final double ancho;
  final double alto;
  final Widget? hueco;

  @override
  State<FotoProducto> createState() => _FotoProductoState();
}

class _FotoProductoState extends State<FotoProducto> {
  late Future<String?> _url = urlFoto(widget.valor);

  @override
  void didUpdateWidget(FotoProducto antes) {
    super.didUpdateWidget(antes);
    if (antes.valor != widget.valor) _url = urlFoto(widget.valor);
  }

  @override
  Widget build(BuildContext context) {
    final hueco = widget.hueco ?? SizedBox(width: widget.ancho, height: widget.alto);
    return FutureBuilder<String?>(
      future: _url,
      builder: (context, s) {
        final url = s.data;
        if (url == null) return hueco;
        return Image.network(url,
            width: widget.ancho, height: widget.alto, fit: BoxFit.cover, errorBuilder: (_, _, _) => hueco);
      },
    );
  }
}
