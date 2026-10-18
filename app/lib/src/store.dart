// Ce que l'application garde sur le téléphone : sa clé et les réglages du
// serveur, dans le stockage chiffré d'Android (la clé de chiffrement est
// gardée par le Keystore, protégé par le matériel du téléphone, et ne peut
// pas en être extraite).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ssh_link.dart';

class AppData {
  const AppData({
    this.keyPem,
    this.publicLine,
    this.host,
    this.port = 22,
    this.user = 'homelab',
    this.hostKey,
  });

  final String? keyPem;
  final String? publicLine;
  final String? host;
  final int port;
  final String user;

  /// Clé du serveur vérifiée à la première connexion (voir HostKeySeen.pin).
  final String? hostKey;

  bool get hasKey => keyPem != null && publicLine != null;
  bool get ready => hasKey && host != null && hostKey != null;

  /// Commande à lancer sur le serveur pour autoriser la clé de l'application.
  String get addKeyCommand =>
      'sudo ~/homelab-control/server/install.sh add-key "${publicLine ?? ''}"';

  SshLink link() => SshLink(
        host: host!,
        port: port,
        user: user,
        keyPem: keyPem!,
        pinnedHostKey: hostKey,
      );
}

abstract final class Store {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyPem = 'key_pem';
  static const _publicLine = 'public_line';
  static const _host = 'host';
  static const _port = 'port';
  static const _user = 'user';
  static const _hostKey = 'host_key';

  static Future<AppData> load() async {
    final all = await _storage.readAll();
    return AppData(
      keyPem: all[_keyPem],
      publicLine: all[_publicLine],
      host: all[_host],
      port: int.tryParse(all[_port] ?? '') ?? 22,
      user: all[_user] ?? 'homelab',
      hostKey: all[_hostKey],
    );
  }

  static Future<void> saveKey({required String pem, required String publicLine}) async {
    await _storage.write(key: _keyPem, value: pem);
    await _storage.write(key: _publicLine, value: publicLine);
  }

  static Future<void> saveServer({
    required String host,
    required int port,
    required String user,
    required String hostKey,
  }) async {
    await _storage.write(key: _host, value: host);
    await _storage.write(key: _port, value: '$port');
    await _storage.write(key: _user, value: user);
    await _storage.write(key: _hostKey, value: hostKey);
  }

  /// Oublie le serveur (adresse et clé vérifiée), garde la clé de l'application.
  static Future<void> forgetServer() async {
    for (final k in [_host, _port, _user, _hostKey]) {
      await _storage.delete(key: k);
    }
  }

  /// Efface tout, y compris la clé de l'application.
  static Future<void> clear() => _storage.deleteAll();
}
