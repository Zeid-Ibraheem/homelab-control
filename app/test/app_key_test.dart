import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homelab_control/src/app_key.dart';
import 'package:homelab_control/src/format.dart';

void main() {
  // Vecteur de test n° 1 de la RFC 8032 (Ed25519) : graine publique, connue de
  // tous, et clé publique attendue. Ligne SSH calculée à part avec une autre
  // bibliothèque (Python cryptography).
  final rfcSeed = bytesOfHex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60');
  const rfcLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea homelab-app';

  test('clé publique conforme à la RFC 8032', () {
    expect(AppKey.fromSeed(rfcSeed).publicLine, rfcLine);
  });

  test('clé privée relue par dartssh2', () {
    final key = AppKey.fromSeed(rfcSeed, checkInt: 0x12345678);
    expect(SSHKeyPair.fromPem(key.privatePem), hasLength(1));
  });

  test('format OpenSSH : en-tête, fin, lignes de 70 caractères au plus', () {
    final lines = AppKey.fromSeed(rfcSeed).privatePem.trim().split('\n');
    expect(lines.first, startsWith('-----BEGIN OPENSSH'));
    expect(lines.last, startsWith('-----END OPENSSH'));
    final body = lines.sublist(1, lines.length - 1);
    expect(body.every((l) => l.length <= 70), isTrue);
    final raw = base64.decode(body.join());
    expect(utf8.decode(raw.sublist(0, 14)), 'openssh-key-v1');
    expect(raw[14], 0);
  });

  test('deux clés créées sont différentes', () {
    expect(AppKey.generate().publicLine, isNot(AppKey.generate().publicLine));
  });

  test('clé du terminal : commentaire distinct', () {
    final key = AppKey.fromSeed(rfcSeed, comment: AppKey.terminalComment);
    expect(key.publicLine, endsWith(' homelab-terminal'));
    expect(key.publicLine.split(' ')[1], rfcLine.split(' ')[1]);
    expect(SSHKeyPair.fromPem(key.privatePem), hasLength(1));
  });

  test('commentaire invalide refusé', () {
    expect(() => AppKey.fromSeed(rfcSeed, comment: 'a b'), throwsArgumentError);
  });

  test('graine de mauvaise taille refusée', () {
    expect(() => AppKey.fromSeed(Uint8List(16)), throwsArgumentError);
  });
}
