// Terminal : session SSH interactive vers le serveur, ou vers la tour en
// passant par le serveur (le téléphone ne parle toujours qu'au serveur).
// Clé du terminal : séparée de la clé « actions », avec un accès complet.
import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_link.dart';
import 'store.dart';

class RemoteShell {
  RemoteShell._(this._clients, this._session) {
    var open = 2;
    void finished() {
      open--;
      if (open == 0) unawaited(_out.close());
    }

    for (final s in [_session.stdout, _session.stderr]) {
      _subs.add(s
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_out.add, onDone: finished, onError: (Object _) => finished()));
    }
  }

  final List<SSHClient> _clients;
  final SSHSession _session;
  final _out = StreamController<String>();
  final _subs = <StreamSubscription<String>>[];

  /// Texte reçu (sortie normale et erreurs) ; se ferme à la fin de la session.
  Stream<String> get output => _out.stream;

  /// Ouvre la session. Pour la tour, sa clé est vérifiée par [confirmTowerKey]
  /// à la première connexion, puis enregistrée.
  static Future<RemoteShell> open(
    AppData data, {
    required bool toTower,
    required Future<bool> Function(HostKeySeen seen) confirmTowerKey,
    required int width,
    required int height,
  }) async {
    if (!(toTower ? data.towerTerminalReady : data.serverTerminalReady)) {
      throw const LinkError('Terminal pas encore configuré : voir les réglages.');
    }
    final identities = parseIdentities(data.termKeyPem!);
    final clients = <SSHClient>[];
    try {
      final server = await authenticate(
        await connectTcp(data.host!, data.port),
        user: data.serverUser!,
        identities: identities,
        pinned: data.hostKey!,
        peer: Peer.server,
        keyHint: terminalKeyHint,
      );
      clients.add(server);
      var target = server;
      if (toTower) {
        final address = data.towerAddress!;
        var pin = data.towerHostKey;
        if (pin == null) {
          final seen = await probeHostKeyOn(await _forward(server, address), user: data.towerUser!);
          if (!await confirmTowerKey(seen)) {
            throw const LinkError('Clé de la tour non vérifiée : connexion annulée.');
          }
          await Store.saveTowerHostKey(seen.pin);
          pin = seen.pin;
        }
        final tower = await authenticate(
          await _forward(server, address),
          user: data.towerUser!,
          identities: identities,
          pinned: pin,
          peer: Peer.tower,
          keyHint: terminalKeyHint,
        );
        clients.add(tower);
        target = tower;
      }
      final session = await target.shell(pty: SSHPtyConfig(width: width, height: height));
      return RemoteShell._(clients, session);
    } catch (e) {
      for (final c in clients.reversed) {
        c.close().ignore();
      }
      throw explainError(e, keyHint: terminalKeyHint);
    }
  }

  // Canal vers le port SSH de la tour, ouvert depuis le serveur.
  static Future<SSHSocket> _forward(SSHClient server, String address) async {
    try {
      return await server.forwardLocal(address, 22).timeout(const Duration(seconds: 15));
    } catch (e) {
      throw LinkError('Le serveur ne joint pas la tour à l\'adresse « $address » : est-elle allumée ? ($e)');
    }
  }

  void write(String text) => _session.write(utf8.encode(text));

  void resize(int width, int height) => _session.resizeTerminal(width, height);

  void close() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _session.close();
    for (final c in _clients.reversed) {
      c.close().ignore();
    }
    if (!_out.isClosed) unawaited(_out.close());
  }
}
