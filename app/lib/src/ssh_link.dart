// Liaison SSH avec le serveur : une connexion par commande, rien ne reste
// ouvert. La clé du serveur est vérifiée à chaque connexion.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'format.dart';

/// Erreur de connexion, avec un message lisible.
class LinkError implements Exception {
  const LinkError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Message lisible pour n'importe quelle erreur.
String errorText(Object e) {
  if (e is LinkError) return e.message;
  if (e is FormatException) return capitalize(e.message);
  return e.toString();
}

/// Clé du serveur vue pendant une connexion.
class HostKeySeen {
  const HostKeySeen(this.type, this.fingerprint);
  final String type;
  final Uint8List fingerprint;

  /// Valeur enregistrée à la première connexion, puis comparée aux suivantes.
  String get pin => '$type ${hexOf(fingerprint)}';

  /// Empreinte telle que l'affiche ssh-keygen.
  String get display => fingerprintText(fingerprint);

  /// Commande à lancer sur le serveur pour afficher la même empreinte.
  String get checkCommand {
    final file = switch (type) {
      'ssh-ed25519' => 'ssh_host_ed25519_key.pub',
      'ssh-rsa' || 'rsa-sha2-256' || 'rsa-sha2-512' => 'ssh_host_rsa_key.pub',
      _ => 'ssh_host_ecdsa_key.pub',
    };
    final md5 = fingerprint.length == 16 ? ' -E md5' : '';
    return 'ssh-keygen -l$md5 -f /etc/ssh/$file';
  }

  /// Empreinte lisible d'une valeur enregistrée (« type hexadécimal »).
  static String describePin(String pin) {
    final parts = pin.split(' ');
    if (parts.length != 2) return pin;
    return '${parts[0]}  ${fingerprintText(bytesOfHex(parts[1]))}';
  }
}

class SshLink {
  const SshLink({
    required this.host,
    required this.port,
    required this.user,
    required this.keyPem,
    this.pinnedHostKey,
  });

  final String host;
  final int port;
  final String user;
  final String keyPem;

  /// Clé du serveur acceptée (voir [HostKeySeen.pin]) ; sans elle, aucune
  /// commande n'est envoyée.
  final String? pinnedHostKey;

  static const _connectTimeout = Duration(seconds: 6);
  static const _commandTimeout = Duration(seconds: 30);

  /// Première connexion : lit la clé du serveur, puis coupe aussitôt, sans
  /// s'authentifier ni rien envoyer.
  Future<HostKeySeen> probeHostKey() async {
    final socket = await _connect();
    final seen = Completer<HostKeySeen>();
    final client = SSHClient(
      socket,
      username: user,
      onVerifyHostKey: (type, fingerprint) {
        if (!seen.isCompleted) seen.complete(HostKeySeen(type, fingerprint));
        return false;
      },
    );
    // La connexion échoue volontairement : ces erreurs sont attendues.
    client.authenticated.ignore();
    client.done.ignore();
    try {
      return await seen.future.timeout(_connectTimeout);
    } on TimeoutException {
      throw const LinkError('Le serveur ne répond pas.');
    } finally {
      client.close();
    }
  }

  /// Envoie une commande et renvoie la réponse du serveur (texte).
  Future<String> run(String command) async {
    final pinned = pinnedHostKey;
    if (pinned == null) throw const LinkError("Clé du serveur pas encore vérifiée.");
    final List<SSHKeyPair> identities;
    try {
      identities = SSHKeyPair.fromPem(keyPem);
    } catch (_) {
      throw const LinkError("Clé de l'application illisible : recrée-la dans les réglages.");
    }

    final socket = await _connect();
    var wrongHostKey = false;
    final client = SSHClient(
      socket,
      username: user,
      identities: identities,
      onVerifyHostKey: (type, fingerprint) {
        final same = HostKeySeen(type, fingerprint).pin == pinned;
        if (!same) wrongHostKey = true;
        return same;
      },
    );
    client.done.ignore();
    try {
      final out = await client.run(command, stderr: false).timeout(_commandTimeout);
      return utf8.decode(out, allowMalformed: true);
    } on TimeoutException {
      throw const LinkError('Le serveur met trop de temps à répondre.');
    } catch (e) {
      if (wrongHostKey) {
        throw const LinkError(
            "La clé du serveur a changé : connexion refusée. Si le serveur a été "
            "réinstallé, refais la configuration du serveur dans les réglages.");
      }
      if (e.toString().toLowerCase().contains('auth')) {
        throw const LinkError(
            "Clé refusée par le serveur : autorise-la avec la commande add-key affichée par l'application.");
      }
      throw LinkError('Connexion interrompue : $e');
    } finally {
      client.close();
    }
  }

  Future<SSHSocket> _connect() async {
    final address = await _ipv4(host);
    try {
      return await SSHSocket.connect(address, port, timeout: _connectTimeout);
    } on SocketException {
      throw LinkError('Serveur « $host » injoignable : le VPN est-il actif ?');
    } on TimeoutException {
      throw LinkError('Serveur « $host » injoignable : le VPN est-il actif ?');
    }
  }

  /// Adresse IPv4 : le serveur n'accepte la clé que depuis la plage IPv4 du VPN.
  static Future<String> _ipv4(String host) async {
    if (InternetAddress.tryParse(host) != null) return host;
    try {
      final found = await InternetAddress.lookup(host, type: InternetAddressType.IPv4)
          .timeout(_connectTimeout);
      if (found.isNotEmpty) return found.first.address;
    } on SocketException {
      // nom introuvable : message ci-dessous
    } on TimeoutException {
      // pas de réponse du serveur de noms : message ci-dessous
    }
    throw LinkError('Nom « $host » introuvable : le VPN est-il actif ?');
  }
}
