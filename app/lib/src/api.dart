// Contrat d'échange avec le script « homelab » du serveur : commandes envoyées
// et réponses JSON (voir server/README.md et tower/README.md).
import 'dart:convert';

/// Les seules commandes que l'application fabrique. Le serveur vérifie de
/// toute façon chaque commande reçue.
abstract final class Cmd {
  static const status = 'status';
  static const health = 'health';
  static const wake = 'wake';
  static const towerOff = 'tower-off';
  static const towerReboot = 'tower-reboot';
  static const version = 'version';

  static String extend([int? hours]) =>
      hours == null ? 'extend' : 'extend ${_check(hours, 1, 720)}';
  static String extendMinutes(int minutes) => 'extend-min ${_check(minutes, 1, 43200)}';
  static String offIn(int minutes) => 'off-in ${_check(minutes, 1, 10080)}';
  static String hold(bool on) => on ? 'hold on' : 'hold off';
  static String log(int count) => 'log ${_check(count, 1, 200)}';

  /// Redémarre un service du serveur (autorisé par SERVER_RESTARTABLE).
  static String restart(String service) => 'restart ${_service(service)}';

  /// Redémarre un service de la tour (autorisé par TOWER_RESTARTABLE).
  static String towerRestart(String service) => 'tower-restart ${_service(service)}';

  static int _check(int v, int min, int max) {
    if (v < min || v > max) throw RangeError.range(v, min, max);
    return v;
  }

  /// Même règle que les scripts : minuscules, chiffres, tirets, 48 au plus.
  static final _serviceName = RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$');

  static String _service(String name) {
    if (!_serviceName.hasMatch(name)) throw ArgumentError.value(name, 'service', 'nom de service invalide');
    return name;
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

/// Réponse à « status » : le serveur, le câble, la tour, la webcam et les
/// allumages programmés.
class Status {
  const Status({
    required this.server,
    required this.tower,
    this.webcamPort,
    this.wakeSpecs = const [],
    this.nextWake,
  });

  final ServerState server;
  final TowerState tower;

  /// Port local du serveur vidéo, joignable par tunnel SSH ; null = pas de webcam.
  final int? webcamPort;

  /// Dates d'allumage programmé, au format systemd (« Mon..Fri *-*-* 07:45:00 »).
  final List<String> wakeSpecs;

  /// Prochain allumage programmé, s'il y en a un.
  final DateTime? nextWake;

  factory Status.fromReply(Reply r) {
    final webcam = _map(r.data['webcam']);
    final schedule = _map(r.data['wake_schedule']) ?? const {};
    final specs = schedule['specs'];
    return Status(
      server: ServerState.fromJson(r.data),
      tower: TowerState.fromJson(_map(r.data['tower']) ?? const {}),
      webcamPort: webcam == null ? null : _int(webcam['port']),
      wakeSpecs: specs is List ? [for (final s in specs) if (s is String) s] : const [],
      nextWake: _date(schedule['next']),
    );
  }
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
    this.wifi,
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

  /// Signal Wi-Fi ; null si la machine n'est pas connectée en Wi-Fi.
  final Wifi? wifi;

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
      wifi: Wifi.fromJson(s['wifi']),
    );
  }
}

/// Signal Wi-Fi d'une machine, en dBm (décibels-milliwatts : -50 est un très
/// bon signal, -80 un signal à peine utilisable).
class Wifi {
  const Wifi({required this.iface, required this.signalDbm});
  final String iface;
  final int signalDbm;

