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

/// Empreinte d'une clé, au format affiché par ssh-keygen. dartssh2 la donne
/// déjà en texte (« SHA256:… ») ; sinon, 32 octets bruts = SHA-256 et
/// 16 octets = MD5 (« MD5:xx:xx:… »).
String fingerprintText(List<int> fp) {
  final printable = fp.isNotEmpty && fp.every((b) => b >= 0x20 && b < 0x7f);
  if (printable) {
    final text = String.fromCharCodes(fp);
    if (text.startsWith('SHA256:') || text.startsWith('MD5:')) return text;
  }
  if (fp.length == 32) return 'SHA256:${base64.encode(fp).replaceAll('=', '')}';
  final pairs = [for (final b in fp) b.toRadixString(16).padLeft(2, '0')];
  return fp.length == 16 ? 'MD5:${pairs.join(':')}' : pairs.join(':');
}

const _dayNames = {
  'mon': 'lundi',
  'tue': 'mardi',
  'wed': 'mercredi',
  'thu': 'jeudi',
  'fri': 'vendredi',
  'sat': 'samedi',
  'sun': 'dimanche',
};

/// Allumage programmé (format des minuteurs systemd), en clair quand c'est
/// possible : « Mon..Fri *-*-* 07:45:00 » → « du lundi au vendredi à 07:45 ».
/// Une forme moins courante est rendue telle quelle.
String describeSchedule(String spec) {
  final m = RegExp(r'^(?:([A-Za-z.,]+) )?\*-\*-\* (\d{1,2}):(\d{2})(?::00)?$').firstMatch(spec.trim());
  if (m == null) return spec;
  final time = '${m.group(2)!.padLeft(2, '0')}:${m.group(3)}';
  final days = m.group(1);
  if (days == null) return 'tous les jours à $time';
  final parts = <String>[];
  for (final item in days.split(',')) {
    final names = [for (final d in item.split('..')) _dayNames[d.toLowerCase()]];
    if (names.isEmpty || names.length > 2 || names.contains(null)) return spec;
    parts.add(names.length == 2 ? 'du ${names[0]} au ${names[1]}' : names[0]!);
  }
  final joined = parts.length == 1
      ? parts.first
      : '${parts.sublist(0, parts.length - 1).join(', ')} et ${parts.last}';
  final prefix = parts.length == 1 && !joined.startsWith('du ') ? 'le ' : '';
  return '$prefix$joined à $time';
}

/// Signal Wi-Fi en clair, d'après les repères habituels :
/// -55 dBm ou plus = excellent ; -67 = bon (vidéo, appels) ; -75 = moyen ;
/// -82 = faible ; en dessous, la connexion décroche.
String wifiText(int dbm) {
  final quality = dbm >= -55
      ? 'excellent'
      : dbm >= -67
          ? 'bon'
          : dbm >= -75
              ? 'moyen'
              : dbm >= -82
                  ? 'faible'
                  : 'très faible';
  return '$dbm dBm ($quality)';
}

/// État d'un service systemd, en français.
String serviceStateText(String state) => switch (state) {
      'active' => 'actif',
      'inactive' => 'arrêté',
      'failed' => 'en échec',
      'activating' => 'démarrage',
      'deactivating' => 'arrêt en cours',
      'reloading' => 'rechargement',
      'unknown' => 'inconnu',
      _ => state,
    };

/// Temps de fonctionnement d'un disque : « 36 h », « 51 j », « 2,3 ans ».
String powerOnText(int hours) {
  if (hours < 48) return '$hours h';
  if (hours < 24 * 365) return '${hours ~/ 24} j';
  return '${(hours / 8766).toStringAsFixed(1).replaceAll('.', ',')} ans';
}
