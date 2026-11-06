import 'package:proxie/src/config.dart';
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/store.dart';

/// How long a worker may take to open and start its store by default.
const Duration defaultWorkerStartupTimeout = Duration(seconds: 30);

/// What a [WorkerCommand] runs against inside the worker.
class WorkerContext {
  /// Creates the context for commands running against [store].
  WorkerContext({required this.store, required this.config});

  /// Where calls, rules and presets are kept.
  final ProxieStore store;

  /// The settings the worker was started with.
  final ProxieConfig config;

  /// Long-lived worker-side state shared between commands (e.g. parsed
  /// JSON documents), keyed by the commands that own it.
  final Map<String, Object> resources = {};
}

/// One operation run inside the worker; adding an operation is adding a
/// subclass.
///
/// Commands and their results cross an isolate boundary on native, so they
/// must hold only sendable objects (no ports, sockets or native handles).
abstract class WorkerCommand<R> {
  /// Lets subclasses be const.
  const WorkerCommand();

  /// Must complete. Commands run one at a time, so one that never completes
  /// stalls every later command until the worker is disposed.
  Future<R> execute(WorkerContext ctx);
}

/// An error a worker command throws that callers recognize by [code],
/// which survives the isolate boundary and minification (unlike
/// [ProxieWorkerException.type]).
abstract interface class CodedWorkerError {
  /// A stable name for this kind of error.
  String get code;
}

/// A failure inside the worker, carrying the original error's details.
class ProxieWorkerException implements Exception {
  /// Creates an exception from the original error's details.
  const ProxieWorkerException({
    required this.type,
    required this.message,
    required this.stackTrace,
    this.code,
  });

  /// Describes [error]; returns it unchanged when it already is one.
  factory ProxieWorkerException.wrap(Object error, StackTrace stackTrace) =>
      error is ProxieWorkerException
      ? error
      : ProxieWorkerException(
          type: error.runtimeType.toString(),
          message: error.toString(),
          stackTrace: stackTrace.toString(),
          code: switch (error) {
            CodedWorkerError() => error.code,
            ArgumentError() => argumentCode,
            StateError() => stateCode,
            _ => null,
          },
        );

  /// [code] of an [ArgumentError] (including a [RangeError]).
  static const argumentCode = 'argument';

  /// [code] of a [StateError].
  static const stateCode = 'state';

  /// Runtime type name of the original error; for messages only, since
  /// minified builds mangle it. Recognize errors by [code].
  final String type;

  /// A stable name for known kinds of error ([argumentCode], [stateCode],
  /// or a [CodedWorkerError]'s code); null for others.
  final String? code;

  /// The original error's `toString()`.
  final String message;

  /// The original stack trace, as text.
  final String stackTrace;

  @override
  String toString() => 'ProxieWorkerException($type): $message';
}

/// Owns storage (and the other heavy work) away from the UI isolate.
///
/// Commands run one at a time in the order they were sent, so a [run] sees
/// every earlier [upsert].
abstract interface class ProxieWorker implements CallSink {
  /// Session started when the worker was spawned.
  int get sessionId;

  /// Masks and stores [call] without waiting; failures are logged inside
  /// the worker, never thrown. Ignored after [dispose].
  @override
  void upsert(ProxieCall call);

  /// Runs [cmd] in the worker. Failures inside the worker complete the
  /// future with a [ProxieWorkerException]; after [dispose], or once the
  /// worker died, with a [StateError].
  Future<R> run<R>(WorkerCommand<R> cmd);

  /// Finishes queued commands, closes the store and stops the worker.
  /// Idempotent.
  Future<void> dispose();
}
