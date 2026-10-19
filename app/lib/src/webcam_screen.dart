// Webcam : flux vidéo du serveur, par un tunnel SSH vers son port local
// (aucun port vidéo n'est exposé sur le réseau). La réception se fait dans un
// fil séparé (voir webcam_feed.dart) ; cet écran ne fait qu'afficher.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'ssh_link.dart';
import 'webcam_feed.dart';

class WebcamScreen extends StatefulWidget {
  const WebcamScreen({super.key, required this.link, required this.port});

  final SshLink link;

  /// Port du serveur vidéo, sur le serveur lui-même (127.0.0.1).
  final int port;

  @override
  State<WebcamScreen> createState() => _WebcamScreenState();
}

class _WebcamScreenState extends State<WebcamScreen> {
  WebcamFeed? _feed;
  StreamSubscription<Uint8List>? _sub;
  ui.Image? _image;
  String? _error;

  // Images affichées pendant la dernière seconde complète.
  int _fps = 0;
  int _count = 0;
  Timer? _fpsTimer;

  @override
  void initState() {
    super.initState();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _fps = _count;
        _count = 0;
      });
    });
    unawaited(_start());
  }

  @override
  void dispose() {
    _fpsTimer?.cancel();
    _stop();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _stop();
    setState(() => _error = null);
    try {
      final feed = await WebcamFeed.start(widget.link, widget.port);
      if (!mounted) {
        feed.close();
        return;
      }
      _feed = feed;
      _sub = feed.frames.listen(
        (jpeg) => unawaited(_show(feed, jpeg)),
        onError: (Object e) => _fail(errorText(e)),
      );
    } catch (e) {
      _fail(errorText(e));
    }
  }

  // Décode et affiche une image, puis demande la suivante.
  Future<void> _show(WebcamFeed feed, Uint8List jpeg) async {
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted || !identical(feed, _feed)) {
        frame.image.dispose();
        return;
      }
      _count++;
      setState(() {
        _image?.dispose();
        _image = frame.image;
      });
    } catch (_) {
      // image abîmée : on passe à la suivante
    }
    if (mounted && identical(feed, _feed)) feed.next();
  }

  void _fail(String message) {
    _stop();
    if (mounted) setState(() => _error = message);
  }

  void _stop() {
    unawaited(_sub?.cancel());
    _sub = null;
    _feed?.close();
    _feed = null;
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Webcam'),
        actions: [
          if (_error == null && image != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text('$_fps img/s · ${image.width}x${image.height}'),
              ),
            ),
          IconButton(tooltip: 'Relancer', icon: const Icon(Icons.refresh), onPressed: () => unawaited(_start())),
        ],
      ),
      backgroundColor: Colors.black,
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: () => unawaited(_start()), child: const Text('Réessayer')),
                  ],
                ),
              )
            : image == null
                ? const CircularProgressIndicator()
                : RawImage(image: image, fit: BoxFit.contain),
      ),
    );
  }
}
