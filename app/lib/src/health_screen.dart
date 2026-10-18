// Santé du serveur et de la tour : services (avec redémarrage des services
// autorisés), disques (SMART), sécurité sur 24 h.
import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'format.dart';
import 'ssh_link.dart';

/// Un redémarrage peut prendre 45 s sur la machine, plus le relais vers la tour.
const _restartTimeout = Duration(seconds: 75);

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key, required this.link});

  final SshLink link;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  HealthReport? _report;
  String? _error;
  bool _loading = false;

  /// Service en cours de redémarrage (« serveur:cups », « tour:cups »), ou null.
  String? _restarting;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final reply = Reply.parse(await widget.link.run(Cmd.health));
      if (!reply.ok) throw LinkError(capitalize(reply.message));
      final report = HealthReport.fromReply(reply);
      if (!mounted) return;
      setState(() {
        _report = report;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restart(String service, {required bool tower}) async {
    final where = tower ? 'la tour' : 'le serveur';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('Redémarrer « $service » sur $where ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Redémarrer')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _restarting = '${tower ? 'tour' : 'serveur'}:$service');
    var message = '';
    try {
      final command = tower ? Cmd.towerRestart(service) : Cmd.restart(service);
      final reply = Reply.parse(await widget.link.run(command, timeout: _restartTimeout));
      if (reply.ok) {
        final r = RestartResult.fromJson(tower ? reply.tower : reply.data);
        message = r.pending
            ? '« $service » : le redémarrage continue (plus de 45 s).'
            : '« $service » redémarré : ${serviceStateText(r.state)}.';
      } else {
        // Refus ou échec côté tour : son message est le plus précis.
        final t = reply.tower;
        final towerMessage = t?['message'];
        message = capitalize(towerMessage is String ? towerMessage : reply.message);
      }
    } catch (e) {
      message = errorText(e);
    } finally {
      if (mounted) setState(() => _restarting = null);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Santé'),
        bottom: _loading || _restarting != null
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (r == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Lecture des disques et des journaux…')),
              ),
            if (r != null) ...[
              _MachineCard(
                title: 'Serveur',
                health: r.server,
                busy: _restarting != null,
                onRestart: (s) => unawaited(_restart(s, tower: false)),
              ),
              const SizedBox(height: 12),
              if (r.tower != null)
                _MachineCard(
                  title: 'Tour',
                  health: r.tower!,
                  busy: _restarting != null,
                  onRestart: (s) => unawaited(_restart(s, tower: true)),
                )
              else
                _Box(
                  title: 'Tour',
                  children: [Text(r.towerOnline ? 'Allumée, mais ne répond pas encore.' : 'Éteinte : pas de mesures.')],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MachineCard extends StatelessWidget {
  const _MachineCard({
    required this.title,
    required this.health,
    required this.busy,
    required this.onRestart,
  });

  final String title;
  final MachineHealth health;

  /// Un redémarrage est en cours : les boutons attendent.
  final bool busy;
  final void Function(String service) onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final disks = health.disks;
    final sec = health.security;
    return _Box(
      title: title,
      children: [
        const _Heading('Services'),
        if (health.services.isEmpty) const Text('Aucun service suivi (voir la configuration).'),
        for (final s in health.services)
          _Line(
            dot: s.active ? Colors.greenAccent : (s.state == 'failed' ? scheme.error : scheme.outline),
            text: '${s.name} : ${serviceStateText(s.state)}',
            trailing: s.restartable
                ? TextButton(
                    onPressed: busy ? null : () => onRestart(s.name),
                    child: const Text('Redémarrer'),
                  )
                : null,
          ),
        if (health.failedUnits > 0)
          Text(
            '${health.failedUnits} service(s) en échec sur la machine (systemctl --failed)',
            style: TextStyle(color: scheme.error),
          ),
        const SizedBox(height: 12),
        const _Heading('Disques'),
        if (disks == null)
          const Text('Indisponible : installer smartmontools et jq sur la machine.')
        else if (disks.isEmpty)
          const Text('Aucun disque suivi (voir la configuration).')
        else
          for (final d in disks) _DiskTile(d),
        const SizedBox(height: 12),
        const _Heading('Sécurité (24 h)'),
        if (sec == null)
          const Text('Indisponible.')
        else ...[
          Text('Connexions SSH : ${sec.logins} · tentatives refusées : ${sec.failures}'),
          Text(sec.firewallBlocks == null
              ? 'Pare-feu ufw absent'
              : 'Paquets bloqués par le pare-feu : ${sec.firewallBlocks}'),
          for (final l in sec.lastLogins)
            Text(
              '${l.time == null ? '?' : shortDate(l.time!)} · ${l.user} depuis ${l.from} (${l.method})',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ],
    );
  }
}

class _DiskTile extends StatelessWidget {
  const _DiskTile(this.disk);
  final DiskHealth disk;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = disk;
    final verdict = d.error != null
        ? 'illisible'
        : d.standby
            ? 'en veille (pas réveillé pour la lecture)'
            : switch (d.passed) {
                true => 'sain',
                false => 'PANNE ANNONCÉE PAR LE DISQUE',
                null => 'verdict inconnu',
              };
    final details = <String>[
      if (d.tempC != null) temp(d.tempC),
      if (d.powerOnHours != null) '${powerOnText(d.powerOnHours!)} de fonctionnement',
      if (d.usedPct != null) 'usure ${d.usedPct} %',
      if ((d.mediaErrors ?? 0) > 0) '${d.mediaErrors} erreur(s) de lecture',
      if ((d.reallocated ?? 0) > 0) '${d.reallocated} secteur(s) remplacé(s)',
      if ((d.pending ?? 0) > 0) '${d.pending} secteur(s) douteux',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line(
            dot: d.alarming ? scheme.error : (d.passed == true ? Colors.greenAccent : scheme.outline),
            text: '${d.model ?? d.device} : $verdict',
          ),
          if (details.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Text(details.join(' · '), style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.dot, required this.text, this.trailing});
  final Color dot;
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: dot),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
