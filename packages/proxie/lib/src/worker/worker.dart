import '../config.dart';
import '../core/engine.dart';
import '../model/call.dart';
import '../storage/store.dart';

/// What a [WorkerCommand] runs against inside the worker.
class WorkerContext {
  WorkerContext({required this.store, required this.config});

  final ProxieStore store;
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
  const WorkerCommand();

  /// Must complete. Commands run one at a time, so one that never completes
  /// stalls every later command until the worker is disposed.
  Future<R> execute(WorkerContext ctx);
}

/// A failure inside the worker, carrying the original error's details.
class ProxieWorkerException implements Exception {
  const ProxieWorkerException({
    required this.type,
    required this.message,
    required this.stackTrace,
  });

  /// Describes [error]; returns it unchanged when it already is one.
  factory ProxieWorkerException.wrap(Object error, StackTrace stackTrace) =>
      error is ProxieWorkerException
      ? error
      : ProxieWorkerException(
          type: error.runtimeType.toString(),
          message: error.toString(),
          stackTrace: stackTrace.toString(),
        );

  /// Runtime type name of the original error.
  final String type;

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
