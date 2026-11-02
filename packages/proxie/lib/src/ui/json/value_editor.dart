import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:proxie/src/json/json_document.dart';
import 'package:proxie/src/json/json_row.dart';

/// What a value editor returns: the member name (when one was asked for)
/// and the JSON value, as [JsonEdit] values take it.
typedef JsonValueInput = ({String? key, Object? value});

final _numberGrammar = RegExp(
  r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$',
);

/// Reads [text] as a value of [kind]: a string as typed, a number by the
/// JSON grammar (kept exactly as a [JsonNumber]), `true` / `false`, null,
/// or JSON text for an object or array. Returns the value, or an error
/// message.
({Object? value, String? error}) parseJsonValue(JsonKind kind, String text) {
  switch (kind) {
    case JsonKind.string:
      return (value: text, error: null);
    case JsonKind.number:
      final t = text.trim();
      if (!_numberGrammar.hasMatch(t)) {
        return (value: null, error: 'Not a JSON number');
      }
      return (value: JsonNumber(t), error: null);
    case JsonKind.boolean:
      final t = text.trim();
      if (t != 'true' && t != 'false') {
        return (value: null, error: 'Must be true or false');
      }
      return (value: t == 'true', error: null);
    case JsonKind.nullValue:
      return (value: null, error: null);
    case JsonKind.object:
    case JsonKind.array:
      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException catch (e) {
        return (value: null, error: 'Invalid JSON: ${e.message}');
      }
      final ok = kind == JsonKind.object ? decoded is Map : decoded is List;
      if (!ok) {
        return (
          value: null,
          error: kind == JsonKind.object ? 'Not an object' : 'Not an array',
        );
      }
      return (value: decoded, error: null);
  }
}

String _kindLabel(JsonKind kind) => switch (kind) {
  JsonKind.object => 'Object',
  JsonKind.array => 'Array',
  JsonKind.string => 'String',
  JsonKind.number => 'Number',
  JsonKind.boolean => 'Boolean',
  JsonKind.nullValue => 'Null',
};

/// Asks for a JSON value (and a member name when [askKey]); null when
/// cancelled.
Future<JsonValueInput?> showValueEditor(
  BuildContext context, {
  required String title,
  bool askKey = false,
  String initialKey = '',
  JsonKind initialKind = JsonKind.string,
  String initialText = '',
}) => showDialog<JsonValueInput>(
  context: context,
  builder: (context) => ValueEditorDialog(
    title: title,
    askKey: askKey,
    initialKey: initialKey,
    initialKind: initialKind,
    initialText: initialText,
  ),
);

/// Asks for a member name; null when cancelled.
Future<String?> showKeyEditor(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final result = await showDialog<JsonValueInput>(
    context: context,
    builder: (context) => ValueEditorDialog(
      title: title,
      askKey: true,
      askValue: false,
      initialKey: initial,
    ),
  );
  return result?.key;
}

/// Asks to pick one of [keys]; null when cancelled.
Future<String?> showKeyPicker(
  BuildContext context, {
  required String title,
  required List<String> keys,
}) => showDialog<String>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text(title),
    children: [
      for (final k in keys)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, k),
          child: Text(k),
        ),
    ],
  ),
);

/// A dialog that edits a member name, a JSON value of a chosen kind, or
/// both; it pops a [JsonValueInput].
class ValueEditorDialog extends StatefulWidget {
  /// Creates the dialog titled [title].
  const ValueEditorDialog({
    required this.title,
    super.key,
    this.askKey = false,
    this.askValue = true,
    this.initialKey = '',
    this.initialKind = JsonKind.string,
    this.initialText = '',
  });

  /// The dialog's title.
  final String title;

  /// Whether a member name is asked for.
  final bool askKey;

  /// Whether a value is asked for.
  final bool askValue;

  /// The member name to start with.
  final String initialKey;

  /// The kind of value to start with.
  final JsonKind initialKind;

  /// The value text to start with; see [parseJsonValue].
  final String initialText;

  @override
  State<ValueEditorDialog> createState() => _ValueEditorDialogState();
}

class _ValueEditorDialogState extends State<ValueEditorDialog> {
  late final TextEditingController _key = TextEditingController(
    text: widget.initialKey,
  );
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  late JsonKind _kind = widget.initialKind;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _text.dispose();
    super.dispose();
  }

  void _setKind(JsonKind kind) {
    setState(() {
      _kind = kind;
      _error = null;
      switch (kind) {
        case JsonKind.object:
          _text.text = '{}';
        case JsonKind.array:
          _text.text = '[]';
        case JsonKind.boolean:
          _text.text = 'true';
        case JsonKind.nullValue:
          _text.text = '';
        case JsonKind.string:
        case JsonKind.number:
          break;
      }
    });
  }

  void _save() {
    final key = widget.askKey ? _key.text : null;
    if (!widget.askValue) {
      Navigator.pop<JsonValueInput>(context, (key: key, value: null));
      return;
    }
    final parsed = parseJsonValue(_kind, _text.text);
    if (parsed.error != null) {
      setState(() => _error = parsed.error);
      return;
    }
    Navigator.pop<JsonValueInput>(context, (key: key, value: parsed.value));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.askKey)
              TextField(
                key: const ValueKey('proxie-key-field'),
                controller: _key,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Key'),
              ),
            if (widget.askValue) ...[
              const SizedBox(height: 8),
              DropdownButton<JsonKind>(
                key: const ValueKey('proxie-kind-field'),
                value: _kind,
                isExpanded: true,
                onChanged: (k) {
                  if (k != null) _setKind(k);
                },
                items: [
                  for (final k in JsonKind.values)
                    DropdownMenuItem(value: k, child: Text(_kindLabel(k))),
                ],
              ),
              if (_kind != JsonKind.nullValue)
                TextField(
                  key: const ValueKey('proxie-value-field'),
                  controller: _text,
                  autofocus: !widget.askKey,
                  minLines: 1,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: 'Value',
                    errorText: _error,
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
