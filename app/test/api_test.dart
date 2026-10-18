import 'package:flutter_test/flutter_test.dart';
import 'package:homelab_control/src/api.dart';

// Réponses au format du script « homelab », avec des valeurs fictives.
const statusTowerOn = '{"ok":true,"api":1,"time":"2026-01-01T12:00:00+01:00",'
    '"server":{"uptime_s":345600,"load":[0.08,0.12,0.10],"cpu_pct":2.3,"mem_used_pct":21.4,'
    '"temp_c":41.0,"disk_used_pct":12,"battery_pct":64,"on_ac":true},'
    '"link":{"present":true,"carrier":true},'
    '"tower":{"online":true,"via":"link","detail":{"ok":true,"api":1,"time":"2026-01-01T12:00:00+01:00",'
    '"uptime_s":5400,"boot_time":"2026-01-01T10:30:00+01:00","cpu_pct":3.1,"mem_used_pct":18.2,'
    '"cpu_temp_c":44.0,"gpu_temp_c":null,"disk_used_pct":35,"session_active":true,'
    '"busy":"mise à jour pacman en cours",'
    '"auto_off":{"deadline":"2026-01-01T18:30:00+01:00","remaining_s":23400,"hold":true,'
    '"cap":"2026-01-03T10:30:00+01:00","delayed":false}}}}';

const statusTowerOff = '{"ok":true,"api":1,"time":"2026-01-01T12:00:00+01:00",'
    '"server":{"uptime_s":60,"load":[0.00,0.00,0.00],"cpu_pct":null,"mem_used_pct":5.0,'
    '"temp_c":null,"disk_used_pct":null,"battery_pct":null,"on_ac":null},'
    '"link":{"present":true,"carrier":false},'
    '"tower":{"online":false,"via":null,"detail":null}}';

