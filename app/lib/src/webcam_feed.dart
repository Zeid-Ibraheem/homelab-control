// Flux de la webcam dans un fil d'exécution séparé (un « isolate ») : la
// connexion SSH, le déchiffrement et le découpage des images s'y font, pour
// que l'écran reste fluide. L'écran ne reçoit que des images JPEG complètes,
// une à la fois, quand il a fini d'afficher la précédente : si le téléphone ne
// suit pas, les images en trop sont sautées dans ce fil, sans être copiées.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'mjpeg.dart';
import 'ssh_link.dart';

class WebcamFeed {
  WebcamFeed._(this._isolate, this._receive, this._controller, this._commands);

  final Isolate _isolate;
  final ReceivePort _receive;
  final StreamController<Uint8List> _controller;
  final Future<SendPort> _commands;
  bool _closed = false;

  /// Images JPEG complètes. Une erreur (LinkError) arrête le flux.
  Stream<Uint8List> get frames => _controller.stream;

  /// Lance la connexion vers le serveur vidéo ([webcamPort], sur le serveur
  /// lui-même) à travers un tunnel SSH ouvert par [link].
  static Future<WebcamFeed> start(SshLink link, int webcamPort) async {
    final receive = ReceivePort();
    final controller = StreamController<Uint8List>();
    final commands = Completer<SendPort>();
    final isolate = await Isolate.spawn<List<Object?>>(
      _feedMain,
      <Object?>[receive.sendPort, link.host, link.port, link.user, link.keyPem, link.pinnedHostKey, webcamPort],
      onError: receive.sendPort,
      onExit: receive.sendPort,
      debugName: 'webcam',
    );
    final feed = WebcamFeed._(isolate, receive, controller, commands.future);
    receive.listen((Object? msg) {
      if (msg is SendPort) {
        if (!commands.isCompleted) commands.complete(msg);
      } else if (msg is TransferableTypedData) {
        if (!controller.isClosed) controller.add(msg.materialize().asUint8List());
      } else if (msg is String) {
        if (!controller.isClosed) controller.addError(LinkError(msg));
      } else if (msg is List) {
        // Erreur non rattrapée dans le fil : [message, pile d'appels].
        if (!controller.isClosed) controller.addError(LinkError('Erreur du flux vidéo : ${msg.first}'));
      } else if (msg == null) {
        // Fin du fil.
        feed.close();
      }
    });
    return feed;
  }

  /// L'écran a fini d'afficher l'image précédente : envoyer la suivante.
  void next() {
    if (_closed) return;
    unawaited(_commands.then((port) => port.send('next')));
  }

  /// Arrête tout : le fil est détruit, ce qui ferme aussi sa connexion SSH.
  void close() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _receive.close();
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

// Point d'entrée du fil séparé.
Future<void> _feedMain(List<Object?> args) async {
  final out = args[0]! as SendPort;
  final link = SshLink(
    host: args[1]! as String,
    port: args[2]! as int,
    user: args[3]! as String,
    keyPem: args[4]! as String,
    pinnedHostKey: args[5] as String?,
  );
  final webcamPort = args[6]! as int;

  var wanted = true; // l'écran attend une image
  Uint8List? latest; // image la plus récente pas encore envoyée
  void deliver(Uint8List frame) => out.send(TransferableTypedData.fromList([frame]));

  final commands = ReceivePort();
  out.send(commands.sendPort);
  commands.listen((Object? msg) {
    if (msg != 'next') return;
    final frame = latest;
    if (frame != null) {
      latest = null;
      deliver(frame);
    } else {
      wanted = true;
    }
  });

  try {
    final tunnel = await link.openTunnel(webcamPort);
    final decoder = MjpegDecoder();
    // HTTP/1.0 : réponse envoyée telle quelle, sans découpage en blocs.
    tunnel.send(ascii.encode('GET /stream HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'));
    await for (final chunk in tunnel.stream) {
      for (final frame in decoder.add(chunk)) {
        if (wanted) {
          wanted = false;
          deliver(frame);
        } else {
          latest = frame; // l'ancienne image en attente est sautée
        }
      }
    }
    out.send("Le flux vidéo s'est arrêté.");
  } catch (e) {
    out.send(errorText(e));
  }
  Isolate.exit();
}
