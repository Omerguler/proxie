import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:proxie/src/config.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/store.dart';
import 'package:proxie/src/worker/in_process_worker.dart';
import 'package:proxie/src/worker/worker.dart';

/// A [ProxieWorker] running in its own isolate of the same group, so
/// commands and results are sent as objects, without serialization.
class IsolateWorker implements ProxieWorker {
  IsolateWorker._(this._isolate, this._port, this._disposeTimeout);

  /// Default bound on opening and starting the store.
  static const defaultStartupTimeout = Duration(seconds: 30);

  /// Default time [dispose] waits for queued commands before killing the
  /// isolate.
  static const defaultDisposeTimeout = Duration(seconds: 5);

  /// Spawns the worker; [openStore] runs inside the new isolate and must be
  /// sendable (capture only plain values).
  ///
  /// Fails with a [ProxieWorkerException] when the store cannot be opened or
  /// started, or a [StateError] when the isolate dies during startup or
  /// startup takes longer than [startupTimeout] (the isolate is then killed).
  static Future<IsolateWorker> spawn(
    ProxieConfig config,
    ProxieStore Function() openStore, {
    Duration startupTimeout = defaultStartupTimeout,
    Duration disposeTimeout = defaultDisposeTimeout,
  }) async {
    final port = RawReceivePort();
    final ready = Completer<_Ready>();
    Object? lastError;
    port.handler = (msg) {
      if (ready.isCompleted) return;
      switch (msg) {
        case _Ready():
          ready.complete(msg);
        case _Failure():
          ready.completeError(msg.exception);
        case null: // exit
          ready.completeError(
            StateError(
              'Proxie worker exited during startup'
              '${lastError == null ? '' : ': $lastError'}',
            ),
          );
        case [final error, final stack]: // uncaught error
          lastError = '$error\n$stack';
      }
    };
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _main,
        _Init(port.sendPort, config, openStore),
        onExit: port.sendPort,
        onError: port.sendPort,
        debugName: 'proxie-worker',
      );
    } catch (_) {
      port.close();
      rethrow;
    }
    final _Ready r;
    try {
      r = await ready.future.timeout(
        startupTimeout,
        onTimeout: () => throw StateError(
          'Proxie worker did not start within $startupTimeout',
        ),
      );
    } catch (_) {
      port.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
    return IsolateWorker._(isolate, port, disposeTimeout)
      .._commands = r.commands
      .._sessionId = r.sessionId
      .._listen();
  }

  final Isolate _isolate;

  @visibleForTesting
  Isolate get isolate => _isolate;
  final RawReceivePort _port;
  final Duration _disposeTimeout;
  late final SendPort _commands;
  late final int _sessionId;

  final _pending = <int, Completer<Object?>>{};
  final _exited = Completer<void>();
  int _nextId = 0;
  bool _disposed = false;
  Future<void>? _disposing;
  String? _lastError;

  @override
  int get sessionId => _sessionId;

  bool get _dead => _exited.isCompleted;

  void _listen() {
    _port.handler = (msg) {
      switch (msg) {
        case _Result(:final id, :final value):
          _pending.remove(id)?.complete(value);
        case _Failure(:final id?, :final exception):
          _pending.remove(id)?.completeError(exception);
        case null: // exit
          _onExit();
        case [final error, final stack]: // uncaught error
          _lastError = '$error\n$stack';
      }
    };
  }

  void _onExit() {
    if (_dead) return;
    _exited.complete();
    _port.close();
    final pending = [..._pending.values];
    _pending.clear();
    for (final c in pending) {
      c.completeError(_unavailable());
    }
  }

  StateError _unavailable() => StateError(
    _disposed
        ? 'ProxieWorker is disposed'
        : 'Proxie worker isolate exited unexpectedly'
              '${_lastError == null ? '' : ': $_lastError'}',
  );

  @override
  void upsert(ProxieCall call) {
    if (_disposed || _dead) return;
    try {
      _commands.send(_Upsert(call));
    } catch (e) {
      developer.log('Failed to send call ${call.id}', name: 'proxie', error: e);
    }
  }

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    if (_disposed || _dead) throw _unavailable();
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      _commands.send(_Run(id, cmd));
    } catch (e, st) {
      _pending.remove(id);
      throw ProxieWorkerException.wrap(e, st);
    }
    return await completer.future as R;
  }

  /// Waits up to the dispose timeout (default [defaultDisposeTimeout]) for
  /// queued commands and the store's close; after that the isolate is
  /// killed, queued work is dropped and the store is left unclosed.
  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    if (_dead) return;
    _commands.send(const _Dispose());
    try {
      await _exited.future.timeout(_disposeTimeout);
    } on TimeoutException {
      developer.log(
        'Worker did not stop within $_disposeTimeout; killing it. '
        'Queued work is dropped and the store is not closed.',
        name: 'proxie',
      );
      _isolate.kill(priority: Isolate.immediate);
      await _exited.future;
    }
  }

  static Future<void> _main(_Init init) async {
    final reply = init.reply;
    final InProcessWorker inner;
    try {
      inner = await InProcessWorker.start(init.openStore(), init.config);
    } catch (e, st) {
      Isolate.exit(reply, _Failure(null, ProxieWorkerException.wrap(e, st)));
    }
    // Replies still being sent; dispose waits for them before exiting.
    final replying = <Future<void>>{};
    final commands = RawReceivePort();
    commands.handler = (msg) {
      switch (msg) {
        case _Upsert(:final call):
          inner.upsert(call);
        case _Run(:final id, :final cmd):
          final replied = inner
              .run(cmd)
              .then(
                (value) {
                  try {
                    reply.send(_Result(id, value));
                  } catch (e, st) {
                    reply.send(_Failure(id, ProxieWorkerException.wrap(e, st)));
                  }
                },
                onError: (Object e, StackTrace st) {
                  reply.send(_Failure(id, ProxieWorkerException.wrap(e, st)));
                },
              );
          replying.add(replied);
          replied.whenComplete(() => replying.remove(replied));
        case _Dispose():
          commands.close();
          Future.wait(replying)
              .then((_) => inner.dispose())
              .then(
                (_) => Isolate.exit(),
                onError: (Object e) {
                  developer.log(
                    'Failed to close the store',
                    name: 'proxie',
                    error: e,
                  );
                  Isolate.exit();
                },
              );
      }
    };
    reply.send(_Ready(commands.sendPort, inner.sessionId));
  }
}

class _Init {
  const _Init(this.reply, this.config, this.openStore);

  final SendPort reply;
  final ProxieConfig config;
  final ProxieStore Function() openStore;
}

class _Ready {
  const _Ready(this.commands, this.sessionId);

  final SendPort commands;
  final int sessionId;
}

class _Upsert {
  const _Upsert(this.call);

  final ProxieCall call;
}

class _Run {
  const _Run(this.id, this.cmd);

  final int id;
  final WorkerCommand<Object?> cmd;
}

class _Dispose {
  const _Dispose();
}

class _Result {
  const _Result(this.id, this.value);

  final int id;
  final Object? value;
}

/// A failed command, or a failed startup when [id] is null.
class _Failure {
  const _Failure(this.id, this.exception);

  final int? id;
  final ProxieWorkerException exception;
}
