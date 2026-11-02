import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'package:proxie/src/core/presets.dart';
import 'package:proxie/src/ui/rules/rules_controller.dart';

/// Shows the built-in presets and the custom ones [rules] stores, in a
/// bottom sheet on the nearest navigator; completes with the one tapped,
/// or null.
Future<ResponsePreset?> showPresetPicker(
  BuildContext context,
  RulesController rules,
) => showModalBottomSheet<ResponsePreset>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => FractionallySizedBox(
    heightFactor: 0.75,
    child: PresetPicker(rules: rules),
  ),
);

/// The preset list: built-in presets, then the saved custom ones. Tapping
/// one pops it from the enclosing route.
class PresetPicker extends StatefulWidget {
  /// Creates the list of [builtInPresets] and [rules]' custom presets.
  const PresetPicker({required this.rules, super.key});

  /// Loads the custom presets.
  final RulesController rules;

  @override
  State<PresetPicker> createState() => _PresetPickerState();
}

class _PresetPickerState extends State<PresetPicker> {
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await widget.rules.loadPresets();
    } on Object catch (e, st) {
      // The built-in presets still work without the saved ones.
      developer.log(
        'Proxie could not load the saved presets',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
      if (mounted) setState(() => _failed = true);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final custom = widget.rules.customPresets;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
    Widget tile(ResponsePreset p) => ListTile(
      key: ValueKey('preset-${p.id}'),
      title: Text(p.label),
      onTap: () => Navigator.of(context).pop(p),
    );
    return ListView(
      children: [
        heading('Built-in'),
        for (final p in builtInPresets) tile(p),
        heading('Saved'),
        if (_failed)
          ListTile(
            title: const Text("Couldn't load saved presets"),
            trailing: TextButton(
              onPressed: () => unawaited(_load()),
              child: const Text('Retry'),
            ),
          )
        else if (!_loading && custom.isEmpty)
          const ListTile(title: Text('No saved presets yet'), enabled: false),
        for (final p in custom) tile(p),
      ],
    );
  }
}