void main() {
  group('commandes', () {
    test('valeurs fixes', () {
      expect(Cmd.extend(), 'extend');
      expect(Cmd.extend(3), 'extend 3');
      expect(Cmd.offIn(30), 'off-in 30');
      expect(Cmd.hold(true), 'hold on');
      expect(Cmd.hold(false), 'hold off');
      expect(Cmd.log(50), 'log 50');
    });

    test('valeurs hors limites refusées avant tout envoi', () {
      expect(() => Cmd.extend(0), throwsRangeError);
      expect(() => Cmd.extend(721), throwsRangeError);
      expect(() => Cmd.offIn(0), throwsRangeError);
      expect(() => Cmd.offIn(10081), throwsRangeError);
      expect(() => Cmd.log(201), throwsRangeError);
    });
  });

  group('réponses', () {
    test('tour allumée : toutes les mesures', () {
      final s = Status.fromReply(Reply.parse(statusTowerOn));
      expect(s.server.uptimeS, 345600);
      expect(s.server.batteryPct, 64);
      expect(s.server.onAc, isTrue);
      expect(s.server.linkCarrier, isTrue);
      expect(s.tower.online, isTrue);
      expect(s.tower.via, 'link');
      final d = s.tower.detail!;
      expect(d.cpuTempC, 44.0);
      expect(d.gpuTempC, isNull);
      expect(d.sessionActive, isTrue);
      expect(d.busy, 'mise à jour pacman en cours');
      final a = d.autoOff!;
      expect(a.remainingS, 23400);
      expect(a.hold, isTrue);
      expect(a.delayed, isFalse);
      expect(a.deadline!.toUtc(), DateTime.utc(2026, 1, 1, 17, 30));
      expect(a.cap!.toUtc(), DateTime.utc(2026, 1, 3, 9, 30));
    });

    test('tour éteinte : mesures absentes = null', () {
      final s = Status.fromReply(Reply.parse(statusTowerOff));
      expect(s.server.cpuPct, isNull);
      expect(s.server.onAc, isNull);
      expect(s.server.linkCarrier, isFalse);
      expect(s.tower.online, isFalse);
      expect(s.tower.detail, isNull);
    });

    test('erreur du serveur', () {
      final r = Reply.parse('{"ok":false,"error":"tower_offline","message":"la tour est éteinte ou injoignable"}\n');
      expect(r.ok, isFalse);
      expect(r.error, 'tower_offline');
      expect(r.message, 'la tour est éteinte ou injoignable');
    });

    test('action relayée : échéance de la tour', () {
      final r = Reply.parse('{"ok":true,"action":"extend","via":"vpn","tower":{"ok":true,"action":"extend",'
          '"hours":2,"capped":false,"auto_off":{"deadline":"2026-01-01T20:30:00+01:00","remaining_s":30600,'
          '"hold":false,"cap":"2026-01-03T10:30:00+01:00","delayed":false}}}');
      expect(AutoOff.fromRelayed(r)!.remainingS, 30600);
      expect(r.tower!['capped'], isFalse);
    });

    test('journal : du plus récent au plus ancien', () {
      final r = Reply.parse('{"ok":true,"entries":['
          '{"ts":"2026-01-01T10:00:00+01:00","action":"wake","result":"sent","via":"ssh","from":"192.0.2.10"},'
          '{"ts":"2026-01-01T11:00:00+01:00","action":"status x","result":"refused","via":"ssh","from":"192.0.2.10"}]}');
      final entries = JournalEntry.listFrom(r);
      expect(entries.map((e) => e.action), ['status x', 'wake']);
      expect(entries.first.result, 'refused');
    });

    test('réponses illisibles refusées', () {
      expect(() => Reply.parse('bonjour'), throwsFormatException);
      expect(() => Reply.parse('[1,2]'), throwsFormatException);
      expect(() => Reply.parse('{"status":"ok"}'), throwsFormatException);
      expect(() => Reply.parse(''), throwsFormatException);
    });
  });
  group('extinction automatique', () {
    final cap = DateTime.utc(2026, 1, 1, 18, 0);
    final now = DateTime.utc(2026, 1, 1, 12, 0);

    test('marge avant le plafond', () {
      final a = AutoOff(deadline: DateTime.utc(2026, 1, 1, 14, 0), cap: cap, remainingS: 7200);
      expect(a.minutesToCap(now), 240);
      expect(a.minutesFromNowToCap(now), 360);
    });

    test('échéance passée (tour utilisée) : la marge part de maintenant', () {
      final a = AutoOff(deadline: DateTime.utc(2026, 1, 1, 11, 0), cap: cap, delayed: true);
      expect(a.minutesToCap(now), 360);
    });

    test('« ne pas éteindre » ou plafond atteint : aucune marge', () {
      expect(AutoOff(deadline: cap, cap: cap, hold: true).minutesToCap(now), 0);
      expect(AutoOff(deadline: cap, cap: cap).minutesToCap(now), 0);
      expect(AutoOff(deadline: cap, cap: cap).minutesFromNowToCap(DateTime.utc(2026, 1, 1, 19, 0)), 0);
    });

    test('origine du démarrage', () {
      expect(AutoOff.fromJson(const {'origin': 'server'}).byServer, isTrue);
      expect(AutoOff.fromJson(const {'origin': 'button'}).byServer, isFalse);
    });
  });

  group('état : webcam et allumages programmés', () {
    test('présents', () {
      final s = Status.fromReply(Reply.parse('{"ok":true,"server":{},"link":{},"tower":{"online":false},'
          '"webcam":{"port":8080},"wake_schedule":{"specs":["Mon..Fri *-*-* 07:45:00"],"next":"2026-01-05T07:45:00+01:00"}}'));
      expect(s.webcamPort, 8080);
      expect(s.wakeSpecs, ['Mon..Fri *-*-* 07:45:00']);
      expect(s.nextWake!.toUtc(), DateTime.utc(2026, 1, 5, 6, 45));
    });

    test('absents', () {
      final s = Status.fromReply(Reply.parse('{"ok":true,"server":{},"link":{},"tower":{"online":false},'
          '"webcam":null,"wake_schedule":{"specs":[],"next":null}}'));
      expect(s.webcamPort, isNull);
      expect(s.wakeSpecs, isEmpty);
      expect(s.nextWake, isNull);
    });
  });

  test('santé : services, disques, sécurité', () {
    final h = HealthReport.fromReply(Reply.parse('{"ok":true,"server":{"services":[{"name":"ssh","state":"active"},'
        '{"name":"cups","state":"failed"}],"failed_units":1,'
        '"disks":[{"device":"/dev/nvme0n1","model":"NVMe Test","standby":false,"passed":true,"temp_c":38,'
        '"power_on_hours":1234,"used_pct":2,"media_errors":0,"reallocated":null,"pending":null},'
        '{"device":"/dev/sda","passed":false,"pending":3},{"device":"/dev/sdb","standby":true,"passed":null},'
        '{"device":"/dev/sdz","error":"lecture impossible"}],'
        '"security":{"ssh_logins_24h":2,"ssh_failures_24h":5,"firewall_blocks_24h":null,'
        '"last_logins":[{"time":"2026-01-01T10:00:00+01:00","user":"alice","from":"192.0.2.3","method":"publickey"}]}},'
        '"tower":{"online":false,"via":null,"detail":null}}'));
    expect(h.server.services.map((s) => s.active), [true, false]);
    expect(h.server.failedUnits, 1);
    final disks = h.server.disks!;
    expect(disks[0].alarming, isFalse);
    expect(disks[0].usedPct, 2);
    expect(disks[1].alarming, isTrue);
    expect(disks[2].standby, isTrue);
    expect(disks[3].error, 'lecture impossible');
    expect(h.server.security!.failures, 5);
    expect(h.server.security!.firewallBlocks, isNull);
    expect(h.server.security!.lastLogins.single.user, 'alice');
    expect(h.towerOnline, isFalse);
    expect(h.tower, isNull);
  });

  test('santé : smartctl absent = disques null', () {
    final h = HealthReport.fromReply(Reply.parse('{"ok":true,"server":{"services":[],"failed_units":0,'
        '"disks":null,"security":null},"tower":{"online":true,"via":"link","detail":null}}'));
    expect(h.server.disks, isNull);
    expect(h.server.security, isNull);
    expect(h.towerOnline, isTrue);
  });

  test('commande extend-min', () {
    expect(Cmd.extendMinutes(95), 'extend-min 95');
    expect(() => Cmd.extendMinutes(0), throwsRangeError);
    expect(() => Cmd.extendMinutes(43201), throwsRangeError);
  });

  group('redémarrage de service', () {
    test('commandes', () {
      expect(Cmd.restart('cups'), 'restart cups');
      expect(Cmd.towerRestart('docker'), 'tower-restart docker');
      expect(Cmd.towerRestart('a' * 48), 'tower-restart ${'a' * 48}');
      expect(Cmd.towerRestart('a' * 48).length, lessThanOrEqualTo(64));
    });

    test('noms refusés avant tout envoi', () {
      for (final bad in ['', 'Cups', 'cups.service', '-cups', 'a b', 'a;b', 'a' * 49, '../x']) {
        expect(() => Cmd.restart(bad), throwsArgumentError, reason: bad);
        expect(() => Cmd.towerRestart(bad), throwsArgumentError, reason: bad);
      }
    });

    test('services redémarrables dans la santé', () {
      final m = MachineHealth.fromJson(const {
        'services': [
          {'name': 'ssh', 'state': 'active', 'restartable': false},
          {'name': 'cups', 'state': 'failed', 'restartable': true},
          {'name': 'ancien', 'state': 'active'},
        ],
        'failed_units': 1,
      });
      expect(m.services.map((s) => s.restartable), [false, true, false]);
    });

    test('réponses', () {
      final server = Reply.parse('{"ok":true,"action":"restart","service":"cups","result":"done","state":"active"}');
      final r = RestartResult.fromJson(server.data);
      expect(r.pending, isFalse);
      expect(r.state, 'active');
      final tower = Reply.parse('{"ok":true,"action":"tower-restart cups","via":"link","tower":'
          '{"ok":true,"action":"restart","service":"cups","result":"pending","state":"activating"}}');
      final t = RestartResult.fromJson(tower.tower);
      expect(t.pending, isTrue);
      expect(t.state, 'activating');
      expect(RestartResult.fromJson(null).state, 'unknown');
    });
  });

  group('Wi-Fi', () {
    test('serveur et tour', () {
      final s = Status.fromReply(Reply.parse('{"ok":true,"server":{"wifi":{"iface":"wlan0","signal_dbm":-56}},'
          '"link":{},"tower":{"online":true,"via":"link","detail":{"ok":true,"wifi":{"iface":"wlp9s0","signal_dbm":-71}}}}'));
      expect(s.server.wifi!.signalDbm, -56);
      expect(s.server.wifi!.iface, 'wlan0');
      expect(s.tower.detail!.wifi!.signalDbm, -71);
    });

    test('absent ou incomplet = null', () {
      final s = Status.fromReply(Reply.parse('{"ok":true,"server":{"wifi":null},"link":{},'
          '"tower":{"online":true,"via":"link","detail":{"ok":true,"wifi":{"iface":"wlan0"}}}}'));
      expect(s.server.wifi, isNull);
      expect(s.tower.detail!.wifi, isNull);
    });
  });
}
