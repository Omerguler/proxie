import 'package:flutter/material.dart';

import 'package:proxie/src/json/json_row.dart';
import 'package:proxie/src/json/json_schema.dart';
import 'package:proxie/src/ui/theme.dart';

/// Height of one tree row.
const double jsonRowExtent = 28;

/// Indentation per depth level.
const double jsonIndent = 14;

/// An edit offered in a row's menu.
enum JsonRowAction {
  /// Replace a scalar's value.
  editValue('Edit value'),

  /// Rename an object member.
  rename('Rename key'),

  /// Remove the node.
  delete('Delete'),

  /// Copy an array item after itself.
  duplicate('Duplicate'),

  /// Add a member to an object.
  addKey('Add key'),

  /// Add a member to every object of an array that lacks it.
  addKeyToAll('Add key to all'),

  /// Remove a member from every object of an array.
  removeKeyFromAll('Remove key from all'),

  /// Append an object shaped like the array's schema.
  newItemFromSchema('New item from schema');

  const JsonRowAction(this.label);

  /// The menu label.
  final String label;
}

/// The edits that apply to [row]; [schema] is that of an array row (null
/// when it holds no objects or is not known yet).
List<JsonRowAction> jsonRowActions(JsonRow row, ArraySchema? schema) {
  final container = row.kind == JsonKind.object || row.kind == JsonKind.array;
  return [
    if (!container) JsonRowAction.editValue,
    if (row.key != null) JsonRowAction.rename,
    if (row.nodeId != 0) JsonRowAction.delete,
    if (row.index != null) JsonRowAction.duplicate,
    if (row.kind == JsonKind.object) JsonRowAction.addKey,
    if (row.kind == JsonKind.array && schema != null) ...[
      JsonRowAction.addKeyToAll,
      JsonRowAction.removeKeyFromAll,
      JsonRowAction.newItemFromSchema,
    ],
  ];
}

/// One row of a JSON tree: indented by depth, the member name or index,
/// the value preview colored by kind, the schema of an array, and (when
/// [editable]) `+ key` chips for missing members and an edit menu, also
/// opened by a long press.
class JsonRowTile extends StatefulWidget {
  /// Creates the tile of [row].
  const JsonRowTile({
    required this.row,
    required this.editable,
    super.key,
    this.schema,
    this.highlighted = false,
    this.onToggle,
    this.onAddMissingKey,
    this.onAction,
  });

  /// The row shown.
  final JsonRow row;

  /// Whether edits are offered.
  final bool editable;

  /// The schema of an array row.
  final ArraySchema? schema;

  /// Whether this row is the revealed search match.
  final bool highlighted;

  /// Called when a container row is tapped.
  final VoidCallback? onToggle;

  /// Called with the member name when a `+ key` chip is tapped.
  final ValueChanged<String>? onAddMissingKey;

  /// Called with the chosen menu edit.
  final ValueChanged<JsonRowAction>? onAction;

  @override
  State<JsonRowTile> createState() => _JsonRowTileState();
}

class _JsonRowTileState extends State<JsonRowTile> {
  final _menu = GlobalKey<PopupMenuButtonState<JsonRowAction>>();

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final theme = Theme.of(context);
    final colors = ProxieColors.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final container = row.kind == JsonKind.object || row.kind == JsonKind.array;
    final valueColor = switch (row.kind) {
      JsonKind.string => colors.jsonString,
      JsonKind.number ||
      JsonKind.boolean ||
      JsonKind.nullValue => colors.jsonNumber,
      JsonKind.object || JsonKind.array => muted,
    };
    final actions = widget.editable
        ? jsonRowActions(row, widget.schema)
        : const <JsonRowAction>[];
    final schema = widget.schema;
    final key = row.key;
    final index = row.index;
    final text = Text.rich(
      TextSpan(
        children: [
          if (key != null) ...[
            TextSpan(
              text: key,
              style: TextStyle(color: colors.jsonKey),
            ),
            const TextSpan(text: ': '),
          ] else if (index != null)
            TextSpan(
              text: '[$index]: ',
              style: TextStyle(color: muted),
            ),
          TextSpan(
            text: row.preview,
            style: TextStyle(color: valueColor),
          ),
          if (row.kind == JsonKind.array && schema != null)
            TextSpan(
              text: '  ${schema.describe()}',
              style: TextStyle(color: muted),
            ),
          if (widget.editable)
            for (final k in row.missingKeys)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _MissingKeyChip(
                  label: k,
                  onTap: () => widget.onAddMissingKey?.call(k),
                ),
              ),
        ],
      ),
      style: style,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
    return Material(
      color: widget.highlighted
          ? theme.colorScheme.primary.withValues(alpha: 0.18)
          : Colors.transparent,
      child: InkWell(
        onTap: container ? widget.onToggle : null,
        onLongPress: actions.isEmpty
            ? null
            : () => _menu.currentState?.showButtonMenu(),
        child: SizedBox(
          height: jsonRowExtent,
          child: Row(
            children: [
              SizedBox(width: 4 + jsonIndent * row.depth),
              SizedBox(
                width: 18,
                child: container
                    ? Icon(
                        row.expanded
                            ? Icons.arrow_drop_down
                            : Icons.arrow_right,
                        size: 18,
                        color: muted,
                      )
                    : null,
              ),
              Expanded(child: text),
              if (actions.isNotEmpty)
                PopupMenuButton<JsonRowAction>(
                  key: _menu,
                  tooltip: 'Edit',
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  constraints: const BoxConstraints(minWidth: 180),
                  icon: Icon(Icons.more_vert, color: muted),
                  style: const ButtonStyle(
                    minimumSize: WidgetStatePropertyAll(Size(28, 28)),
                    fixedSize: WidgetStatePropertyAll(Size(28, 28)),
                  ),
                  onSelected: widget.onAction,
                  itemBuilder: (context) => [
                    for (final a in actions)
                      PopupMenuItem(value: a, child: Text(a.label)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MissingKeyChip extends StatelessWidget {
  const _MissingKeyChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: theme.colorScheme.surfaceContainer,
        shape: StadiumBorder(
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            child: Text(
              '+ $label',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
