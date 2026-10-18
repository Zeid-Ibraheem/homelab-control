// Contrat d'échange avec le script « homelab » du serveur : commandes envoyées
// et réponses JSON (voir server/README.md et tower/README.md).
import 'dart:convert';

/// Les seules commandes que l'application fabrique. Le serveur vérifie de
/// toute façon chaque commande reçue.
abstract final class Cmd {
  static const status = 'status';
  static const wake = 'wake';
  static const towerOff = 'tower-off';
  static const towerReboot = 'tower-reboot';
  static const version = 'version';

  static String extend([int? hours]) =>
      hours == null ? 'extend' : 'extend ${_check(hours, 1, 720)}';
  static String offIn(int minutes) => 'off-in ${_check(minutes, 1, 10080)}';
  static String hold(bool on) => on ? 'hold on' : 'hold off';
  static String log(int count) => 'log ${_check(count, 1, 200)}';

  static int _check(int v, int min, int max) {
    if (v < min || v > max) throw RangeError.range(v, min, max);
    return v;
  }
}

/// Réponse du serveur : un objet JSON qui contient toujours « ok ».
class Reply {
  const Reply(this.data);
  final Map<String, dynamic> data;

  bool get ok => data['ok'] == true;
  String? get error => _str(data['error']);
  String get message => _str(data['message']) ?? error ?? 'réponse sans message';
  String? get result => _str(data['result']);

  /// Réponse de la tour, pour une action relayée (prolonger, éteindre…).
  Map<String, dynamic>? get tower => _map(data['tower']);

  static Reply parse(String text) {
    final line = text.split('\n').first.trim();
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw const FormatException('réponse illisible du serveur');
    }
    if (decoded is! Map<String, dynamic> || decoded['ok'] is! bool) {
      throw const FormatException('réponse inattendue du serveur');
    }
    return Reply(decoded);
  }
}

/// Réponse à « status » : le serveur, le câble et la tour.
class Status {
  const Status({required this.server, required this.tower});
  final ServerState server;
  final TowerState tower;

  factory Status.fromReply(Reply r) => Status(
        server: ServerState.fromJson(r.data),
        tower: TowerState.fromJson(_map(r.data['tower']) ?? const {}),
      );
}

class ServerState {
  const ServerState({
    this.uptimeS,
    this.cpuPct,
    this.memPct,
    this.tempC,
    this.diskPct,
    this.batteryPct,
    this.onAc,
    this.linkPresent = false,
    this.linkCarrier = false,
  });

  final int? uptimeS;
  final num? cpuPct;
  final num? memPct;
  final num? tempC;
  final num? diskPct;
  final int? batteryPct;
  final bool? onAc;
  final bool linkPresent;
  final bool linkCarrier;

  factory ServerState.fromJson(Map<String, dynamic> status) {
    final s = _map(status['server']) ?? const {};
    final link = _map(status['link']) ?? const {};
    return ServerState(
      uptimeS: _int(s['uptime_s']),
      cpuPct: _num(s['cpu_pct']),
      memPct: _num(s['mem_used_pct']),
      tempC: _num(s['temp_c']),
      diskPct: _num(s['disk_used_pct']),
      batteryPct: _int(s['battery_pct']),
      onAc: s['on_ac'] is bool ? s['on_ac'] as bool : null,
      linkPresent: link['present'] == true,
      linkCarrier: link['carrier'] == true,
    );
  }
}

class TowerState {
  const TowerState({required this.online, this.via, this.detail});

  /// La tour répond sur le câble ou sur le VPN.
  final bool online;

  /// « link » (câble), « vpn », ou null.
  final String? via;

  /// Réponse de la tour elle-même, ou null si elle ne répond pas encore.
  final TowerDetail? detail;

  factory TowerState.fromJson(Map<String, dynamic> t) {
    final d = _map(t['detail']);
    return TowerState(
      online: t['online'] == true,
      via: _str(t['via']),
      detail: d == null ? null : TowerDetail.fromJson(d),
    );
  }
}

class TowerDetail {
  const TowerDetail({
    this.uptimeS,
    this.cpuPct,
    this.memPct,
    this.cpuTempC,
    this.gpuTempC,
    this.diskPct,
    this.sessionActive = false,
    this.busy,
    this.autoOff,
  });

  final int? uptimeS;
  final num? cpuPct;
  final num? memPct;
  final num? cpuTempC;
  final num? gpuTempC;
  final num? diskPct;

  /// Une session graphique est ouverte et déverrouillée devant la tour.
  final bool sessionActive;

  /// Ce qui empêche l'extinction en ce moment (mise à jour…), ou null.
  final String? busy;
  final AutoOff? autoOff;

  factory TowerDetail.fromJson(Map<String, dynamic> d) {
    final a = _map(d['auto_off']);
    return TowerDetail(
      uptimeS: _int(d['uptime_s']),
      cpuPct: _num(d['cpu_pct']),
      memPct: _num(d['mem_used_pct']),
      cpuTempC: _num(d['cpu_temp_c']),
      gpuTempC: _num(d['gpu_temp_c']),
      diskPct: _num(d['disk_used_pct']),
      sessionActive: d['session_active'] == true,
      busy: _str(d['busy']),
      autoOff: a == null ? null : AutoOff.fromJson(a),
    );
  }
}

/// Extinction automatique de la tour.
class AutoOff {
  const AutoOff({
    this.deadline,
    this.remainingS = 0,
    this.hold = false,
    this.cap,
    this.delayed = false,
  });

  final DateTime? deadline;
  final int remainingS;

  /// « Ne pas éteindre » est actif.
  final bool hold;

  /// Plafond : aucune demande ne va au-delà.
  final DateTime? cap;

  /// Extinction repoussée parce que la tour est utilisée.
  final bool delayed;

  factory AutoOff.fromJson(Map<String, dynamic> a) => AutoOff(
        deadline: _date(a['deadline']),
        remainingS: _int(a['remaining_s']) ?? 0,
        hold: a['hold'] == true,
        cap: _date(a['cap']),
        delayed: a['delayed'] == true,
      );

  /// Échéance contenue dans la réponse à une action relayée vers la tour.
  static AutoOff? fromRelayed(Reply r) {
    final a = _map(r.tower?['auto_off']);
    return a == null ? null : AutoOff.fromJson(a);
  }
}

/// Une ligne du journal des actions du serveur.
class JournalEntry {
  const JournalEntry({this.time, required this.action, required this.result, required this.via, required this.from});

  final DateTime? time;
  final String action;
  final String result;
  final String via;
  final String from;

  factory JournalEntry.fromJson(Map<String, dynamic> e) => JournalEntry(
        time: _date(e['ts']),
        action: _str(e['action']) ?? '?',
        result: _str(e['result']) ?? '?',
        via: _str(e['via']) ?? '?',
        from: _str(e['from']) ?? '?',
      );

  /// Entrées de la réponse à « log N », de la plus récente à la plus ancienne.
  static List<JournalEntry> listFrom(Reply r) {
    final list = r.data['entries'];
    if (list is! List) return const [];
    return [
      for (final e in list.reversed)
        if (e is Map<String, dynamic>) JournalEntry.fromJson(e),
    ];
  }
}

String? _str(Object? v) => v is String ? v : null;
num? _num(Object? v) => v is num ? v : null;
int? _int(Object? v) => v is num ? v.toInt() : null;
Map<String, dynamic>? _map(Object? v) => v is Map<String, dynamic> ? v : null;
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
