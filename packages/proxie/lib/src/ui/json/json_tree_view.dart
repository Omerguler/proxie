import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:proxie/src/json/json_commands.dart';
import 'package:proxie/src/json/json_document.dart';
import 'package:proxie/src/json/json_row.dart';
import 'package:proxie/src/json/json_schema.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/ui/common.dart';
import 'package:proxie/src/ui/json/json_row_tile.dart';
import 'package:proxie/src/ui/json/json_tree_controller.dart';
import 'package:proxie/src/ui/json/raw_text_view.dart';
import 'package:proxie/src/ui/json/value_editor.dart';
import 'package:proxie/src/ui/theme.dart';
import 'package:proxie/src/worker/worker.dart';

/// A virtualized, schema-aware tree of [controller]'s document: a search
/// bar over one [jsonRowExtent]-high row per visible node, built only for
/// the rows on screen. Edits are offered when the controller is editable.
class JsonTreeView extends StatefulWidget {
  /// Creates the tree of [controller]'s document.
  const JsonTreeView({
    required this.controller,
    super.key,
    this.actions = const [],
  });

  /// The document shown; owned by the caller.
  final JsonTreeController controller;

  /// Extra buttons at the end of the search bar.
  final List<Widget> actions;

  @override
  State<JsonTreeView> createState() => _JsonTreeViewState();
}

class _JsonTreeViewState extends State<JsonTreeView> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _query = TextEditingController();

  JsonTreeController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  @override
  void didUpdateWidget(JsonTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    final row = _c.takeReveal();
    if (row == null) return;
    // Jumps once the list has laid out with the new row count, unless the
    // row is already in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final top = row * jsonRowExtent;
      if (top >= position.pixels &&
          top + jsonRowExtent <= position.pixels + position.viewportDimension) {
        return;
      }
      // From the row count: the list's own extent may not have caught up
      // with a count that changed in this frame.
      final end = _c.visibleCount * jsonRowExtent - position.viewportDimension;
      _scroll.jumpTo(math.min(top, math.max(0, end)));
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_c.status) {
      case JsonTreeStatus.loading:
        // One worker round trip; nothing animates meanwhile.
        return const SizedBox.shrink();
      case JsonTreeStatus.failed:
        return InlineRetry(
          message: _c.closed
              ? 'This JSON document was closed'
              : "Couldn't show this JSON",
          onRetry: () => unawaited(_c.retry()),
        );
      case JsonTreeStatus.invalid:
        return Center(child: Text(_c.parseError ?? 'Invalid JSON'));
      case JsonTreeStatus.ready:
        break;
    }
    final editError = _c.editError;
    final root = _c.root;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchBar(context),
        if (editError != null)
          _EditErrorBar(message: editError, onDismiss: _c.clearEditError),
        const Divider(height: 1),
        if (root != null) ...[_rootHeader(root), const Divider(height: 1)],
        Expanded(
          child: ListView.builder(
            key: const ValueKey('proxie-json-tree'),
            controller: _scroll,
            itemExtent: jsonRowExtent,
            itemCount: _c.visibleCount,
            itemBuilder: _row,
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, int i) {
    final row = _c.rowAt(i);
    if (row == null) return const SizedBox.shrink();
    final schema = row.kind == JsonKind.array ? _c.schemaOf(row.nodeId) : null;
    return JsonRowTile(
      key: ValueKey(row.nodeId),
      row: row,
      editable: _c.editable,
      schema: schema,
      highlighted: row.nodeId == _c.currentMatch,
      onToggle: () => unawaited(_c.toggle(row.nodeId)),
      onAddMissingKey: (key) =>
          unawaited(_c.apply(AddMissingKey(row.nodeId, key))),
      onAction: (a) => unawaited(_onAction(row, schema, a)),
    );
  }

  // The top-level object or array, which has no row of its own: its
  // summary, an array's schema, and (when editable) the root's edits.
  Widget _rootHeader(JsonRow root) {
    final schema = root.kind == JsonKind.array ? _c.schemaOf(0) : null;
    return JsonRowTile(
      key: const ValueKey('proxie-json-root'),
      row: root,
      header: true,
      editable: _c.editable,
      schema: schema,
      onAction: (a) => unawaited(_onAction(root, schema, a)),
    );
  }

  Widget _searchBar(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _c.matches;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('proxie-json-search'),
              controller: _query,
              textInputAction: TextInputAction.search,
              decoration: searchDecoration('Search keys and values'),
              onSubmitted: (q) => unawaited(_c.search(q)),
            ),
          ),
          if (_c.query.isNotEmpty)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  matches.isEmpty
                      ? 'No matches'
                      : '${_c.matchIndex + 1}/${matches.length}'
                            '${_c.matchesCapped ? '+' : ''}',
                  style: proxieMono(
                    theme.textTheme.bodySmall,
                  )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          if (matches.length > 1) ...[
            IconButton(
              tooltip: 'Previous match',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: () => unawaited(_c.previousMatch()),
            ),
            IconButton(
              tooltip: 'Next match',
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => unawaited(_c.nextMatch()),
            ),
          ],
          if (_c.editable && _c.edited)
            TextButton(
              onPressed: () => unawaited(_c.revert()),
              child: const Text('Revert'),
            ),
          ...widget.actions,
        ],
      ),
    );
  }

  Future<void> _onAction(
    JsonRow row,
    ArraySchema? schema,
    JsonRowAction action,
  ) async {
    final c = _c;
    final id = row.nodeId;
    switch (action) {
      case JsonRowAction.editValue:
        final text = await c.scalarText(id);
        if (text == null || !mounted) return;
        final input = await showValueEditor(
          context,
          title: 'Edit value',
          initialKind: row.kind,
          initialText: row.kind == JsonKind.nullValue ? '' : text,
        );
        if (input != null) await c.apply(SetValue(id, input.value));
      case JsonRowAction.rename:
        final key = await showKeyEditor(
          context,
          title: 'Rename key',
          initial: row.key ?? '',
        );
        if (key != null) await c.apply(RenameKey(id, key));
      case JsonRowAction.delete:
        await c.apply(DeleteNode(id));
      case JsonRowAction.duplicate:
        await c.apply(DuplicateItem(id));
      case JsonRowAction.addKey:
        final input = await showValueEditor(
          context,
          title: 'Add key',
          askKey: true,
        );
        if (input != null) await c.apply(AddKey(id, input.key!, input.value));
      case JsonRowAction.addKeyToAll:
        final input = await showValueEditor(
          context,
          title: 'Add key to all',
          askKey: true,
        );
        if (input != null) {
          await c.apply(AddKeyToAll(id, input.key!, input.value));
        }
      case JsonRowAction.removeKeyFromAll:
        if (schema == null) return;
        final key = await showKeyPicker(
          context,
          title: 'Remove key from all',
          keys: [for (final f in schema.fields) f.key],
        );
        if (key != null) await c.apply(RemoveKeyFromAll(id, key));
      case JsonRowAction.newItemFromSchema:
        await c.apply(NewItemFromSchema(id));
    }
  }
}