  static Wifi? fromJson(Object? v) {
    final m = _map(v);
    final dbm = _int(m?['signal_dbm']);
    if (m == null || dbm == null) return null;
    return Wifi(iface: _str(m['iface']) ?? '?', signalDbm: dbm);
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
    this.wifi,
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
  final Wifi? wifi;

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
      wifi: Wifi.fromJson(d['wifi']),
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
    this.byServer = false,
  });

  final DateTime? deadline;
  final int remainingS;

  /// « Ne pas éteindre » est actif.
  final bool hold;

  /// Plafond : aucune demande ne va au-delà.
  final DateTime? cap;

  /// Extinction repoussée parce que la tour est utilisée.
  final bool delayed;

  /// La tour a été allumée par le serveur (réveil, redémarrage à distance),
  /// et non à la main.
  final bool byServer;

  factory AutoOff.fromJson(Map<String, dynamic> a) => AutoOff(
        deadline: _date(a['deadline']),
        remainingS: _int(a['remaining_s']) ?? 0,
        hold: a['hold'] == true,
        cap: _date(a['cap']),
        delayed: a['delayed'] == true,
        byServer: a['origin'] == 'server',
      );

  /// Minutes que l'on peut encore ajouter à l'échéance affichée avant le
  /// plafond (0 si atteint, ou si « ne pas éteindre » va déjà jusqu'au plafond).
  int minutesToCap(DateTime now) {
    final c = cap;
    final d = deadline;
    if (c == null || d == null || hold) return 0;
    final from = d.isAfter(now) ? d : now;
    final m = c.difference(from).inMinutes;
    return m < 0 ? 0 : m;
  }

  /// Minutes entre maintenant et le plafond (0 si atteint).
  int minutesFromNowToCap(DateTime now) {
    final c = cap;
    if (c == null) return 0;
    final m = c.difference(now).inMinutes;
    return m < 0 ? 0 : m;
  }

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

/// Réponse à « health » : santé du serveur et de la tour.
class HealthReport {
  const HealthReport({required this.server, required this.towerOnline, this.tower});

  final MachineHealth server;
  final bool towerOnline;

  /// Santé de la tour, ou null si elle est éteinte ou ne répond pas.
  final MachineHealth? tower;

  factory HealthReport.fromReply(Reply r) {
    final t = _map(r.data['tower']) ?? const {};
    final detail = _map(t['detail']);
    return HealthReport(
      server: MachineHealth.fromJson(_map(r.data['server']) ?? const {}),
      towerOnline: t['online'] == true,
      tower: detail == null ? null : MachineHealth.fromJson(detail),
    );
  }
}

class MachineHealth {
  const MachineHealth({this.services = const [], this.failedUnits = 0, this.disks, this.security});

  final List<ServiceState> services;
  final int failedUnits;

  /// Disques suivis ; null si la lecture est impossible (smartctl absent).
  final List<DiskHealth>? disks;
  final SecuritySummary? security;

  factory MachineHealth.fromJson(Map<String, dynamic> m) {
    final services = m['services'];
    final disks = m['disks'];
    final security = _map(m['security']);
    return MachineHealth(
      services: services is List
          ? [
              for (final s in services)
                if (s is Map<String, dynamic>)
                  ServiceState(
                    _str(s['name']) ?? '?',
                    _str(s['state']) ?? 'unknown',
                    restartable: s['restartable'] == true,
                  ),
            ]
          : const [],
      failedUnits: _int(m['failed_units']) ?? 0,
      disks: disks is List
          ? [for (final d in disks) if (d is Map<String, dynamic>) DiskHealth.fromJson(d)]
          : null,
      security: security == null ? null : SecuritySummary.fromJson(security),
    );
  }
}

class ServiceState {
  const ServiceState(this.name, this.state, {this.restartable = false});
  final String name;

  /// État donné par systemd : active, inactive, failed, activating…
  final String state;

  /// L'application peut le redémarrer (autorisé dans la configuration de la machine).
  final bool restartable;

  bool get active => state == 'active';
}

/// Réponse à « restart » (serveur) ou réponse de la tour à « tower-restart ».
class RestartResult {
  const RestartResult({required this.pending, required this.state});

  /// systemd n'avait pas fini au bout de 45 s : le redémarrage continue.
  final bool pending;

