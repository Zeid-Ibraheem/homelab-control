// Réglages : clé de l'application, serveur, et remise à zéro.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ssh_link.dart';
import 'store.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.data, required this.onReset});

  final AppData data;
  final Future<void> Function({required bool all}) onReset;

  Future<void> _reset(BuildContext context, {required bool all}) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(all ? 'Tout effacer ?' : 'Changer de serveur ?'),
        content: Text(all
            ? "La clé de l'application sera détruite : il faudra en créer une "
                'nouvelle et l\'autoriser de nouveau sur le serveur. Pense à retirer '
                "l'ancienne de son authorized_keys."
            : "L'adresse du serveur et sa clé vérifiée seront oubliées. La clé de "
                "l'application est conservée."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(all ? 'Tout effacer' : 'Oublier le serveur'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    Navigator.pop(context);
    await onReset(all: all);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text("Clé de l'application", style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(data.publicLine ?? '—', style: mono),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: data.publicLine ?? ''));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Clé publique copiée')));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copier la clé publique'),
            ),
          ),
          const SizedBox(height: 24),
          Text('Serveur', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('${data.user}@${data.host ?? '—'}, port ${data.port}'),
          const SizedBox(height: 4),
          Text('Clé du serveur vérifiée :', style: theme.textTheme.bodySmall),
          SelectableText(
            data.hostKey == null ? '—' : HostKeySeen.describePin(data.hostKey!),
            style: mono,
          ),
          const SizedBox(height: 32),
          OutlinedButton(
            onPressed: () => _reset(context, all: false),
            child: const Text('Changer de serveur'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: () => _reset(context, all: true),
            child: const Text('Tout effacer (clé et réglages)'),
          ),
          const SizedBox(height: 24),
          Text(
            "L'application ne parle qu'au serveur, en SSH, avec sa propre clé. Elle se "
            'verrouille au démarrage et après une minute en arrière-plan.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
