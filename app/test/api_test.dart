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
}
