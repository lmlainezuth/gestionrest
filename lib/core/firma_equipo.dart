/// En web no hay firma en el equipo: firma el servidor.
class FirmaEquipo {
  static bool get soportada => false;
  static Future<({String der, String titular, DateTime caduca})> certificado(List<int> p12, String clave) =>
      throw UnsupportedError('La versión web no firma en el equipo');
  static Future<List<int>> firmar(List<int> p12, String clave, List<int> datos) =>
      throw UnsupportedError('La versión web no firma en el equipo');
  static void precalentar(List<int> p12, String clave) {}
}
