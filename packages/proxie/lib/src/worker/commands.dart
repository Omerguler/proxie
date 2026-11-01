import '../config.dart';
import '../core/presets.dart';
import '../core/rule.dart';
import '../model/call.dart';
import '../storage/call_query.dart';
import '../storage/store.dart';
import 'worker.dart';

/// Masks [call] with the configured masking, then stores it.
class UpsertCall extends WorkerCommand<void> {
  const UpsertCall(this.call);

  /// Unmasked, as captured.
  final ProxieCall call;

  @override
  Future<void> execute(WorkerContext ctx) {
    final masking = ctx.config.masking;
    final response = call.response;
    return ctx.store.upsert(
      call.copyWith(
        request: masking.maskRequest(call.request),
        response: response == null ? null : masking.maskResponse(response),
      ),
    );
  }
}

class QueryCalls extends WorkerCommand<List<CallSummary>> {
  const QueryCalls(this.query, {required this.offset, required this.limit});

  final CallQuery query;
  final int offset;
  final int limit;

  @override
  Future<List<CallSummary>> execute(WorkerContext ctx) =>
      ctx.store.query(query, offset: offset, limit: limit);
}

class CountCalls extends WorkerCommand<int> {
  const CountCalls([this.query = const CallQuery()]);

  final CallQuery query;

  @override
  Future<int> execute(WorkerContext ctx) => ctx.store.count(query);
}

class GetCall extends WorkerCommand<ProxieCall?> {
  const GetCall(this.id);

  final String id;

  @override
  Future<ProxieCall?> execute(WorkerContext ctx) => ctx.store.get(id);
}

class ListSessions extends WorkerCommand<List<SessionInfo>> {
  const ListSessions();

  @override
  Future<List<SessionInfo>> execute(WorkerContext ctx) => ctx.store.sessions();
}

class LoadRules extends WorkerCommand<List<ProxieRule>> {
  const LoadRules();

  @override
  Future<List<ProxieRule>> execute(WorkerContext ctx) => ctx.store.rules();
}

class SaveRules extends WorkerCommand<void> {
  const SaveRules(this.rules);

  final List<ProxieRule> rules;

  @override
  Future<void> execute(WorkerContext ctx) => ctx.store.saveRules(rules);
}

class LoadPresets extends WorkerCommand<List<ResponsePreset>> {
  const LoadPresets();

  @override
  Future<List<ResponsePreset>> execute(WorkerContext ctx) =>
      ctx.store.customPresets();
}

class SavePreset extends WorkerCommand<void> {
  const SavePreset(this.id, this.label, this.action);

  final String id;
  final String label;
  final MapLocalAction action;

  @override
  Future<void> execute(WorkerContext ctx) =>
      ctx.store.saveCustomPreset(id, label, action);
}

/// Applies retention. A null limit means "use the configured value"
/// ([ProxieConfig.retentionCalls] / [ProxieConfig.retentionAge]), not
/// unlimited.
class Trim extends WorkerCommand<void> {
  const Trim({this.maxCalls, this.maxAge});

  final int? maxCalls;
  final Duration? maxAge;

  @override
  Future<void> execute(WorkerContext ctx) => ctx.store.trim(
    maxCalls: maxCalls ?? ctx.config.retentionCalls,
    maxAge: maxAge ?? ctx.config.retentionAge,
  );
}

/// Removes all calls and sessions; rules and presets are kept.
class ClearAll extends WorkerCommand<void> {
  const ClearAll();

  @override
  Future<void> execute(WorkerContext ctx) => ctx.store.clear();
}
