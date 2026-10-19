// Liaisons SSH : une connexion par commande (rien ne reste ouvert), un tunnel
// pour la webcam, et les briques du terminal. La clé de chaque machine est
// vérifiée à chaque connexion.
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

/// Machine au bout de la connexion, pour les messages.
enum Peer {
  server('du serveur', 'le serveur'),
  tower('de la tour', 'la tour');

  const Peer(this.of, this.subject);

  /// « la clé du serveur », « la clé de la tour »
  final String of;

  /// « refusée par le serveur », « refusée par la tour »
  final String subject;
}

/// Ce qu'il faut faire quand une clé de l'application est refusée.
const actionsKeyHint = "autorise-la avec la commande add-key affichée par l'application";
const terminalKeyHint = "ajoute la clé du terminal à ~/.ssh/authorized_keys de ce compte (voir les réglages)";

const _connectTimeout = Duration(seconds: 6);
const _authTimeout = Duration(seconds: 15);
const _commandTimeout = Duration(seconds: 30);

/// Clé d'une machine vue pendant une connexion.
class HostKeySeen {
  const HostKeySeen(this.type, this.fingerprint);
  final String type;
  final Uint8List fingerprint;

  /// Valeur enregistrée à la première connexion, puis comparée aux suivantes.
  String get pin => '$type ${hexOf(fingerprint)}';

  /// Empreinte telle que l'affiche ssh-keygen.
  String get display => fingerprintText(fingerprint);

  /// Commande à lancer sur la machine pour afficher la même empreinte.
  String get checkCommand {
    final file = switch (type) {
      'ssh-ed25519' => 'ssh_host_ed25519_key.pub',
      'ssh-rsa' || 'rsa-sha2-256' || 'rsa-sha2-512' => 'ssh_host_rsa_key.pub',
      _ => 'ssh_host_ecdsa_key.pub',
    };
    final md5 = display.startsWith('MD5:') ? ' -E md5' : '';
    return 'ssh-keygen -l$md5 -f /etc/ssh/$file';
  }

  /// Empreinte lisible d'une valeur enregistrée (« type hexadécimal »).
  static String describePin(String pin) {
    final parts = pin.split(' ');
    if (parts.length != 2) return pin;
    return '${parts[0]}  ${fingerprintText(bytesOfHex(parts[1]))}';
  }
}

/// Erreur lisible, selon la machine et la clé utilisée.
LinkError explainError(
  Object e, {
  bool wrongHostKey = false,
  Peer peer = Peer.server,
  String keyHint = actionsKeyHint,
}) {
  if (e is LinkError) return e;
  if (wrongHostKey) {
    return LinkError("La clé ${peer.of} a changé : connexion refusée. Si la machine a été "
        "réinstallée, fais-la vérifier de nouveau (Réglages).");
  }
  if (e is TimeoutException) return LinkError('${capitalize(peer.subject)} met trop de temps à répondre.');
  if (e is SocketException || e is SSHSocketError) return LinkError('${capitalize(peer.subject)} est injoignable.');
  if (e is SSHAuthFailError) return LinkError('Clé refusée par ${peer.subject} : $keyHint.');
  if (e is SSHAuthAbortError) {
    final reason = e.reason;
    if (reason is SSHDisconnectError) {
      return LinkError('Connexion fermée par ${peer.subject} : ${reason.message}');
    }
    return LinkError("Connexion interrompue avant la fin de l'authentification (${peer.subject}).");
  }
  return LinkError('Connexion interrompue : $e');
}

/// Adresses de la tour vues du serveur : une ou deux (le câble, puis le VPN),
/// séparées par des espaces ou des virgules. Null si la saisie est invalide.
List<String>? parseAddresses(String text, {int max = 2}) {
  final parts = [for (final p in text.split(RegExp(r'[\s,]+'))) if (p.isNotEmpty) p];
  if (parts.isEmpty || parts.length > max) return null;
  final valid = RegExp(r'^[A-Za-z0-9.:-]{1,253}$');
  return parts.every(valid.hasMatch) ? parts : null;
}

/// Lit une clé privée OpenSSH gardée par l'application.
List<SSHKeyPair> parseIdentities(String pem) {
  try {
    return SSHKeyPair.fromPem(pem);
  } catch (_) {
    throw const LinkError("Clé de l'application illisible : recrée-la dans les réglages.");
  }
}

