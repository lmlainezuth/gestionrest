import 'package:flutter_test/flutter_test.dart';
import 'package:gestionrest/core/nif.dart';

/// Los mismos casos valen para nif_valido (migración 0054) y para la función alta-bar.
void main() {
  test('DNI', () {
    expect(nifValido('12345678Z'), isTrue);
    expect(nifValido(' 12345678z '), isTrue);
    expect(nifValido('12345678A'), isFalse);
    expect(nifValido('00000006Y'), isTrue);
  });

  test('NIE', () {
    expect(nifValido('X1234567L'), isTrue);
    expect(nifValido('X1234567T'), isFalse);
  });

  test('CIF', () {
    expect(nifValido('A58818501'), isTrue);
    expect(nifValido('A58818502'), isFalse);
    // Válido de forma: por eso el alta y el paso a producción lo rechazan aparte
    expect(nifValido(nifDeRelleno), isTrue);
  });

  test('Forma incorrecta', () {
    expect(nifValido(''), isFalse);
    expect(nifValido('1234567Z'), isFalse);
    expect(nifValido('I1234567A'), isFalse);
  });
}
