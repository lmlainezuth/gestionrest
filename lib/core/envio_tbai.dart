/// En web no se puede abrir una conexión con certificado de cliente.
Future<(int, String)> enviarConCertificado(String url, String xml, List<int> p12, String clave) async =>
    throw UnsupportedError('Desde la versión web no se puede enviar a Hacienda: usa el TPV o el PC');
