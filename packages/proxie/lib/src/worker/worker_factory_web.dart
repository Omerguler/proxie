import '../config.dart';
import '../storage/memory_store.dart';
import 'in_process_worker.dart';
import 'worker.dart';

/// Web has no isolates or files: commands run in-process over memory.
Future<ProxieWorker> spawnProxieWorker(
  ProxieConfig config, {
  String? supportDir,
  Duration startupTimeout = const Duration(seconds: 30),
}) => InProcessWorker.start(MemoryStore(), config);
