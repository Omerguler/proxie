import 'package:proxie/src/config.dart';
import 'package:proxie/src/core/presets.dart';
import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/call_query.dart';
import 'package:proxie/src/storage/store.dart';
import 'package:proxie/src/worker/worker.dart';

/// Masks [call] with the configured masking, then stores it.
class UpsertCall extends WorkerCommand<void> {
  /// Creates a command that stores [call].
  const UpsertCall(this.call);

  /// Unmasked, as captured.
  final ProxieCall call;

  @override
  Future<void> execute(WorkerContext ctx) {
    final masking = ctx.config.masking;
    final response = call.response;
    final error = call.error;
    return ctx.store.upsert(
      call.copyWith(
        request: masking.maskRequest(call.request),
        response: response == null ? null : masking.maskResponse(response),
        error: error == null ? null : masking.maskError(error),
      ),
    );
  }
}

/// One page of the calls matching [query], newest first.
class QueryCalls extends WorkerCommand<List<CallSummary>> {
  /// Creates a command that lists [limit] calls from [offset].
  const QueryCalls(this.query, {required this.offset, required this.limit});

  /// The filters a call must match.
  final CallQuery query;

  /// How many matching calls to skip.
  final int offset;

  /// The most calls to return.
  final int limit;

  @override
  Future<List<CallSummary>> execute(WorkerContext ctx) =>
      ctx.store.query(query, offset: offset, limit: limit);
}

/// The number of calls matching [query].
class CountCalls extends WorkerCommand<int> {
  /// Creates a command that counts calls; all of them by default.
  const CountCalls([this.query = const CallQuery()]);

  /// The filters a counted call must match.
  final CallQuery query;

  @override
  Future<int> execute(WorkerContext ctx) => ctx.store.count(query);
}

/// The full call with id [id], bodies included; null when it is gone.
class GetCall extends WorkerCommand<ProxieCall?> {
  /// Creates a command that loads call [id].
  const GetCall(this.id);

  /// The id of the call to load.
  final String id;

  @override
  Future<ProxieCall?> execute(WorkerContext ctx) => ctx.store.get(id);
}

/// The recorded sessions, newest first.
class ListSessions extends WorkerCommand<List<SessionInfo>> {
  /// Creates a command that lists the sessions.
  const ListSessions();

  @override
  Future<List<SessionInfo>> execute(WorkerContext ctx) => ctx.store.sessions();
}

/// The stored rules in saved order.
class LoadRules extends WorkerCommand<List<ProxieRule>> {
  /// Creates a command that loads the rules.
  const LoadRules();

  @override
  Future<List<ProxieRule>> execute(WorkerContext ctx) => ctx.store.rules();
}

/// Replaces the stored rules with [rules].
class SaveRules extends WorkerCommand<void> {
  /// Creates a command that stores [rules].
  const SaveRules(this.rules);

  /// The complete rule list, in matching order.
  final List<ProxieRule> rules;

  @override
  Future<void> execute(WorkerContext ctx) => ctx.store.saveRules(rules);
}

/// The custom response presets the user saved.
class LoadPresets extends WorkerCommand<List<ResponsePreset>> {
  /// Creates a command that loads the custom presets.
  const LoadPresets();

  @override
  Future<List<ResponsePreset>> execute(WorkerContext ctx) =>
      ctx.store.customPresets();
}

/// Saves a custom preset, replacing any with the same [id].
class SavePreset extends WorkerCommand<void> {
  /// Creates a command that saves [action] as preset [label].
  const SavePreset(this.id, this.label, this.action);

  /// Identifies the preset; saving the same id again replaces it.
  final String id;

  /// The name shown in the preset picker.
  final String label;

  /// The response or failure the preset applies.
  final MapLocalAction action;

  @override
  Future<void> execute(WorkerContext ctx) =>
      ctx.store.saveCustomPreset(id, label, action);
}

/// Applies retention. A null limit means "use the configured value"
/// ([ProxieConfig.retentionCalls] / [ProxieConfig.retentionAge]), not
/// unlimited.
class Trim extends WorkerCommand<void> {
  /// Creates a command that trims to [maxCalls] calls and [maxAge].
  const Trim({this.maxCalls, this.maxAge});

  /// How many of the newest calls to keep; null uses the config.
  final int? maxCalls;

  /// How old a call may get before it is removed; null uses the config.
  final Duration? maxAge;

  @override
  Future<void> execute(WorkerContext ctx) => ctx.store.trim(
    maxCalls: maxCalls ?? ctx.config.retentionCalls,
    maxAge: maxAge ?? ctx.config.retentionAge,
  );
}

/// Removes all calls and sessions; rules and presets are kept.
class ClearAll extends WorkerCommand<void> {
  /// Creates a command that clears the history.
  const ClearAll();

  @override
  Future<void> execute(WorkerContext ctx) => ctx.store.clear();
}
