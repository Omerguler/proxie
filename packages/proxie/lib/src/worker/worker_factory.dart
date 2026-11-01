import '../config.dart';
import 'worker.dart';
import 'worker_factory_io.dart'
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
/// The worker starts a session and applies retention before completing.
Future<ProxieWorker> spawnProxieWorker(
  ProxieConfig config, {
  String? supportDir,
}) => impl.spawnProxieWorker(config, supportDir: supportDir);
