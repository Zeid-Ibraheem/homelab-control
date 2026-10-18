import 'dart:convert';
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
    // Forme donnée par dartssh2 : le texte « SHA256:… » lui-même.
    final text = 'SHA256:${'A' * 43}';
    expect(fingerprintText(utf8.encode(text)), text);
    expect(fingerprintText(bytesOfHex(hexOf(utf8.encode(text)))), text); // valeur enregistrée relue
    // Octets bruts.
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
  test('allumages programmés en clair', () {
    expect(describeSchedule('Mon..Fri *-*-* 07:45:00'), 'du lundi au vendredi à 07:45');
    expect(describeSchedule('Sat *-*-* 10:00:00'), 'le samedi à 10:00');
    expect(describeSchedule('*-*-* 6:30'), 'tous les jours à 06:30');
    expect(describeSchedule('Mon,Wed,Fri *-*-* 08:00:00'), 'lundi, mercredi et vendredi à 08:00');
    expect(describeSchedule('Sat..Sun *-*-* 11:00'), 'du samedi au dimanche à 11:00');
    expect(describeSchedule('weekly'), 'weekly');
    expect(describeSchedule('Mon *-*-* 07:45:30'), 'Mon *-*-* 07:45:30');
  });

  test('signal Wi-Fi en clair', () {
    expect(wifiText(-48), '-48 dBm (excellent)');
    expect(wifiText(-55), '-55 dBm (excellent)');
    expect(wifiText(-60), '-60 dBm (bon)');
    expect(wifiText(-70), '-70 dBm (moyen)');
    expect(wifiText(-80), '-80 dBm (faible)');
    expect(wifiText(-90), '-90 dBm (très faible)');
  });

  test('états des services', () {
    expect(serviceStateText('active'), 'actif');
    expect(serviceStateText('failed'), 'en échec');
    expect(serviceStateText('maintenance'), 'maintenance');
  });

  test('temps de fonctionnement des disques', () {
    expect(powerOnText(36), '36 h');
    expect(powerOnText(1234), '51 j');
    expect(powerOnText(20000), '2,3 ans');
  });
}
