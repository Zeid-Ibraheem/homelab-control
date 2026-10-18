import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homelab_control/src/mjpeg.dart';

// Fausse image JPEG : marqueurs de début et de fin, remplissage sans 0xFF.
Uint8List jpeg(int fill, int size) => Uint8List.fromList([0xFF, 0xD8, ...List.filled(size, fill), 0xFF, 0xD9]);

// Réponse HTTP au format d'ustreamer : parties avec Content-Length, plus une
// partie sans (découpée d'après les marqueurs JPEG).
Uint8List stream(List<Uint8List> frames, {bool lastWithoutLength = false}) {
  final b = BytesBuilder()
    ..add(ascii.encode('HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace;boundary=boundarydonotcross\r\n\r\n'));
  for (var i = 0; i < frames.length; i++) {
    final noLength = lastWithoutLength && i == frames.length - 1;
    b.add(ascii.encode('--boundarydonotcross\r\nContent-Type: image/jpeg\r\n'
        '${noLength ? '' : 'Content-Length: ${frames[i].length}\r\n'}X-Timestamp: 12.5\r\n\r\n'));
    b.add(frames[i]);
    b.add(ascii.encode('\r\n'));
  }
  return b.toBytes();
}

List<Uint8List> feed(Uint8List data, int chunk, {MjpegDecoder? decoder}) {
  final d = decoder ?? MjpegDecoder();
  final out = <Uint8List>[];
  for (var i = 0; i < data.length; i += chunk) {
    out.addAll(d.add(data.sublist(i, i + chunk > data.length ? data.length : i + chunk)));
  }
  return out;
}

void main() {
  final frames = [jpeg(1, 300), jpeg(2, 5000), jpeg(3, 70000), jpeg(4, 10)];

  for (final chunk in [1, 3, 7, 1000, 1 << 20]) {
    test('images retrouvées, morceaux de $chunk octets', () {
      final got = feed(stream(frames, lastWithoutLength: true), chunk);
      expect(got, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(got[i], frames[i]);
      }
    });
  }

  test('réponse 404 refusée', () {
    expect(() => MjpegDecoder().add(ascii.encode('HTTP/1.0 404 Not Found\r\n\r\n')), throwsFormatException);
  });

  test("autre chose qu'un flux d'images refusé", () {
    expect(() => MjpegDecoder().add(ascii.encode('HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n')),
        throwsFormatException);
  });

  test('image annoncée trop grande refusée', () {
    final d = MjpegDecoder(maxFrameBytes: 1000);
    final head = ascii.encode('HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace;boundary=b\r\n\r\n'
        '--b\r\nContent-Length: 5000\r\n\r\n');
    expect(() => d.add(head), throwsFormatException);
  });

  test('flux sans séparateur : refusé avant de remplir la mémoire', () {
    final d = MjpegDecoder(maxFrameBytes: 1000);
    d.add(ascii.encode('HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace;boundary=b\r\n\r\n'));
    expect(() => d.add(Uint8List(70000)), throwsFormatException);
  });
}
