import 'dart:async';

import 'package:flutter/material.dart';

import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/ui/rules/rule_editor.dart';
import 'package:proxie/src/ui/rules/rules_controller.dart';
import 'package:proxie/src/ui/theme.dart';

/// The rules of the nearest [RulesScope] in matching order: drag to
/// reorder, switch on and off, delete (with Undo), tap to edit, and add a
/// Map Local rule. Every change applies at once and is stored.
class RulesScreen extends StatelessWidget {
  /// Creates the rules screen.
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final rules = RulesController.maybeOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Rules')),
      floatingActionButton: rules == null
          ? null
          : FloatingActionButton(
              tooltip: 'Add rule',
              onPressed: () =>
                  unawaited(openRuleEditor(context, kind: RuleKind.mapLocal)),
              child: const Icon(Icons.add),
            ),
      body: rules == null
          ? const _Empty('Rules are unavailable')
          : _RulesList(rules: rules),
    );
  }
}

class _RulesList extends StatelessWidget {
  const _RulesList({required this.rules});

  final RulesController rules;

  void _delete(BuildContext context, int index, ProxieRule rule) {
    unawaited(rules.delete(rule.id));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted ${rule.name}'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(rules.insert(index, rule)),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final list = rules.rules;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rules.saveError != null)
          ColoredBox(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "Rules apply but couldn't be saved",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(rules.retrySave()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: list.isEmpty
              ? const _Empty('No rules yet')
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: list.length,
                  onReorderItem: (from, to) =>
                      unawaited(rules.reorder(from, to)),
                  itemBuilder: (context, i) => _RuleTile(
                    key: ValueKey(list[i].id),
                    rule: list[i],
                    index: i,
                    onEnabled: (v) =>
                        unawaited(rules.setEnabled(list[i].id, enabled: v)),
                    onDelete: () => _delete(context, i, list[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.index,
    required this.onEnabled,
    required this.onDelete,
    super.key,
  });

  final ProxieRule rule;
  final int index;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onDelete;

  (IconData, String) get _kind => switch (rule.kind) {
    RuleKind.mapLocal => (Icons.file_download_outlined, 'Map Local'),
    RuleKind.breakpoint => (
      switch (rule.phase) {
        BreakpointPhase.request => Icons.north_east,
        BreakpointPhase.response => Icons.south_west,
        BreakpointPhase.both => Icons.pause_circle_outline,
      },
      'Breakpoint (${rule.phase.name})',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (icon, label) = _kind;
    final pattern = rule.matcher.isRegex
        ? '${rule.matcher.pattern} (regex)'
        : rule.matcher.pattern;
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            key: ValueKey('rule-drag-${rule.id}'),
            index: index,
            child: const Icon(Icons.drag_handle),
          ),
          const SizedBox(width: 12),
          Tooltip(message: label, child: Icon(icon)),
        ],
      ),
      title: Text(rule.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${rule.method ?? 'Any'} $pattern',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: proxieMono(
          Theme.of(context).textTheme.bodySmall,
        )?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      onTap: () => unawaited(openRuleEditor(context, existing: rule)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: 'Enable rule ${rule.name}',
            child: Switch(value: rule.enabled, onChanged: onEnabled),
          ),
          IconButton(
            tooltip: 'Delete rule',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        text,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