/// The JSON [body] of call [callId]: its tree (owning the
/// [JsonTreeController]), or indented raw text at the toggle of a button.
/// A body that is not JSON shows why, over its raw text.
class JsonBodyView extends StatefulWidget {
  /// Creates the view of the [which] (`'request'` or `'response'`) body.
  const JsonBodyView({
    required this.worker,
    required this.callId,
    required this.which,
    required this.body,
    super.key,
    this.editable = false,
    this.scope = OpenJson.viewScope,
  });

  /// Where the document is opened.
  final ProxieWorker worker;

  /// The call whose body is shown.
  final String callId;

  /// `'request'` or `'response'`.
  final String which;

  /// The body, for the raw view; a body with other bytes (a pending
  /// call's response arriving, an edited response) opens the document
  /// again, while a reload of the same bytes keeps the tree as it is.
  final ProxieBody body;

  /// Whether the tree offers edits.
  final bool editable;

  /// Which copy of the document is open; see [OpenJson.scope].
  final String scope;

  @override
  State<JsonBodyView> createState() => _JsonBodyViewState();
}

class _JsonBodyViewState extends State<JsonBodyView> {
  late JsonTreeController _controller = _create();
  late JsonTreeStatus _status = _controller.status;
  bool _raw = false;
  // Whether the raw view was opened once; it then stays alive offstage.
  bool _rawShown = false;

  JsonTreeController _create() => JsonTreeController(
    widget.worker,
    widget.callId,
    widget.which,
    editable: widget.editable,
    scope: widget.scope,
  )..addListener(_changed);

  // The tree rebuilds itself; this view only swaps in the invalid state.
  void _changed() {
    if (_controller.status == _status) return;
    setState(() => _status = _controller.status);
  }

  @override
  void didUpdateWidget(JsonBodyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final o = oldWidget;
    final w = widget;
    if (o.worker != w.worker ||
        o.callId != w.callId ||
        o.which != w.which ||
        o.editable != w.editable ||
        o.scope != w.scope ||
        !sameBytes(o.body.bytes, w.body.bytes) ||
        o.body.truncated != w.body.truncated) {
      // The tree lets go of the old controller in this frame.
      final old = _controller..removeListener(_changed);
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      _controller = _create();
      _status = _controller.status;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _rawText({required bool pretty}) => RawTextView(
    worker: widget.worker,
    bytes: widget.body.bytes,
    prettyJson: pretty,
    undecodable: (_) => const Center(child: Text('Not valid UTF-8 text')),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_controller.status == JsonTreeStatus.invalid) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColoredBox(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                _controller.parseError ?? 'Invalid JSON',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
          Expanded(child: _rawText(pretty: false)),
        ],
      );
    }
    // Both views stay alive, so switching keeps the tree's scroll and
    // search and does not split the raw text again.
    final tree = JsonTreeView(
      key: ObjectKey(_controller),
      controller: _controller,
      actions: [
        IconButton(
          tooltip: 'Raw text',
          icon: const Icon(Icons.notes),
          onPressed: () => setState(() => _raw = _rawShown = true),
        ),
      ],
    );
    final raw = !_rawShown
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Tree view',
                  icon: const Icon(Icons.account_tree_outlined),
                  onPressed: () => setState(() => _raw = false),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _rawText(pretty: true)),
            ],
          );
    return IndexedStack(
      index: _raw ? 1 : 0,
      sizing: StackFit.expand,
      children: [tree, raw],
    );
  }
}

class _EditErrorBar extends StatelessWidget {
  const _EditErrorBar({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
