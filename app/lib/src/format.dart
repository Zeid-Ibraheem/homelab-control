// Mise en forme des valeurs affichées, en français.
import 'dart:convert';
import 'dart:typed_data';

/// Durée lisible : « 45 s », « 12 min », « 5 h 07 », « 2 j 3 h ».
String duration(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  if (s < 60) return '$s s';
  final minutes = s ~/ 60;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final m = minutes % 60;
  if (hours < 24) return m == 0 ? '$hours h' : '$hours h ${two(m)}';
  final days = hours ~/ 24;
  final h = hours % 24;
  return h == 0 ? '$days j' : '$days j $h h';
}

String two(int v) => v.toString().padLeft(2, '0');

/// Heure : « 18:30 ».
String clock(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

/// Date et heure courtes : « 18/10 18:30 ».
String shortDate(DateTime t) => '${two(t.day)}/${two(t.month)} ${clock(t)}';

const _days = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];

/// Moment à venir : « 18:30 », « demain 18:30 » ou « lun. 18:30 ».
String when(DateTime t, DateTime now) {
  // En UTC pour que le passage à l'heure d'été ne fausse pas le nombre de jours.
  final day = DateTime.utc(t.year, t.month, t.day);
  final today = DateTime.utc(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return clock(t);
  if (diff == 1) return 'demain ${clock(t)}';
  if (diff > 1 && diff < 7) return '${_days[t.weekday - 1]} ${clock(t)}';
  return shortDate(t);
}

/// Pourcentage : « 41 % », ou « — » si la mesure manque.
String pct(num? v) => v == null ? '—' : '${v.round()} %';

/// Température : « 44 °C », ou « — » si la mesure manque.
String temp(num? v) => v == null ? '—' : '${v.round()} °C';

String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String hexOf(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

Uint8List bytesOfHex(String hex) => Uint8List.fromList([
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

/// Empreinte d'une clé, au format affiché par ssh-keygen :
/// 16 octets = MD5 (« MD5:xx:xx:… »), 32 octets = SHA-256 (« SHA256:… »).
String fingerprintText(List<int> fp) {
  if (fp.length == 32) return 'SHA256:${base64.encode(fp).replaceAll('=', '')}';
  final pairs = [for (final b in fp) b.toRadixString(16).padLeft(2, '0')];
  return fp.length == 16 ? 'MD5:${pairs.join(':')}' : pairs.join(':');
}
