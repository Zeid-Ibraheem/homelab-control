import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homelab_control/src/format.dart';

void main() {
  test('durées', () {
    expect(duration(-5), '0 s');
    expect(duration(45), '45 s');
    expect(duration(60), '1 min');
    expect(duration(59 * 60), '59 min');
    expect(duration(3600), '1 h');
    expect(duration(5 * 3600 + 7 * 60), '5 h 07');
    expect(duration(24 * 3600), '1 j');
    expect(duration(2 * 86400 + 3 * 3600 + 59), '2 j 3 h');
  });

  test('moments à venir', () {
    final now = DateTime(2026, 3, 27, 22, 0); // veille du passage à l'heure d'été
    expect(when(DateTime(2026, 3, 27, 23, 30), now), '23:30');
    expect(when(DateTime(2026, 3, 28, 8, 5), now), 'demain 08:05');
    expect(when(DateTime(2026, 3, 30, 9, 0), now), 'lun. 09:00');
    expect(when(DateTime(2026, 4, 10, 9, 0), now), '10/04 09:00');
  });

  test('mesures absentes', () {
    expect(pct(null), '—');
    expect(pct(41.6), '42 %');
    expect(temp(null), '—');
    expect(temp(44.0), '44 °C');
  });

  test('empreintes au format de ssh-keygen', () {
    final md5 = Uint8List(16);
    expect(fingerprintText(md5), 'MD5:${List.filled(16, '00').join(':')}');
    final sha = Uint8List(32);
    expect(fingerprintText(sha), 'SHA256:${'A' * 43}');
  });

  test('hexadécimal aller-retour', () {
    final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
    expect(hexOf(bytes), '00017f80ff');
    expect(bytesOfHex('00017f80ff'), bytes);
  });

  test('majuscule initiale', () {
    expect(capitalize('la tour'), 'La tour');
    expect(capitalize(''), '');
  });
}
