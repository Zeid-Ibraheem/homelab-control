// Tableau de bord : état du serveur et de la tour, boutons d'action, et accès
// à la santé, à la webcam et aux terminaux.
import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'duration_sheet.dart';
import 'format.dart';
import 'health_screen.dart';
import 'journal_screen.dart';
import 'settings_screen.dart';
import 'ssh_link.dart';
import 'store.dart';
import 'terminal_screen.dart';
import 'webcam_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.data,
    required this.onReset,
    required this.onStoreChanged,
  });

  final AppData data;
  final Future<void> Function({required bool all}) onReset;

  /// Appelé quand des réglages ont été enregistrés : les relire.
  final VoidCallback onStoreChanged;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  static const _refreshEvery = Duration(seconds: 30);

  late final SshLink _link = widget.data.link();
  Status? _status;
  String? _error;
  DateTime? _updated;
  bool _loading = false;
  bool _again = false; // une relecture a été demandée pendant la précédente
  bool _acting = false;
  Timer? _timer;
  Timer? _fastTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _timer = Timer.periodic(_refreshEvery, (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _fastTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
      _timer ??= Timer.periodic(_refreshEvery, (_) => unawaited(_refresh()));
    } else if (state == AppLifecycleState.paused) {
      // Rien ne tourne en arrière-plan.
      _timer?.cancel();
      _timer = null;
      _fastTimer?.cancel();
      _fastTimer = null;
    }
  }

  Future<void> _refresh() async {
    if (_loading) {
      _again = true;
      return;
    }
    setState(() => _loading = true);
    try {
      final reply = Reply.parse(await _link.run(Cmd.status));
      if (!reply.ok) throw LinkError(capitalize(reply.message));
      final status = Status.fromReply(reply);
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
        _updated = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (_again && mounted) {
      _again = false;
      unawaited(_refresh());
    }
  }

  /// Après un réveil : état relu toutes les 5 secondes, pendant 2 minutes au
  /// plus, jusqu'à ce que la tour réponde.
  void _watchWake() {
    _fastTimer?.cancel();
    final until = DateTime.now().add(const Duration(minutes: 2));
    _fastTimer = Timer.periodic(const Duration(seconds: 5), (t) {
      final detail = _status?.tower.detail;
      if (DateTime.now().isAfter(until) || detail != null) {
        t.cancel();
        if (identical(_fastTimer, t)) _fastTimer = null;
        return;
      }
      unawaited(_refresh());
    });
  }

  /// Envoie une action, affiche le résultat, puis relit l'état.
  Future<void> _act(String command, String Function(Reply r) describe) async {
    setState(() => _acting = true);
    var message = '';
    try {
      final reply = Reply.parse(await _link.run(command));
      message = reply.ok ? describe(reply) : capitalize(reply.message);
    } catch (e) {
      message = errorText(e);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _refresh();
  }

  Future<void> _wake() => _act(Cmd.wake, (r) {
        if (r.result == 'sent') _watchWake();
        return switch (r.result) {
          'sent' => 'Réveil envoyé : la tour démarre (environ une minute).',
          'already_on' => 'La tour est déjà allumée.',
          'ignored_recent' => 'Réveil déjà envoyé il y a quelques secondes.',
          'busy' => 'Un réveil est déjà en cours.',
          _ => 'Réveil : ${r.result ?? 'fait'}.',
        };
      });

  Future<void> _shutdown() async {
    if (!await _confirm('Éteindre la tour maintenant ?', 'Éteindre') || !mounted) return;
    await _act(Cmd.towerOff, (r) => r.result == 'already_off'
        ? 'La tour est déjà éteinte.'
        : "La tour s'éteint dans 3 secondes.");
  }

  Future<void> _reboot() async {
    if (!await _confirm('Redémarrer la tour maintenant ?', 'Redémarrer') || !mounted) return;
    await _act(Cmd.towerReboot, (_) => 'La tour redémarre dans 3 secondes.');
  }

  /// Prolonger : durée au choix, jusqu'au plafond.
  Future<void> _extend() async {
    final a = _status?.tower.detail?.autoOff;
    if (a == null) return;
    final now = DateTime.now();
    final deadline = a.deadline;
    final from = deadline != null && deadline.isAfter(now) ? deadline : now;
    final minutes = await chooseDuration(
      context,
      title: "Repousser l'extinction de…",
      maxMinutes: a.minutesToCap(now),
      preview: (m) => 'Extinction : ${when(from.add(Duration(minutes: m)), now)}',
      emptyMessage: a.hold
          ? '« Ne pas éteindre » est actif : la tour reste allumée jusqu\'au plafond.'
          : 'Plafond atteint : impossible de repousser davantage.',
    );
    if (minutes == null || !mounted) return;
    await _act(Cmd.extendMinutes(minutes), (r) {
      final after = AutoOff.fromRelayed(r);
      final capped = r.tower?['capped'] == true;
      final at = after?.deadline == null ? '' : ' : ${when(after!.deadline!, DateTime.now())}';
      return 'Extinction repoussée$at${capped ? ' (plafond atteint)' : ''}.';
    });
  }

  /// Éteindre dans… : durée au choix, jusqu'au plafond.
  Future<void> _offIn() async {
    final a = _status?.tower.detail?.autoOff;
    if (a == null) return;
    final now = DateTime.now();
    final minutes = await chooseDuration(
      context,
      title: 'Éteindre la tour dans…',
      maxMinutes: a.minutesFromNowToCap(now),
      preview: (m) => 'Extinction : ${when(now.add(Duration(minutes: m)), now)}',
      emptyMessage: 'Plafond atteint : utilise « Éteindre ».',
      quick: const [5, 15, 30, 60],
    );
    if (minutes == null || !mounted) return;
    await _act(Cmd.offIn(minutes), (r) {
      final after = AutoOff.fromRelayed(r);
      return after?.deadline == null
          ? 'Extinction programmée.'
          : "La tour s'éteindra à ${clock(after!.deadline!)}.";
    });
  }

  Future<void> _hold(bool on) => _act(
        Cmd.hold(on),
        (_) => on ? '« Ne pas éteindre » activé, jusqu\'au plafond.' : '« Ne pas éteindre » désactivé.',
      );

  Future<bool> _confirm(String question, String action) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(question),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return yes ?? false;
  }

  void _open(Widget screen) {
    unawaited(Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen)));
  }

  void _openSettings() => _open(SettingsScreen(
        data: widget.data,
        onReset: widget.onReset,
        onStoreChanged: widget.onStoreChanged,
      ));

  void _openTerminal(bool toTower) => _open(TerminalScreen(
        data: widget.data,
        toTower: toTower,
        onStoreChanged: widget.onStoreChanged,
      ));

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Homelab'),
        actions: [
          IconButton(
            tooltip: 'Santé',
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: () => _open(HealthScreen(link: _link)),
          ),
          IconButton(
            tooltip: 'Journal',
            icon: const Icon(Icons.history),
            onPressed: () => _open(JournalScreen(link: _link)),
          ),
          IconButton(
            tooltip: 'Réglages',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
        bottom: _loading || _acting
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null) _ErrorCard(_error!),
            if (s == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Connexion au serveur…')),
              ),
            if (s != null) ...[
              _serverCard(s.server),
              const SizedBox(height: 12),
              _towerCard(s),
              const SizedBox(height: 12),
              _actions(s.tower),
              const SizedBox(height: 12),
              _access(s),
              if (_updated != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Mis à jour à ${clock(_updated!)}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _serverCard(ServerState v) {
    final power = switch (v.onAc) {
      true => ' (sur secteur)',
      false => ' (sur batterie)',
      null => '',
    };
    final cable = !v.linkPresent
        ? 'adaptateur absent'
        : v.linkCarrier
            ? 'branché'
            : 'pas de signal';
    return _Section(
      title: 'Serveur',
      state: 'en ligne',
      on: true,
      lines: [
        if (v.uptimeS != null) 'Allumé depuis ${duration(v.uptimeS!)}',
        'Processeur ${pct(v.cpuPct)} · Mémoire ${pct(v.memPct)} · ${temp(v.tempC)}',
        'Disque ${pct(v.diskPct)}${v.batteryPct == null ? '' : ' · Batterie ${v.batteryPct} %$power'}',
        if (v.wifi != null) 'Wi-Fi : ${wifiText(v.wifi!.signalDbm)}',
        'Câble vers la tour : $cable',
      ],
    );
  }

  Widget _towerCard(Status s) {
    final t = s.tower;
    final now = DateTime.now();
    final next = s.nextWake;
    final schedule = [
      if (next != null) 'Prochain allumage programmé : ${when(next, now)}',
      if (s.wakeSpecs.isNotEmpty) 'Programmé : ${s.wakeSpecs.map(describeSchedule).join(' ; ')}',
    ];
    if (!t.online) {
      return _Section(title: 'Tour', state: 'éteinte', on: false, lines: schedule);
    }
    final via = switch (t.via) {
      'link' => 'par le câble',
      'vpn' => 'par le VPN',
      _ => '',
    };
    final d = t.detail;
    if (d == null) {
      return _Section(
        title: 'Tour',
        state: 'allumée $via',
        on: true,
        lines: ['Elle démarre, ou ne répond pas encore.', ...schedule],
      );
    }
    final a = d.autoOff;
    return _Section(
      title: 'Tour',
      state: 'allumée $via',
      on: true,
      lines: [
        if (d.uptimeS != null)
          'Allumée depuis ${duration(d.uptimeS!)}'
              '${a == null ? '' : a.byServer ? ', par le serveur' : ', à la main'}',
        'Processeur ${pct(d.cpuPct)} · ${temp(d.cpuTempC)} · Carte graphique ${temp(d.gpuTempC)}',
        'Mémoire ${pct(d.memPct)} · Disque ${pct(d.diskPct)}',
        if (d.wifi != null) 'Wi-Fi : ${wifiText(d.wifi!.signalDbm)}',
        if (a != null)
          'Extinction automatique dans ${duration(a.remainingS)}'
              '${a.deadline == null ? '' : ' (${when(a.deadline!, now)})'}',
        if (a != null && a.cap != null) 'Plafond : ${when(a.cap!, now)}',
        ...schedule,
      ],
      chips: [
        if (a != null && a.hold) 'Ne pas éteindre',
        if (a != null && a.delayed) 'Repoussée : tour utilisée',
        if (d.sessionActive) 'Session ouverte devant la tour',
        if (d.busy != null) capitalize(d.busy!),
      ],
    );
  }

  Widget _actions(TowerState t) {
    final off = _acting;
    if (!t.online) {
      return FilledButton.icon(
        onPressed: off ? null : _wake,
        icon: const Icon(Icons.power_settings_new),
        label: const Text('Allumer la tour'),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final hold = t.detail?.autoOff?.hold ?? false;
    final canPilot = t.detail?.autoOff != null;
    return Card(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: off || !canPilot ? null : _extend,
                    child: const Text('Prolonger…'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: off || !canPilot ? null : _offIn,
                    child: const Text('Éteindre dans…'),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: const Text('Ne pas éteindre'),
              subtitle: const Text("Jusqu'au plafond"),
              value: hold,
              onChanged: off || !canPilot ? null : _hold,
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: off ? null : _reboot,
                    child: const Text('Redémarrer'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    ),
                    onPressed: off ? null : _shutdown,
                    child: const Text('Éteindre'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Accès : webcam et terminaux.
  Widget _access(Status s) {
    final data = widget.data;
    final port = s.webcamPort;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: port == null ? null : () => _open(WebcamScreen(link: _link, port: port)),
              icon: const Icon(Icons.videocam_outlined),
              label: Text(port == null ? 'Webcam (non configurée)' : 'Webcam'),
            ),
            OutlinedButton.icon(
              onPressed: data.serverTerminalReady ? () => _openTerminal(false) : _openSettings,
              icon: const Icon(Icons.terminal),
              label: const Text('Terminal serveur'),
            ),
            OutlinedButton.icon(
              onPressed: data.towerTerminalReady && s.tower.online ? () => _openTerminal(true) : null,
              icon: const Icon(Icons.terminal),
              label: const Text('Terminal tour'),
            ),
            if (!data.serverTerminalReady)
              Text(
                'Terminaux : à configurer dans les réglages.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.state,
    required this.on,
    this.lines = const [],
    this.chips = const [],
  });

  final String title;
  final String state;
  final bool on;
  final List<String> lines;
  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: on ? Colors.greenAccent : scheme.outline),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state,
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            for (final l in lines) Padding(padding: const EdgeInsets.only(top: 6), child: Text(l)),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final c in chips) Chip(label: Text(c))],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
      ),
    );
  }
}