  /// État du service juste après : active, failed…
  final String state;

  /// [data] : la réponse du serveur, ou celle de la tour (Reply.tower).
  factory RestartResult.fromJson(Map<String, dynamic>? data) => RestartResult(
        pending: data?['result'] == 'pending',
        state: _str(data?['state']) ?? 'unknown',
      );
}

/// Santé d'un disque, d'après SMART (l'autodiagnostic intégré aux disques).
class DiskHealth {
  const DiskHealth({
    required this.device,
    this.model,
    this.standby = false,
    this.passed,
    this.tempC,
    this.powerOnHours,
    this.usedPct,
    this.mediaErrors,
    this.reallocated,
    this.pending,
    this.error,
  });

  final String device;
  final String? model;

  /// Disque en veille : pas lu, pour ne pas le réveiller.
  final bool standby;

  /// Verdict du disque lui-même : true = sain, false = panne annoncée.
  final bool? passed;
  final num? tempC;
  final int? powerOnHours;

  /// Usure d'un SSD NVMe, en % de sa durée de vie prévue.
  final int? usedPct;
  final int? mediaErrors;

  /// Secteurs remplacés, et secteurs douteux en attente (disques SATA).
  final int? reallocated;
  final int? pending;
  final String? error;

  /// Un signe de problème : panne annoncée, secteurs abîmés, erreurs.
  bool get alarming =>
      passed == false || (reallocated ?? 0) > 0 || (pending ?? 0) > 0 || (mediaErrors ?? 0) > 0;

  factory DiskHealth.fromJson(Map<String, dynamic> d) => DiskHealth(
        device: _str(d['device']) ?? '?',
        model: _str(d['model']),
        standby: d['standby'] == true,
        passed: d['passed'] is bool ? d['passed'] as bool : null,
        tempC: _num(d['temp_c']),
        powerOnHours: _int(d['power_on_hours']),
        usedPct: _int(d['used_pct']),
        mediaErrors: _int(d['media_errors']),
        reallocated: _int(d['reallocated']),
        pending: _int(d['pending']),
        error: _str(d['error']),
      );
}

/// Sécurité sur les dernières 24 h.
class SecuritySummary {
  const SecuritySummary({
    this.logins = 0,
    this.failures = 0,
    this.firewallBlocks,
    this.lastLogins = const [],
  });

  /// Connexions SSH réussies (hors compte homelab, qui sert aux scripts).
  final int logins;

  /// Tentatives de connexion refusées.
  final int failures;

  /// Paquets bloqués par le pare-feu ; null s'il n'y a pas de pare-feu ufw.
  final int? firewallBlocks;
  final List<LoginEntry> lastLogins;

  factory SecuritySummary.fromJson(Map<String, dynamic> s) {
    final last = s['last_logins'];
    return SecuritySummary(
      logins: _int(s['ssh_logins_24h']) ?? 0,
      failures: _int(s['ssh_failures_24h']) ?? 0,
      firewallBlocks: _int(s['firewall_blocks_24h']),
      lastLogins: last is List
          ? [for (final e in last) if (e is Map<String, dynamic>) LoginEntry.fromJson(e)]
          : const [],
    );
  }
}

class LoginEntry {
  const LoginEntry({this.time, required this.user, required this.from, required this.method});
  final DateTime? time;
  final String user;
  final String from;
  final String method;

  factory LoginEntry.fromJson(Map<String, dynamic> e) => LoginEntry(
        time: _date(e['time']),
        user: _str(e['user']) ?? '?',
        from: _str(e['from']) ?? '?',
        method: _str(e['method']) ?? '?',
      );
}

String? _str(Object? v) => v is String ? v : null;
num? _num(Object? v) => v is num ? v : null;
int? _int(Object? v) => v is num ? v.toInt() : null;
Map<String, dynamic>? _map(Object? v) => v is Map<String, dynamic> ? v : null;
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
