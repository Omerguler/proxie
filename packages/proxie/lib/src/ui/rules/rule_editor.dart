import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/core/url_matcher.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/response.dart';
import 'package:proxie/src/ui/detail/copy_actions.dart';
import 'package:proxie/src/ui/inspector_shell.dart';
import 'package:proxie/src/ui/rules/preset_picker.dart';
import 'package:proxie/src/ui/rules/response_editor.dart';
import 'package:proxie/src/ui/rules/rules_controller.dart';

/// Opens the rule editor for [existing], or for a new rule of [kind] (Map
/// Local by default). [from] pre-fills a new rule from a call: its URL
/// without query as a `*` wildcard, its method and, for Map Local, its
/// response.
///
/// The editor is pushed on the inspector's navigator (see
/// [ProxieInspector.navigatorOf]) and edits the rules of the nearest
/// [RulesScope]; without one it does nothing. Completes when it closes.
Future<void> openRuleEditor(
  BuildContext c, {
  ProxieRule? existing,
  ProxieCall? from,
  RuleKind? kind,
}) async {
  final rules = RulesController.maybeOf(c, listen: false);
  if (rules == null) {
    developer.log('Cannot edit rules: no RulesScope above', name: 'proxie');
    return;
  }
  await ProxieInspector.navigatorOf(c).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          RuleEditor(rules: rules, existing: existing, from: from, kind: kind),
    ),
  );
}

/// The detail screen's rule actions, opening editors from [context]:
/// "Map Local from this response". Breakpoints are not offered yet.
ProxieDetailActions ruleDetailActions(BuildContext context) =>
    ProxieDetailActions(
      onMapLocal: (call) => unawaited(
        openRuleEditor(context, from: call, kind: RuleKind.mapLocal),
      ),
    );

/// The URL of [url] without query or fragment, followed by `*`.
String wildcardFor(Uri url) {
  final s = url.toString();
  final cut = s.indexOf(RegExp('[?#]'));
  return '${cut < 0 ? s : s.substring(0, cut)}*';
}

const _methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];

enum _Outcome { respond, timeout, noConnection }

/// Edits one rule: its name, URL pattern, method and, by kind, its
/// breakpoint phase or its Map Local answer (a response edited in a
/// [ResponseEditor], or a simulated failure, after a delay). Save applies
/// the rule at once and stores it.
class RuleEditor extends StatefulWidget {
  /// Creates the editor; see [openRuleEditor].
  const RuleEditor({
    required this.rules,
    super.key,
    this.existing,
    this.from,
    this.kind,
  });

  /// Where the rule is saved.
  final RulesController rules;

  /// The rule edited; null for a new rule.
  final ProxieRule? existing;

  /// The call a new rule is made from.
  final ProxieCall? from;

