// Clé SSH Ed25519 de l'application, créée sur le téléphone : la partie privée
// ne quitte jamais le téléphone, seule la partie publique est montrée.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pinenacl/ed25519.dart' as ed;

class AppKey {
  const AppKey._(this.privatePem, this.publicLine);

  /// Clé privée au format OpenSSH (texte), gardée dans le stockage chiffré.
  final String privatePem;

  /// Clé publique sur une ligne (« ssh-ed25519 AAAA… homelab-app »), à
  /// autoriser sur le serveur avec install.sh add-key.
  final String publicLine;

  static const comment = 'homelab-app';

  /// Nouvelle clé, à partir de 32 octets du générateur aléatoire
  /// cryptographique du système.
  factory AppKey.generate() {
    final rnd = Random.secure();
    final seed = Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    return AppKey.fromSeed(seed, checkInt: rnd.nextInt(1 << 32));
  }

  /// Clé construite à partir d'une graine de 32 octets (sert aussi aux tests).
  factory AppKey.fromSeed(Uint8List seed, {int checkInt = 0}) {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'graine de 32 octets attendue');
    }
    final signing = ed.SigningKey(seed: seed);
    final pub = Uint8List.fromList(signing.verifyKey);
    final blob = _publicBlob(pub);
    return AppKey._(
      _openSshPem(blob, seed, pub, checkInt),
      'ssh-ed25519 ${base64.encode(blob)} $comment',
    );
  }

  // Clé publique au format SSH : chaîne « ssh-ed25519 », puis les 32 octets.
  static Uint8List _publicBlob(Uint8List pub) {
    final b = BytesBuilder();
    _putString(b, ascii.encode('ssh-ed25519'));
    _putString(b, pub);
    return b.toBytes();
  }

  // Format « openssh-key-v1 », sans chiffrement (le stockage d'Android chiffre
  // déjà) : même résultat que ssh-keygen -t ed25519 -N "".
  static String _openSshPem(Uint8List blob, Uint8List seed, Uint8List pub, int checkInt) {
    final priv = BytesBuilder()
      ..add(_u32(checkInt))
      ..add(_u32(checkInt));
    _putString(priv, ascii.encode('ssh-ed25519'));
    _putString(priv, pub);
    _putString(priv, [...seed, ...pub]); // 64 octets : graine puis clé publique
    _putString(priv, ascii.encode(comment));
    for (var pad = 1; priv.length % 8 != 0; pad++) {
      priv.addByte(pad);
    }

    final body = BytesBuilder()..add(ascii.encode('openssh-key-v1'))..addByte(0);
    _putString(body, ascii.encode('none')); // pas de chiffrement
    _putString(body, ascii.encode('none')); // pas de dérivation de mot de passe
    _putString(body, const <int>[]);
    body.add(_u32(1)); // une seule clé
    _putString(body, blob);
    _putString(body, priv.toBytes());

    final b64 = base64.encode(body.toBytes());
    final lines = <String>[
      for (var i = 0; i < b64.length; i += 70) b64.substring(i, min(i + 70, b64.length)),
    ];
    // Libellé en deux morceaux : les vérifications avant publication cherchent
    // les en-têtes de clé privée dans le code.
    const label = 'OPENSSH PRIVATE' ' KEY';
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

  static void _putString(BytesBuilder b, List<int> data) {
    b.add(_u32(data.length));
    b.add(data);
  }
}
