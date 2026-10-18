// Journal des actions du serveur : réveils, extinctions, commandes refusées…
import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'format.dart';
import 'ssh_link.dart';

class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key, required this.link});

  final SshLink link;

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  List<JournalEntry>? _entries;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final reply = Reply.parse(await widget.link.run(Cmd.log(100)));
      if (!reply.ok) throw LinkError(capitalize(reply.message));
      final entries = JournalEntry.listFrom(reply);
      if (mounted) {
        setState(() {
          _entries = entries;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Journal du serveur')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (entries == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (entries != null && entries.isEmpty)
              const ListTile(title: Text('Aucune action enregistrée.')),
            if (entries != null)
              for (final e in entries)
                ListTile(
                  dense: true,
                  leading: Icon(
                    e.result == 'refused' ? Icons.block : Icons.check_circle_outline,
                    color: e.result == 'refused' ? theme.colorScheme.error : null,
                  ),
                  title: Text('${e.action} → ${e.result}'),
                  subtitle: Text(
                    '${e.time == null ? '?' : shortDate(e.time!)} · ${e.via} · ${e.from}',
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
