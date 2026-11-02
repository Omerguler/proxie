import 'package:proxie/src/config.dart';
import 'package:proxie/src/worker/worker.dart';
import 'package:proxie/src/worker/worker_factory_io.dart'
    if (dart.library.js_interop) 'worker_factory_web.dart'
    as impl;

/// Spawns the worker that owns storage.
///
/// Native: an isolate holding `<supportDir>/proxie/proxie.db` (spill files
/// in `<supportDir>/proxie/spill`), or an in-memory store when
/// [ProxieConfig.persistHistory] is false (no files are created). A null
/// [supportDir] is resolved with `getApplicationSupportDirectory()` on the
/// calling isolate. Web: an in-process worker over an in-memory store.
///
/// The worker starts a session and applies retention before completing;
/// on native, startup that takes longer than [startupTimeout] fails with a
/// [StateError].
Future<ProxieWorker> spawnProxieWorker(
  ProxieConfig config, {
  String? supportDir,
  Duration startupTimeout = const Duration(seconds: 30),
}) => impl.spawnProxieWorker(
  config,
  supportDir: supportDir,
  startupTimeout: startupTimeout,
);
