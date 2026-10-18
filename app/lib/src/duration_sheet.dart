// Choix d'une durée au curseur, par pas de 5 minutes, borné par le plafond.
import 'package:flutter/material.dart';

import 'format.dart';

/// Ouvre la feuille de choix ; renvoie un nombre de minutes, ou null si annulé.
/// [maxMinutes] : durée la plus longue autorisée (le plafond) ; en dessous de
/// [step], seul [emptyMessage] est affiché.
Future<int?> chooseDuration(
  BuildContext context, {
  required String title,
  required int maxMinutes,
  required String Function(int minutes) preview,
  required String emptyMessage,
  int step = 5,
  List<int> quick = const [15, 30, 60, 120],
}) {
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => _DurationSheet(
      title: title,
      maxMinutes: maxMinutes - maxMinutes % step,
      preview: preview,
      emptyMessage: emptyMessage,
      step: step,
      quick: quick,
    ),
  );
}

class _DurationSheet extends StatefulWidget {
  const _DurationSheet({
    required this.title,
    required this.maxMinutes,
    required this.preview,
    required this.emptyMessage,
    required this.step,
    required this.quick,
  });

  final String title;
  final int maxMinutes;
  final String Function(int minutes) preview;
  final String emptyMessage;
  final int step;
  final List<int> quick;

  @override
  State<_DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<_DurationSheet> {
  // Une heure par défaut, ou moins si le plafond est plus proche.
  late int _minutes = widget.maxMinutes < 60 ? widget.maxMinutes : 60;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = widget.maxMinutes;
    final step = widget.step;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            if (max < step)
              Text(widget.emptyMessage)
            else ...[
              Text(
                duration(_minutes * 60),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(
                widget.preview(_minutes),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (max > step)
                Slider(
                  value: _minutes.toDouble(),
                  min: step.toDouble(),
                  max: max.toDouble(),
                  divisions: max ~/ step - 1,
                  label: duration(_minutes * 60),
                  onChanged: (v) => setState(() => _minutes = v.round()),
                ),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final q in widget.quick)
                    if (q >= step && q <= max)
                      ActionChip(
                        label: Text(duration(q * 60)),
                        onPressed: () => setState(() => _minutes = q),
                      ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context, _minutes),
                child: const Text('Valider'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
