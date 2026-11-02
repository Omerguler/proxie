import 'package:proxie/src/config.dart';
import 'package:proxie/src/storage/memory_store.dart';
import 'package:proxie/src/worker/in_process_worker.dart';
import 'package:proxie/src/worker/worker.dart';

/// Web has no isolates or files: commands run in-process over memory.
Future<ProxieWorker> spawnProxieWorker(
  ProxieConfig config, {
  String? supportDir,
  Duration startupTimeout = const Duration(seconds: 30),
}) => InProcessWorker.start(MemoryStore(), config);
