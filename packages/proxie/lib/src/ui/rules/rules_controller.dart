import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/core/presets.dart';
import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/worker/commands.dart';
import 'package:proxie/src/worker/worker.dart';

/// The rules and custom presets the rules screen and rule editor change.
///
/// [ProxieEngine.rules] is the source of truth: every change replaces it at
/// once, so the next call already sees it, then the whole list is saved in
/// the worker. Saves run one at a time, each storing the list as it is when
/// it runs, so the stored order always ends at the engine's. A failed save
/// never throws; it shows as [saveError] until a later save succeeds.
class RulesController extends ChangeNotifier {
  /// Creates the controller of [engine]'s rules, stored by [worker].
  RulesController({
    required this.worker,
    required this.engine,
    this.rawEditableLimit = defaultRawEditableLimit,
  });

  /// Stores the rules and presets.
  final ProxieWorker worker;

  /// Uses the rules.
  final ProxieEngine engine;

  /// Bodies of at least this many bytes open read-only in the editors
  /// until "Edit anyway" is tapped.
  final int rawEditableLimit;

  // The last save started; created on first use, in the caller's zone.
  Future<bool>? _tail;
  Object? _saveError;
  List<ResponsePreset> _customPresets = const [];
  bool _disposed = false;
  int _nextId = 0;

  /// The rules in matching order.
  List<ProxieRule> get rules => engine.rules.rules;

  /// Why the last save failed; null once one succeeds.
  Object? get saveError => _saveError;

  /// The custom presets as last loaded by [loadPresets].
  List<ResponsePreset> get customPresets => _customPresets;

  /// A new id for a rule or preset, unique within this controller.
  String newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';

  /// Replaces the rule with [rule]'s id, or inserts [rule] first, so no
  /// older rule shadows the one just made; true once saved.
  Future<bool> save(ProxieRule rule) {
    final next = [...rules];
    final i = next.indexWhere((r) => r.id == rule.id);
    if (i < 0) {
      next.insert(0, rule);
    } else {
      next[i] = rule;
    }
    return _commit(next);
  }

  /// Enables or disables rule [id].
  Future<bool> setEnabled(String id, {required bool enabled}) => _commit([
    for (final r in rules)
      if (r.id == id) r.copyWith(enabled: enabled) else r,
  ]);

  /// Removes rule [id].
  Future<bool> delete(String id) => _commit([
    for (final r in rules)
      if (r.id != id) r,
  ]);

  /// Puts [rule] back at [index] (clamped), as after an undone delete.
  Future<bool> insert(int index, ProxieRule rule) {
    final next = [
      for (final r in rules)
        if (r.id != rule.id) r,
    ];
    next.insert(index.clamp(0, next.length), rule);
    return _commit(next);
  }

  /// Moves the rule at [from] to [to]: [from] indexes [rules] before the
  /// move, [to] the list with the rule already removed (as
  /// `ReorderableListView.onReorderItem` reports them).
  Future<bool> reorder(int from, int to) {
    final next = [...rules];
    final rule = next.removeAt(from);
    next.insert(to.clamp(0, next.length), rule);
    return _commit(next);
  }

  /// Completes once every save started so far has finished (saves never
  /// throw), so the worker can be disposed without losing the last change.
  Future<void> flush() async {
    Future<bool>? last;
    while (_tail != null && !identical(_tail, last)) {
      last = _tail;
      await last;
    }
  }

  /// Saves the rules as they are now again, after a failure.
  Future<bool> retrySave() => _commit(rules);

  Future<bool> _commit(List<ProxieRule> next) {
    engine.rules = RuleSet(next);
    _notify();
    final previous = _tail;
    final done = previous == null
        ? _persist()
        : previous.then((_) => _persist());
    _tail = done;
    return done;
  }

  Future<bool> _persist() async {
    final list = rules;
    try {
      await worker.run(SaveRules(list));
      _saveError = null;
      _notify();
      return true;
    } on Object catch (e, st) {
      // The host app must never crash because the worker failed; the rules
      // still apply until the app restarts.
      developer.log(
        'Proxie could not save the rules',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
      _saveError = e;
      _notify();
      return false;
    }
  }

  /// Loads the custom presets into [customPresets]; throws when the worker
  /// fails.
  Future<List<ResponsePreset>> loadPresets() async {
    final presets = await worker.run(const LoadPresets());
    _customPresets = List.unmodifiable(presets);
    _notify();
    return _customPresets;
  }

  /// Saves [action] as a custom preset named [label]; throws when the
  /// worker fails.
  Future<void> savePreset(String label, MapLocalAction action) async {
    await worker.run(SavePreset(newId('preset'), label, action));
    try {
      await loadPresets();
    } on Object catch (e, st) {
      // Saved; the picker loads the list again when it opens.
      developer.log(
        'Proxie could not reload the presets',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// The controller of the nearest enclosing [RulesScope], if any. With
  /// [listen], [context] rebuilds when the rules change; pass false from
  /// callbacks.
  static RulesController? maybeOf(BuildContext context, {bool listen = true}) {
    final scope = listen
        ? context.dependOnInheritedWidgetOfExactType<RulesScope>()
        : context.getInheritedWidgetOfExactType<RulesScope>();
    return scope?.notifier;
  }
}

/// Makes its controller available to the rules screen and rule editors
/// below it, including pages pushed by them.
class RulesScope extends InheritedNotifier<RulesController> {
  /// Provides [controller] to [child].
  const RulesScope({
    required RulesController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
}