  /// The kind of a new rule; Map Local when null.
  final RuleKind? kind;

  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<RuleEditor> {
  // Fixed for the editor's life, so saving again replaces what the first
  // save added.
  late final String _id;
  late final RuleKind _kind;
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late final TextEditingController _delay;
  late bool _regex;
  late String? _method;
  late BreakpointPhase _phase;
  late _Outcome _outcome;
  late final ResponseDraft _draft;

  // The response the "captured" presets start from.
  ProxieResponse? _captured;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final from = widget.from;
    final request = from?.request;
    _id = existing?.id ?? widget.rules.newId('rule');
    _kind = existing?.kind ?? widget.kind ?? RuleKind.mapLocal;
    _name = TextEditingController(
      text:
          existing?.name ??
          (request == null
              ? ''
              : '${request.method} '
                    '${request.url.path.isEmpty ? '/' : request.url.path}'),
    );
    _pattern = TextEditingController(
      text:
          existing?.matcher.pattern ??
          (request == null ? '' : wildcardFor(request.url)),
    );
    _regex = existing?.matcher.isRegex ?? false;
    _method = existing != null ? existing.method : request?.method;
    _phase = existing?.phase ?? BreakpointPhase.both;
    final action = existing?.mapLocal;
    _outcome = _outcomeOf(action?.failure);
    _delay = TextEditingController(
      text: '${action?.delay.inMilliseconds ?? 0}',
    );
    _draft = ResponseDraft(widget.rules.worker);
    final captured = existing != null ? action?.response : from?.response;
    _captured = captured;
    if (captured != null) {
      _draft.load(captured, callId: existing == null ? from?.id : null);
    } else {
      _draft.load(
        ProxieResponse(
          statusCode: 200,
          headers: const {},
          body: ProxieBody.empty(),
        ),
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    _delay.dispose();
    _draft.dispose();
    super.dispose();
  }

  static _Outcome _outcomeOf(SimulatedFailure? failure) => switch (failure) {
    null => _Outcome.respond,
    SimulatedFailure.timeout => _Outcome.timeout,
    SimulatedFailure.noConnection => _Outcome.noConnection,
  };

  SimulatedFailure? get _failure => switch (_outcome) {
    _Outcome.respond => null,
    _Outcome.timeout => SimulatedFailure.timeout,
    _Outcome.noConnection => SimulatedFailure.noConnection,
  };

  void _message(String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
  }

  /// The Map Local action as edited, or null after telling why it is not
  /// valid.
  Future<MapLocalAction?> _action() async {
    final delay = int.tryParse(_delay.text.trim());
    if (delay == null || delay < 0) {
      _message('Delay must be a whole number of milliseconds');
      return null;
    }
    final failure = _failure;
    final problem = _draft.validate();
    // A simulated failure sends no response; a valid one is kept for later.
    if (failure == null && problem != null) {
      _message(problem);
      return null;
    }
    ProxieResponse? response;
    if (problem == null) {
      try {
        response = await _draft.build();
      } on Object catch (e, st) {
        developer.log(
          'Proxie could not read the edited body',
          name: 'proxie',
          error: e,
          stackTrace: st,
        );
        _message("Couldn't read the edited body");
        return null;
      }
    }
    return MapLocalAction(
      response: response,
      delay: Duration(milliseconds: delay),
      failure: failure,
    );
  }

  Future<void> _save() async {
    final pattern = _pattern.text.trim();
    if (pattern.isEmpty) {
      _message('Enter a URL pattern');
      return;
    }
    if (_regex) {
      try {
        RegExp(pattern);
      } on FormatException {
        _message('Invalid regular expression');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      MapLocalAction? action;
      if (_kind == RuleKind.mapLocal) {
        action = await _action();
        if (action == null) return;
      }
      final existing = widget.existing;
      final name = _name.text.trim();
      final rule = ProxieRule(
        id: _id,
        name: name.isEmpty ? pattern : name,
        enabled: existing?.enabled ?? true,
        kind: _kind,
        matcher: UrlMatcher(pattern, isRegex: _regex),
        method: _method,
        phase: _phase,
        mapLocal: action,
      );
      final saved = await widget.rules.save(rule);
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop();
      } else {
        _message(
          "The rule applies now but couldn't be saved. Tap Save to try again.",
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickPreset() async {
    final preset = await showPresetPicker(context, widget.rules);
    if (preset == null || !mounted) return;
    final captured = _captured;
    final action = preset.build(captured);
    setState(() {
      _outcome = _outcomeOf(action.failure);
      _delay.text = '${action.delay.inMilliseconds}';
    });
    final response = action.response;
    if (response == null) return;
    // The captured response itself opens as the call's tree again.
    final fromCall = widget.existing == null && identical(response, captured);
    _draft.load(response, callId: fromCall ? widget.from?.id : null);
  }

  Future<void> _saveAsPreset() async {
    final action = await _action();
    if (action == null || !mounted) return;
    final label = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (_) => const _PresetLabelDialog(),
    );
    if (label == null || label.trim().isEmpty || !mounted) return;
    try {
      await widget.rules.savePreset(label.trim(), action);
      if (mounted) _message('Preset saved');
    } on Object catch (e, st) {
      developer.log(
        'Proxie could not save the preset',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
      if (mounted) _message("Couldn't save the preset");
    }
  }

  @override
  Widget build(BuildContext context) {
    final mapLocal = _kind == RuleKind.mapLocal;
    final appBar = AppBar(
      title: Text(widget.existing == null ? 'New rule' : 'Edit rule'),
      actions: [
        IconButton(
          tooltip: 'Save rule',
          icon: const Icon(Icons.check),
          onPressed: _saving ? null : () => unawaited(_save()),
        ),
      ],
    );
    if (!mapLocal) return Scaffold(appBar: appBar, body: _form(context));
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: appBar,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Rule'),
                Tab(text: 'Response'),
              ],
            ),
            Expanded(
              child: Builder(
                builder: (context) {
                  final tabs = DefaultTabController.of(context);
                  // Both tabs stay alive, so typed text and the body's tree
                  // survive switching.
                  return ListenableBuilder(
                    listenable: tabs,
                    builder: (context, _) => IndexedStack(
                      index: tabs.index,
                      sizing: StackFit.expand,
                      children: [
                        _form(context),
                        ResponseEditor(
                          draft: _draft,
                          worker: widget.rules.worker,
                          rawEditableLimit: widget.rules.rawEditableLimit,
                          onPresets: () => unawaited(_pickPreset()),
                          onSaveAsPreset: () => unawaited(_saveAsPreset()),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final method = _method;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          key: const ValueKey('rule-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('rule-pattern'),
          controller: _pattern,
          decoration: InputDecoration(
            labelText: 'URL pattern',
            helperText: _regex
                ? 'Regular expression, matched as written'
                : '* matches anything; case-insensitive',
          ),
        ),
        SwitchListTile(
          key: const ValueKey('rule-regex'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Regular expression'),
          value: _regex,
          onChanged: (v) => setState(() => _regex = v),
        ),
        DropdownButtonFormField<String?>(
          key: const ValueKey('rule-method'),
          initialValue: method,
          decoration: const InputDecoration(labelText: 'Method'),
          items: [
            const DropdownMenuItem(child: Text('Any')),
            for (final m in [
              ..._methods,
              if (method != null && !_methods.contains(method)) method,
            ])
              DropdownMenuItem(value: m, child: Text(m)),
          ],
          onChanged: (v) => setState(() => _method = v),
        ),
        const SizedBox(height: 20),
        if (_kind == RuleKind.breakpoint) ...[
          Text('Pause at', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<BreakpointPhase>(
            segments: const [
              ButtonSegment(
                value: BreakpointPhase.request,
                label: Text('Request'),
              ),
              ButtonSegment(
                value: BreakpointPhase.response,
                label: Text('Response'),
              ),
              ButtonSegment(value: BreakpointPhase.both, label: Text('Both')),
            ],
            selected: {_phase},
            onSelectionChanged: (s) => setState(() => _phase = s.single),
          ),
        ] else ...[
          Text('Answer with', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<_Outcome>(
            segments: const [
              ButtonSegment(value: _Outcome.respond, label: Text('Respond')),
              ButtonSegment(value: _Outcome.timeout, label: Text('Timeout')),
              ButtonSegment(
                value: _Outcome.noConnection,
                label: Text('No connection'),
              ),
            ],
            selected: {_outcome},
            onSelectionChanged: (s) => setState(() => _outcome = s.single),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('rule-delay'),
            controller: _delay,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Delay (ms)'),
          ),
        ],
      ],
    );
  }
}

class _PresetLabelDialog extends StatefulWidget {
  const _PresetLabelDialog();

  @override
  State<_PresetLabelDialog> createState() => _PresetLabelDialogState();
}

class _PresetLabelDialogState extends State<_PresetLabelDialog> {
  final TextEditingController _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save as preset'),
    content: TextField(
      key: const ValueKey('preset-label'),
      controller: _label,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Name'),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(_label.text),
        child: const Text('Save'),
      ),
    ],
  );
}
