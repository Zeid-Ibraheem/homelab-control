// Réglages : clés de l'application, serveur, terminal, et remise à zéro.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_key.dart';
import 'ssh_link.dart';
import 'store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.data,
    required this.onReset,
    required this.onStoreChanged,
  });

  final AppData data;
  final Future<void> Function({required bool all}) onReset;
  final VoidCallback onStoreChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String? _termPublicLine = widget.data.termPublicLine;
  late final _serverUser = TextEditingController(text: widget.data.serverUser ?? '');
  late final _towerUser = TextEditingController(text: widget.data.towerUser ?? '');
  late final _towerAddress = TextEditingController(text: widget.data.towerAddress ?? '');
  String? _message;

  static final _userPattern = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$');

  @override
  void dispose() {
    _serverUser.dispose();
    _towerUser.dispose();
    _towerAddress.dispose();
    super.dispose();
  }

  static String _serverTermCommand(String line) =>
      'sudo ~/homelab-control/server/install.sh add-terminal-key "$line"';
  static String _towerTermCommand(String line) => 'sudo tower/install.sh add-terminal-key "$line"';

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copiée')));
  }

  Future<void> _createTermKey() async {
    final key = AppKey.generate(comment: AppKey.terminalComment);
    await Store.saveTermKey(pem: key.privatePem, publicLine: key.publicLine);
    widget.onStoreChanged();
    if (mounted) setState(() => _termPublicLine = key.publicLine);
  }

  Future<void> _saveTerminal() async {
    final serverUser = _serverUser.text.trim();
    final towerUser = _towerUser.text.trim();
    final typed = _towerAddress.text.trim();
    for (final u in [serverUser, towerUser]) {
      if (u.isNotEmpty && !_userPattern.hasMatch(u)) {
        setState(() => _message = 'Compte invalide : « $u ».');
        return;
      }
    }
    final addresses = typed.isEmpty ? const <String>[] : parseAddresses(typed);
    if (addresses == null) {
      setState(() => _message = 'Adresses de la tour invalides (deux au plus, séparées par un espace).');
      return;
    }
    final address = addresses.join(' ');
    _towerAddress.text = address;
    await Store.saveTerminal(
      serverUser: serverUser,
      towerUser: towerUser,
      towerAddress: address,
      towerAddressChanged: address != (widget.data.towerAddress ?? ''),
    );
    widget.onStoreChanged();
    if (mounted) setState(() => _message = 'Enregistré.');
  }

  Future<void> _reset({required bool all}) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(all ? 'Tout effacer ?' : 'Changer de serveur ?'),
        content: Text(all
            ? "Les clés de l'application seront détruites : il faudra en créer de "
                "nouvelles et les autoriser de nouveau. Pense à retirer les anciennes "
                'des fichiers authorized_keys.'
            : "L'adresse du serveur et sa clé vérifiée seront oubliées. Les clés de "
                "l'application sont conservées."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(all ? 'Tout effacer' : 'Oublier le serveur'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    Navigator.pop(context);
    await widget.onReset(all: all);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final termLine = _termPublicLine;
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text("Clé « actions » de l'application", style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(data.publicLine ?? '—', style: mono),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _copy(data.addKeyCommand, 'Commande add-key'),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copier la commande add-key'),
            ),
          ),
          const SizedBox(height: 16),
          Text('Serveur', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('${data.user}@${data.host ?? '—'}, port ${data.port}'),
          const SizedBox(height: 4),
          Text('Clé du serveur vérifiée :', style: theme.textTheme.bodySmall),
          SelectableText(data.hostKey == null ? '—' : HostKeySeen.describePin(data.hostKey!), style: mono),
          const Divider(height: 40),
          Text('Terminal', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
              "Une clé séparée, avec un accès complet à ton compte : l'empreinte (ou le "
              'code) est redemandée à chaque ouverture du terminal. La tour est jointe en '
              'passant par le serveur.'),
          const SizedBox(height: 8),
          if (termLine == null)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: _createTermKey, child: const Text('Créer la clé du terminal')),
            )
          else ...[
            // Les adresses d'origine (from=) sont prises dans la configuration de
            // chaque machine : le téléphone pour le serveur, le serveur pour la tour.
            const Text('Autorise-la sur ton compte du serveur :'),
            const SizedBox(height: 4),
            SelectableText(_serverTermCommand(termLine), style: mono),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _copy(_serverTermCommand(termLine), 'Commande pour le serveur'),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copier la commande pour le serveur'),
              ),
            ),
            const Text('Puis sur ton compte de la tour, depuis le dossier du dépôt :'),
            const SizedBox(height: 4),
            SelectableText(_towerTermCommand(termLine), style: mono),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _copy(_towerTermCommand(termLine), 'Commande pour la tour'),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copier la commande pour la tour'),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _copy(termLine, 'Clé du terminal'),
                child: const Text('Copier la clé seule'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _serverUser,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Ton compte sur le serveur'),
          ),
          TextField(
            controller: _towerUser,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Ton compte sur la tour'),
          ),
          TextField(
            controller: _towerAddress,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Adresses de la tour, vues du serveur',
              helperText: 'Câble puis VPN, séparées par un espace (ex. : 10.0.0.2 ma-tour)',
            ),
          ),
          if (data.towerHostKey != null) ...[
            const SizedBox(height: 8),
            Text('Clé de la tour vérifiée :', style: theme.textTheme.bodySmall),
            SelectableText(HostKeySeen.describePin(data.towerHostKey!), style: mono),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonal(onPressed: _saveTerminal, child: const Text('Enregistrer')),
              const SizedBox(width: 12),
              if (_message != null) Expanded(child: Text(_message!)),
            ],
          ),
          const Divider(height: 40),
          OutlinedButton(
            onPressed: () => _reset(all: false),
            child: const Text('Changer de serveur'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: () => _reset(all: true),
            child: const Text('Tout effacer (clés et réglages)'),
          ),
          const SizedBox(height: 24),
          Text(
            "L'application ne parle qu'au serveur, en SSH, avec ses propres clés. Elle se "
            'verrouille au démarrage et après une minute en arrière-plan.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
