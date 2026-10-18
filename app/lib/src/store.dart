// Ce que l'application garde sur le téléphone : ses clés et les réglages,
// chiffrés en AES-GCM. La clé de chiffrement est elle-même protégée par une
// clé du Keystore d'Android, gardée par le matériel du téléphone : elle ne
// peut pas en être extraite.
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
    this.termKeyPem,
    this.termPublicLine,
    this.serverUser,
    this.towerUser,
    this.towerAddress,
    this.towerHostKey,
  });

  // ── Clé « actions » et serveur ──
  final String? keyPem;
  final String? publicLine;
  final String? host;
  final int port;
  final String user;

  /// Clé du serveur vérifiée à la première connexion (voir HostKeySeen.pin).
  final String? hostKey;

  // ── Terminal : clé séparée, avec un accès complet ──
  final String? termKeyPem;
  final String? termPublicLine;

  /// Compte de connexion sur le serveur, et sur la tour.
  final String? serverUser;
  final String? towerUser;

  /// Adresse de la tour vue depuis le serveur (câble ou VPN) : le terminal de
  /// la tour passe par le serveur.
  final String? towerAddress;

  /// Clé de la tour vérifiée à la première connexion du terminal.
  final String? towerHostKey;

  bool get hasKey => keyPem != null && publicLine != null;
  bool get ready => hasKey && host != null && hostKey != null;

  bool get hasTermKey => termKeyPem != null && termPublicLine != null;
  bool get serverTerminalReady => ready && hasTermKey && serverUser != null;
  bool get towerTerminalReady => serverTerminalReady && towerUser != null && towerAddress != null;

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
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions());

  static const _keyPem = 'key_pem';
  static const _publicLine = 'public_line';
  static const _host = 'host';
  static const _port = 'port';
  static const _user = 'user';
  static const _hostKey = 'host_key';
  static const _termKeyPem = 'term_key_pem';
  static const _termPublicLine = 'term_public_line';
  static const _serverUser = 'server_user';
  static const _towerUser = 'tower_user';
  static const _towerAddress = 'tower_address';
  static const _towerHostKey = 'tower_host_key';

  static Future<AppData> load() async {
    final all = await _storage.readAll();
    return AppData(
      keyPem: all[_keyPem],
      publicLine: all[_publicLine],
      host: all[_host],
      port: int.tryParse(all[_port] ?? '') ?? 22,
      user: all[_user] ?? 'homelab',
      hostKey: all[_hostKey],
      termKeyPem: all[_termKeyPem],
      termPublicLine: all[_termPublicLine],
      serverUser: all[_serverUser],
      towerUser: all[_towerUser],
      towerAddress: all[_towerAddress],
      towerHostKey: all[_towerHostKey],
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

  static Future<void> saveTermKey({required String pem, required String publicLine}) async {
    await _storage.write(key: _termKeyPem, value: pem);
    await _storage.write(key: _termPublicLine, value: publicLine);
  }

  /// Comptes et adresse du terminal. Changer l'adresse de la tour oublie sa
  /// clé vérifiée : elle sera vérifiée de nouveau à la prochaine connexion.
  static Future<void> saveTerminal({
    required String serverUser,
    required String towerUser,
    required String towerAddress,
    required bool towerAddressChanged,
  }) async {
    await _setOrDelete(_serverUser, serverUser);
    await _setOrDelete(_towerUser, towerUser);
    await _setOrDelete(_towerAddress, towerAddress);
    if (towerAddressChanged) await _storage.delete(key: _towerHostKey);
  }

  static Future<void> saveTowerHostKey(String pin) => _storage.write(key: _towerHostKey, value: pin);

  /// Oublie le serveur (adresse et clé vérifiée), garde les clés de l'application.
  static Future<void> forgetServer() async {
    for (final k in [_host, _port, _user, _hostKey]) {
      await _storage.delete(key: k);
    }
  }

  /// Efface tout, y compris les clés de l'application.
  static Future<void> clear() => _storage.deleteAll();

  static Future<void> _setOrDelete(String key, String value) =>
      value.isEmpty ? _storage.delete(key: key) : _storage.write(key: key, value: value);
}
