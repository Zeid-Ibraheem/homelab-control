// Tableau de bord : état du serveur et de la tour, et les boutons d'action.
import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'format.dart';
import 'journal_screen.dart';
import 'settings_screen.dart';
import 'ssh_link.dart';
import 'store.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.data, required this.onReset});

  final AppData data;
  final Future<void> Function({required bool all}) onReset;

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

  Future<void> _extend() async {
    final hours = await _choose('Repousser l\'extinction de…', const {
      1: '1 heure',
      2: '2 heures',
      4: '4 heures',
      8: '8 heures',
    });
    if (hours == null || !mounted) return;
    await _act(Cmd.extend(hours), (r) {
      final a = AutoOff.fromRelayed(r);
      final capped = r.tower?['capped'] == true;
      final at = a?.deadline == null ? '' : ' : ${when(a!.deadline!, DateTime.now())}';
      return 'Extinction repoussée$at${capped ? ' (plafond atteint)' : ''}.';
    });
  }

  Future<void> _offIn() async {
    final minutes = await _choose('Éteindre la tour dans…', const {
      15: '15 minutes',
      30: '30 minutes',
      60: '1 heure',
      120: '2 heures',
    });
    if (minutes == null || !mounted) return;
    await _act(Cmd.offIn(minutes), (r) {
      final a = AutoOff.fromRelayed(r);
      return a?.deadline == null
          ? 'Extinction programmée.'
          : "La tour s'éteindra à ${clock(a!.deadline!)}.";
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

  Future<int?> _choose(String title, Map<int, String> options) {
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final o in options.entries)
              ListTile(title: Text(o.value), onTap: () => Navigator.pop(ctx, o.key)),
          ],
        ),
      ),
    );
  }

  void _open(Widget screen) {
    unawaited(Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen)));
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Homelab'),
        actions: [
          IconButton(
            tooltip: 'Journal',
            icon: const Icon(Icons.history),
            onPressed: () => _open(JournalScreen(link: _link)),
          ),
          IconButton(
            tooltip: 'Réglages',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open(SettingsScreen(data: widget.data, onReset: widget.onReset)),
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
              _towerCard(s.tower),
              const SizedBox(height: 12),
              _actions(s.tower),
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
        'Câble vers la tour : $cable',
      ],
    );
  }

  Widget _towerCard(TowerState t) {
    if (!t.online) {
      return const _Section(title: 'Tour', state: 'éteinte', on: false);
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
        lines: const ['Elle démarre, ou ne répond pas encore.'],
      );
    }
    final a = d.autoOff;
    final now = DateTime.now();
    return _Section(
      title: 'Tour',
      state: 'allumée $via',
      on: true,
      lines: [
        if (d.uptimeS != null) 'Allumée depuis ${duration(d.uptimeS!)}',
        'Processeur ${pct(d.cpuPct)} · ${temp(d.cpuTempC)} · Carte graphique ${temp(d.gpuTempC)}',
        'Mémoire ${pct(d.memPct)} · Disque ${pct(d.diskPct)}',
        if (a != null)
          'Extinction automatique dans ${duration(a.remainingS)}'
              '${a.deadline == null ? '' : ' (${when(a.deadline!, now)})'}',
        if (a != null && a.cap != null) 'Plafond : ${when(a.cap!, now)}',
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
    final canPilot = t.detail != null;
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
                    child: const Text('Prolonger'),
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
