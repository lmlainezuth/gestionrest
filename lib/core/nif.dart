/// NIF español con su control: DNI (12345678Z), NIE (X1234567L) o CIF (B12345674).
/// Misma regla que el servidor (nif_valido, migración 0054, y supabase/functions/_shared/certificado.ts).
bool nifValido(String nif) {
  final n = nif.trim().toUpperCase();
  const letras = 'TRWAGMYFPDXBNJZSQVHLCKE';
  if (RegExp(r'^\d{8}[A-Z]$').hasMatch(n)) return letras[int.parse(n.substring(0, 8)) % 23] == n[8];
  if (RegExp(r'^[XYZ]\d{7}[A-Z]$').hasMatch(n)) {
    return letras[int.parse('${'XYZ'.indexOf(n[0])}${n.substring(1, 8)}') % 23] == n[8];
  }
  if (RegExp(r'^[ABCDEFGHJNPQRSUVW]\d{7}[0-9A-J]$').hasMatch(n)) {
    var suma = 0;
    for (var i = 1; i <= 7; i++) {
      final d = int.parse(n[i]);
      suma += i.isEven ? d : (d * 2) ~/ 10 + (d * 2) % 10;
    }
    final c = (10 - suma % 10) % 10;
    return n[8] == '$c' || n[8] == 'JABCDEFGHI'[c];
  }
  return false;
}

/// El NIF de relleno con el que nacían los bares de prueba: válido de forma, pero no es de nadie.
const nifDeRelleno = 'B00000000';
