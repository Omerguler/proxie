import 'dart:async';
import 'dart:developer' as developer;

import 'package:proxie/src/config.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/store.dart';
import 'package:proxie/src/worker/commands.dart';
import 'package:proxie/src/worker/worker.dart';

/// Runs commands on the current isolate, one at a time.
///
/// Used directly on web, and inside the worker isolate on native.
///
/// Retention applies at start and again every [trimEvery] stored snapshots, so
/// an app that runs for days stays within it.
class InProcessWorker implements ProxieWorker {
  InProcessWorker._(this._ctx, this.sessionId);

  /// How many stored snapshots pass between two retention runs. A call makes
  /// two or more, so the history can exceed the limit by less than this.
  static const int trimEvery = 200;

  /// Starts a session on [store] and applies retention. On failure [store]
  /// is closed and the error rethrown.
  static Future<InProcessWorker> start(
    ProxieStore store,
    ProxieConfig config,
  ) async {
    try {
      final ctx = WorkerContext(store: store, config: config);
      final session = await store.startSession();
      await const Trim().execute(ctx);
      return InProcessWorker._(ctx, session);
    } on Object catch (_) {
      try {
        await store.close();
      } on Object catch (_) {
        // The original failure is the one worth reporting.
      }
      rethrow;
    }
  }

  final WorkerContext _ctx;

  @override
  final int sessionId;

  Future<void> _tail = Future.value();
  Future<void>? _disposing;
  int _sinceTrim = 0;

  Future<R> _enqueue<R>(WorkerCommand<R> cmd) {
    final result = _tail.then((_) => cmd.execute(_ctx));
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  void upsert(ProxieCall call) {
    if (_disposing != null) return;
    unawaited(
      _enqueue(UpsertCall(call)).catchError((Object e, StackTrace st) {
        developer.log(
          'Failed to store call ${call.id}',
          name: 'proxie',
          error: e,
          stackTrace: st,
        );
      }),
    );
    if (++_sinceTrim < trimEvery) return;
    _sinceTrim = 0;
    unawaited(
      _enqueue(const Trim()).catchError((Object e, StackTrace st) {
        developer.log(
          'Failed to apply retention',
          name: 'proxie',
          error: e,
          stackTrace: st,
        );
      }),
    );
  }

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    if (_disposing != null) throw StateError('ProxieWorker is disposed');
    try {
      return await _enqueue(cmd);
    } catch (e, st) {
      throw ProxieWorkerException.wrap(e, st);
    }
  }

  @override
  Future<void> dispose() =>
      _disposing ??= _tail.then((_) => _ctx.store.close());
}
