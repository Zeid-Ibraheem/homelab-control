// Écran du terminal : empreinte (ou code) à chaque ouverture, puis session SSH
// vers le serveur ou vers la tour.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'lock.dart';
import 'remote_shell.dart';
import 'ssh_link.dart';
import 'store.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.data, required this.toTower, required this.onStoreChanged});

  final AppData data;
  final bool toTower;

  /// Appelé quand une clé de machine vient d'être enregistrée.
  final VoidCallback onStoreChanged;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _terminal = Terminal(maxLines: 10000);
  RemoteShell? _shell;
  bool _ctrl = false;

  // Touches absentes du clavier du téléphone : libellé et texte envoyé.
  static const _keys = <(String, String)>[
    ('Échap', '\x1b'),
    ('Tab', '\t'),
    ('↑', '\x1b[A'),
    ('↓', '\x1b[B'),
    ('←', '\x1b[D'),
    ('→', '\x1b[C'),
    ('|', '|'),
    ('~', '~'),
    ('/', '/'),
    ('-', '-'),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _shell?.close();
    super.dispose();
  }

  Future<void> _open() async {
    // Accès complet : on redemande l'empreinte à chaque ouverture.
    final refused = await AppLock.unlock();
    if (!mounted) return;
    if (refused != null) {
      _terminal.write('$refused\r\n');
      return;
    }
    _terminal.write('Connexion…\r\n');
    try {
      final shell = await RemoteShell.open(
        widget.data,
        toTower: widget.toTower,
        confirmTowerKey: _confirmTowerKey,
        width: _terminal.viewWidth,
        height: _terminal.viewHeight,
      );
      if (widget.toTower && widget.data.towerHostKey == null) widget.onStoreChanged();
      if (!mounted) {
        shell.close();
        return;
      }
      _shell = shell;
      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);
      _terminal.onOutput = (text) => shell.write(_withCtrl(text));
      _terminal.onResize = (width, height, pixelWidth, pixelHeight) => shell.resize(width, height);
      // La taille réelle de l'écran est connue maintenant : on la transmet.
      shell.resize(_terminal.viewWidth, _terminal.viewHeight);
      shell.output.listen(_terminal.write, onDone: () {
        if (mounted) _terminal.write('\r\n[session terminée]\r\n');
      });
    } catch (e) {
      if (mounted) _terminal.write('\r\n${errorText(e)}\r\n');
    }
  }

  /// Avec « Ctrl » enclenché, la lettre tapée devient la touche de contrôle
  /// correspondante (Ctrl+C = interrompre, Ctrl+D = fin…).
  String _withCtrl(String text) {
    if (!_ctrl || text.length != 1) return text;
    final c = text.toUpperCase().codeUnitAt(0);
    if (c < 64 || c > 95) return text;
    setState(() => _ctrl = false);
    return String.fromCharCode(c - 64);
  }

  void _send(String text) => _shell?.write(text);

  Future<bool> _confirmTowerKey(HostKeySeen seen) async {
    if (!mounted) return false;
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Vérifie la clé de la tour'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('La tour présente cette empreinte :'),
              const SizedBox(height: 8),
              SelectableText('${seen.type}\n${seen.display}', style: mono),
              const SizedBox(height: 16),
              const Text('Sur la tour, cette commande doit afficher exactement la même :'),
              const SizedBox(height: 8),
              SelectableText(seen.checkCommand, style: mono),
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.toTower ? 'Terminal : tour' : 'Terminal : serveur')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: TerminalView(_terminal, autofocus: true)),
            Material(
              color: scheme.surfaceContainerHigh,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  children: [
                    _KeyButton(
                      label: 'Ctrl',
                      selected: _ctrl,
                      onPressed: () => setState(() => _ctrl = !_ctrl),
                    ),
                    for (final k in _keys) _KeyButton(label: k.$1, onPressed: () => _send(k.$2)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.label, required this.onPressed, this.selected = false});

  final String label;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 40),
          backgroundColor: selected ? scheme.primaryContainer : null,
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}
