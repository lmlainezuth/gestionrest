import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Android/Windows: si el servidor no contesta en 4 s a la conexión (wifi sin internet),
/// se da por perdida enseguida en vez de esperar al sistema (puede tardar un minuto).
http.Client clienteBase() => IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 4));
