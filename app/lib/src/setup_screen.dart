// Première configuration : clé de l'application, puis serveur (adresse et
// vérification de sa clé).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'app_key.dart';
import 'format.dart';
import 'ssh_link.dart';
import 'store.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.initial, required this.onDone});

  final AppData initial;
  final ValueChanged<AppData> onDone;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late AppData _data = widget.initial;
  late final _host = TextEditingController(text: widget.initial.host ?? '');
  late final _port = TextEditingController(text: '${widget.initial.port}');
  late final _user = TextEditingController(text: widget.initial.user);
  bool _busy = false;
  String? _error;

  static final _userPattern = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$');
  static final _hostPattern = RegExp(r'^[A-Za-z0-9.:-]{1,253}$');

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    super.dispose();
  }

  Future<void> _createKey() async {
    setState(() => _busy = true);
    try {
      final key = AppKey.generate();
      await Store.saveKey(pem: key.privatePem, publicLine: key.publicLine);
      if (!mounted) return;
      setState(() => _data = AppData(
            keyPem: key.privatePem,
            publicLine: key.publicLine,
            host: _data.host,
            port: _data.port,
            user: _data.user,
          ));
    } catch (e) {
      if (mounted) setState(() => _error = 'Création de la clé impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copiée')));
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final user = _user.text.trim();
    if (!_hostPattern.hasMatch(host)) {
      setState(() => _error = 'Adresse du serveur invalide.');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Port invalide (1 à 65535).');
      return;
    }
    if (!_userPattern.hasMatch(user)) {
      setState(() => _error = 'Compte invalide.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final probe = SshLink(host: host, port: port, user: user, keyPem: _data.keyPem!);
      final seen = await probe.probeHostKey();
      if (!mounted) return;
      final same = await _confirmHostKey(seen);
      if (!same || !mounted) return;

      final link = SshLink(host: host, port: port, user: user, keyPem: _data.keyPem!, pinnedHostKey: seen.pin);
      final reply = Reply.parse(await link.run(Cmd.version));
      if (!reply.ok) throw LinkError(capitalize(reply.message));
      await Store.saveServer(host: host, port: port, user: user, hostKey: seen.pin);
      if (!mounted) return;
      widget.onDone(AppData(
        keyPem: _data.keyPem,
        publicLine: _data.publicLine,
        host: host,
        port: port,
        user: user,
        hostKey: seen.pin,
      ));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmHostKey(HostKeySeen seen) async {
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Vérifie la clé du serveur'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Le serveur présente cette empreinte :'),
              const SizedBox(height: 8),
              SelectableText('${seen.type}\n${seen.display}', style: mono),
              const SizedBox(height: 16),
              const Text('Sur le serveur, cette commande doit afficher exactement la même :'),
              const SizedBox(height: 8),
              SelectableText(seen.checkCommand, style: mono),
              const SizedBox(height: 16),
              const Text("Si elles diffèrent, quelqu'un s'interpose : n'accepte pas."),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Identique')),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Scaffold(
      appBar: AppBar(title: const Text('Configuration')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text("1. Clé de l'application", style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!_data.hasKey) ...[
            const Text(
                "L'application crée sa propre clé SSH. La partie privée reste dans le "
                'stockage chiffré du téléphone ; seule la partie publique est montrée.'),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : _createKey, child: const Text('Créer la clé')),
          ] else ...[
            const Text('Sur le serveur, autorise cette clé avec la commande :'),
            const SizedBox(height: 8),
            SelectableText(_data.addKeyCommand, style: mono),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _copy(_data.addKeyCommand, 'Commande'),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copier la commande'),
                ),
                TextButton(
                  onPressed: () => _copy(_data.publicLine!, 'Clé publique'),
                  child: const Text('Copier la clé seule'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 32),
          Text('2. Serveur', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _host,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Adresse du serveur',
              helperText: 'Son nom sur le VPN, ou son adresse 100.x.y.z',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _user,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Compte'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || !_data.hasKey ? null : _connect,
            child: const Text('Se connecter'),
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
