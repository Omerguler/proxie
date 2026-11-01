import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../config.dart';
import '../model/call.dart';
import '../storage/store.dart';
import 'in_process_worker.dart';
import 'worker.dart';

/// A [ProxieWorker] running in its own isolate of the same group, so
/// commands and results are sent as objects, without serialization.
class IsolateWorker implements ProxieWorker {
  IsolateWorker._(this._isolate, this._port);

  /// How long [dispose] waits for queued commands before killing the isolate.
  static const disposeTimeout = Duration(seconds: 5);

  /// Spawns the worker; [openStore] runs inside the new isolate and must be
  /// sendable (capture only plain values).
  ///
  /// Fails with a [ProxieWorkerException] when the store cannot be opened or
  /// started, or a [StateError] when the isolate dies during startup.
  static Future<IsolateWorker> spawn(
    ProxieConfig config,
    ProxieStore Function() openStore,
  ) async {
    final port = RawReceivePort();
    final ready = Completer<_Ready>();
    Object? lastError;
    port.handler = (Object? msg) {
      if (ready.isCompleted) return;
      switch (msg) {
        case _Ready():
          ready.complete(msg);
        case _Failure():
          ready.completeError(msg.exception);
        case null: // exit
          ready.completeError(
            StateError('Proxie worker exited during startup: $lastError'),
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
      r = await ready.future;
    } catch (_) {
      port.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
    return IsolateWorker._(isolate, port)
      .._commands = r.commands
      .._sessionId = r.sessionId
      .._listen();
  }

  final Isolate _isolate;

  @visibleForTesting
  Isolate get isolate => _isolate;
  final RawReceivePort _port;
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
    _port.handler = (Object? msg) {
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
      debugPrint('Proxie: failed to send call ${call.id}: $e');
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
    } catch (_) {
      _pending.remove(id);
      rethrow;
    }
    return await completer.future as R;
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    if (_dead) return;
    _commands.send(const _Dispose());
    try {
      await _exited.future.timeout(disposeTimeout);
    } on TimeoutException {
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
    commands.handler = (Object? msg) {
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
                  debugPrint('Proxie: failed to close the store: $e');
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