/// Connexion TCP vers une machine, en IPv4 : les clés ne sont acceptées que
/// depuis la plage IPv4 du VPN.
Future<SSHSocket> connectTcp(String host, int port) async {
  final address = await _ipv4(host);
  try {
    return await SSHSocket.connect(address, port, timeout: _connectTimeout);
  } on SocketException {
    throw LinkError('Serveur « $host » injoignable : le VPN est-il actif ?');
  } on TimeoutException {
    throw LinkError('Serveur « $host » injoignable : le VPN est-il actif ?');
  }
}

Future<String> _ipv4(String host) async {
  if (InternetAddress.tryParse(host) != null) return host;
  try {
    final found = await InternetAddress.lookup(host, type: InternetAddressType.IPv4).timeout(_connectTimeout);
    if (found.isNotEmpty) return found.first.address;
  } on SocketException {
    // nom introuvable : message ci-dessous
  } on TimeoutException {
    // pas de réponse du serveur de noms : message ci-dessous
  }
  throw LinkError('Nom « $host » introuvable : le VPN est-il actif ?');
}

/// Première connexion à une machine : lit sa clé, puis coupe aussitôt, sans
/// s'authentifier ni rien envoyer.
Future<HostKeySeen> probeHostKeyOn(SSHSocket socket, {required String user}) async {
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
    throw const LinkError('La machine ne répond pas.');
  } finally {
    client.close().ignore();
  }
}

/// Client SSH authentifié par [identities], si la machine présente la clé
/// enregistrée [pinned] ; sinon, rien n'est envoyé.
Future<SSHClient> authenticate(
  SSHSocket socket, {
  required String user,
  required List<SSHKeyPair> identities,
  required String pinned,
  required Peer peer,
  required String keyHint,
}) async {
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
    await client.authenticated.timeout(_authTimeout);
    return client;
  } catch (e) {
    client.close().ignore();
    throw explainError(e, wrongHostKey: wrongHostKey, peer: peer, keyHint: keyHint);
  }
}

/// Liaison avec le compte « homelab » du serveur, par la clé « actions ».
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

  /// Première connexion : lit la clé du serveur, sans rien envoyer.
  Future<HostKeySeen> probeHostKey() async => probeHostKeyOn(await connectTcp(host, port), user: user);

  Future<SSHClient> _client() async {
    final pinned = pinnedHostKey;
    if (pinned == null) throw const LinkError('Clé du serveur pas encore vérifiée.');
    final identities = parseIdentities(keyPem);
    return authenticate(
      await connectTcp(host, port),
      user: user,
      identities: identities,
      pinned: pinned,
      peer: Peer.server,
      keyHint: actionsKeyHint,
    );
  }

  /// Envoie une commande et renvoie la réponse du serveur (texte). [timeout] :
  /// attente maximale de la réponse (plus longue pour un redémarrage de service).
  Future<String> run(String command, {Duration timeout = _commandTimeout}) async {
    final client = await _client();
    try {
      final out = await client.run(command, stderr: false).timeout(timeout);
      return utf8.decode(out, allowMalformed: true);
    } on TimeoutException {
      throw const LinkError('Le serveur met trop de temps à répondre.');
    } catch (e) {
      throw explainError(e);
    } finally {
      client.close().ignore();
    }
  }

  /// Tunnel vers un port local du serveur (la webcam), seul tunnel autorisé
  /// pour cette clé.
  Future<SshTunnel> openTunnel(int port) async {
    final client = await _client();
    try {
      final SSHSocket channel = await client.forwardLocal('127.0.0.1', port).timeout(_authTimeout);
      return SshTunnel._(client, channel);
    } catch (e) {
      client.close().ignore();
      if (e is TimeoutException) throw const LinkError('Le serveur met trop de temps à ouvrir le tunnel.');
      throw LinkError('Webcam injoignable sur le port $port du serveur : serveur vidéo arrêté '
          '(sur le serveur : systemctl status homelab-webcam), ou WEBCAM_PORT changé sans relancer '
          'install.sh ($e)');
    }
  }
}

/// Tunnel SSH ouvert : octets reçus, envoi, fermeture.
class SshTunnel {
  SshTunnel._(this._client, this._channel);
  final SSHClient _client;
  final SSHSocket _channel;

  Stream<Uint8List> get stream => _channel.stream;

  void send(List<int> data) => _channel.sink.add(data);

  void close() {
    _channel.destroy();
    _client.close().ignore();
  }
}
