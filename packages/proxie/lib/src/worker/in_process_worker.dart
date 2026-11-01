import 'package:flutter/foundation.dart' show debugPrint;

import '../config.dart';
import '../model/call.dart';
import '../storage/store.dart';
import 'commands.dart';
import 'worker.dart';

/// Runs commands on the current isolate, one at a time.
///
/// Used directly on web, and inside the worker isolate on native.
class InProcessWorker implements ProxieWorker {
  InProcessWorker._(this._ctx, this.sessionId);

  /// Starts a session on [store] and applies retention. On failure [store]
  /// is closed and the error rethrown.
  static Future<InProcessWorker> start(
    ProxieStore store,
    ProxieConfig config,
  ) async {
    try {
      final session = await store.startSession();
      await store.trim(
        maxCalls: config.retentionCalls,
        maxAge: config.retentionAge,
      );
      return InProcessWorker._(
        WorkerContext(store: store, config: config),
        session,
      );
    } catch (_) {
      try {
        await store.close();
      } catch (_) {
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

  Future<R> _enqueue<R>(WorkerCommand<R> cmd) {
    final result = _tail.then((_) => cmd.execute(_ctx));
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  void upsert(ProxieCall call) {
    if (_disposing != null) return;
    _enqueue(UpsertCall(call)).catchError((Object e) {
      debugPrint('Proxie: failed to store call ${call.id}: $e');
    });
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
