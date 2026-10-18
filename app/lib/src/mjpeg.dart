// Découpe un flux vidéo MJPEG (réponse HTTP « multipart/x-mixed-replace »,
// celle d'ustreamer) en images JPEG, au fil des octets reçus par le tunnel.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

enum _Step { httpHeaders, partHeaders, body, scan }

class MjpegDecoder {
  MjpegDecoder({this.maxFrameBytes = 8 * 1024 * 1024});

  /// Taille maximale d'une image : au-delà, le flux est refusé (protection de
  /// la mémoire du téléphone).
  final int maxFrameBytes;

  Uint8List _buf = Uint8List(64 * 1024);
  int _start = 0; // premier octet pas encore traité
  int _end = 0; // fin des octets reçus
  _Step _step = _Step.httpHeaders;
  int _need = 0; // octets de l'image en cours (Content-Length)

  static const _crlf2 = [13, 10, 13, 10];
  static const _soi = [0xFF, 0xD8]; // début d'une image JPEG
  static const _eoi = [0xFF, 0xD9]; // fin d'une image JPEG
  static final _length = RegExp(r'content-length:\s*(\d{1,9})', caseSensitive: false);

  /// Ajoute des octets reçus ; renvoie les images complètes trouvées. Lève
  /// FormatException si la réponse n'est pas un flux d'images.
  List<Uint8List> add(List<int> chunk) {
    _append(chunk);
    final frames = <Uint8List>[];
    while (true) {
      switch (_step) {
        case _Step.httpHeaders:
          final i = _find(_crlf2, _start);
          if (i < 0) return _wait(frames);
          final head = latin1.decode(_buf.sublist(_start, i));
          final status = head.split('\r\n').first;
          if (!RegExp(r'^HTTP/1\.[01] 200').hasMatch(status)) {
            throw FormatException('réponse du serveur vidéo : $status');
          }
          if (!head.toLowerCase().contains('multipart/x-mixed-replace')) {
            throw const FormatException("le serveur vidéo n'envoie pas un flux d'images (chemin /stream ?)");
          }
          _start = i + 4;
          _step = _Step.partHeaders;
        case _Step.partHeaders:
          final i = _find(_crlf2, _start);
          if (i < 0) return _wait(frames);
          final m = _length.firstMatch(latin1.decode(_buf.sublist(_start, i)));
          _start = i + 4;
          if (m == null) {
            _step = _Step.scan;
          } else {
            _need = int.parse(m.group(1)!);
            if (_need > maxFrameBytes) throw const FormatException('image trop grande dans le flux vidéo');
            _step = _Step.body;
          }
        case _Step.body:
          if (_end - _start < _need) return frames;
          frames.add(_buf.sublist(_start, _start + _need));
          _start += _need;
          _step = _Step.partHeaders;
        case _Step.scan:
          // Partie sans Content-Length : l'image va du marqueur de début au
          // marqueur de fin.
          final soi = _find(_soi, _start);
          if (soi < 0) return _wait(frames);
          final eoi = _find(_eoi, soi + 2);
          if (eoi < 0) return _wait(frames);
          frames.add(_buf.sublist(soi, eoi + 2));
          _start = eoi + 2;
          _step = _Step.partHeaders;
      }
    }
  }

  // En attente de la suite ; refuse un flux qui grossit sans fin.
  List<Uint8List> _wait(List<Uint8List> frames) {
    if (_end - _start > maxFrameBytes + 65536) {
      throw const FormatException('flux vidéo illisible (séparateur introuvable)');
    }
    return frames;
  }

  void _append(List<int> chunk) {
    final len = _end - _start;
    final needed = len + chunk.length;
    if (needed > _buf.length) {
      final bigger = Uint8List(math.max(needed, _buf.length * 2));
      bigger.setRange(0, len, _buf, _start);
      _buf = bigger;
      _start = 0;
      _end = len;
    } else if (_end + chunk.length > _buf.length) {
      _buf.setRange(0, len, _buf, _start);
      _start = 0;
      _end = len;
    }
    _buf.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  int _find(List<int> pattern, int from) {
    final last = _end - pattern.length;
    outer:
    for (var i = from; i <= last; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (_buf[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
