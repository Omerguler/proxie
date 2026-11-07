import 'package:proxie/src/core/presets.dart';
import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/call_query.dart';

/// Whether [error], thrown while decoding a stored row, means the row no longer
/// decodes. Rows are decoded with casts and enum names, so besides an
/// [Exception] a bad one shows up as a [TypeError] or an [ArgumentError]
/// (written by a newer version, say).
bool isStoredRowError(Object error) =>
    error is Exception || error is TypeError || error is ArgumentError;

/// A recording session: one app run.
class SessionInfo {
  /// Describes session [id].
  const SessionInfo({
    required this.id,
    required this.startedAt,
    required this.callCount,
  });

  /// The session's id; sessions are numbered from 1 and never reused.
  final int id;

  /// When the session started.
  final DateTime startedAt;

  /// How many stored calls belong to the session.
  final int callCount;
}

/// Persistence for calls, rules and custom presets.
///
/// Calls are listed newest first by `startedAt`, ties broken by id
/// descending, so pagination is stable.
abstract interface class ProxieStore {
  /// Starts a session and returns its id (1, 2, 3, ...; never reused).
  Future<int> startSession();

  /// Inserts [c], or replaces the stored call with the same id.
  ///
  /// The call's session need not have been started (there is no foreign
  /// key); such calls are queryable but belong to no entry of [sessions].
  Future<void> upsert(ProxieCall c);

  /// Up to [limit] summaries of calls matching [q], skipping the first
  /// [offset], in the store's listing order.
  Future<List<CallSummary>> query(
    CallQuery q, {
    required int offset,
    required int limit,
  });

  /// Number of calls matching [q].
  Future<int> count(CallQuery q);

  /// The full call with id [id], bodies included; null when not stored.
  Future<ProxieCall?> get(String id);

  /// Started sessions, newest first. `callCount` counts the stored calls
  /// carrying the session id.
  Future<List<SessionInfo>> sessions();

  /// Stored rules in saved order; rules that cannot be decoded are skipped.
  Future<List<ProxieRule>> rules();

  /// Replaces all stored rules.
  Future<void> saveRules(List<ProxieRule> r);

  /// Custom presets in insertion order (replacing an id keeps its original
  /// position); their `build` ignores the captured response.
  Future<List<ResponsePreset>> customPresets();

  /// Saves a custom preset, replacing any with the same [id].
  Future<void> saveCustomPreset(String id, String label, MapLocalAction a);

  /// Removes calls older than [maxAge], then all but the newest [maxCalls].
  Future<void> trim({required int maxCalls, required Duration maxAge});

  /// Removes all calls and sessions; rules and presets are kept.
  Future<void> clear();

  /// Releases the store; it must not be used afterwards.
  Future<void> close();
}
