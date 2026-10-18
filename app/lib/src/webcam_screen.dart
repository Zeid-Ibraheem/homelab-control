// Webcam : flux vidéo du serveur, par un tunnel SSH vers son port local
// (aucun port vidéo n'est exposé sur le réseau).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'format.dart';
import 'mjpeg.dart';
import 'ssh_link.dart';

class WebcamScreen extends StatefulWidget {
  const WebcamScreen({super.key, required this.link, required this.port});

  final SshLink link;

  /// Port du serveur vidéo, sur le serveur lui-même (127.0.0.1).
  final int port;

  @override
  State<WebcamScreen> createState() => _WebcamScreenState();
}

class _WebcamScreenState extends State<WebcamScreen> {
  SshTunnel? _tunnel;
  StreamSubscription<Uint8List>? _sub;
  ui.Image? _image;
  Uint8List? _pending; // image arrivée pendant le décodage de la précédente
  bool _decoding = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _stop();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _stop();
    setState(() => _error = null);
    try {
      final tunnel = await widget.link.openTunnel(widget.port);
      if (!mounted) {
        tunnel.close();
        return;
      }
      _tunnel = tunnel;
      final decoder = MjpegDecoder();
      // HTTP/1.0 : réponse envoyée telle quelle, sans découpage en blocs.
      tunnel.send(ascii.encode('GET /stream HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'));
      _sub = tunnel.stream.listen(
        (chunk) {
          try {
            for (final frame in decoder.add(chunk)) {
              _show(frame);
            }
          } on FormatException catch (e) {
            _fail(capitalize(e.message));
          }
        },
        onError: (Object e) => _fail(errorText(e)),
        onDone: () => _fail('Le flux vidéo s\'est arrêté.'),
      );
    } catch (e) {
      _fail(errorText(e));
    }
  }

  // Une seule image décodée à la fois ; les plus anciennes sont sautées si le
  // téléphone ne suit pas.
  void _show(Uint8List jpeg) {
    if (_decoding) {
      _pending = jpeg;
      return;
    }
    _decoding = true;
    unawaited(_decode(jpeg));
  }

  Future<void> _decode(Uint8List jpeg) async {
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = frame.image;
      });
    } catch (_) {
      // image abîmée : on attend la suivante
    } finally {
      _decoding = false;
      final next = _pending;
      _pending = null;
      if (next != null && mounted) _show(next);
    }
  }

  void _fail(String message) {
    _stop();
    if (mounted) setState(() => _error = message);
  }

  void _stop() {
    unawaited(_sub?.cancel());
    _sub = null;
    _tunnel?.close();
    _tunnel = null;
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Webcam'),
        actions: [
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
