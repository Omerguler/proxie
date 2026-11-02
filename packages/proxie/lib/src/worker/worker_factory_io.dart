import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:proxie/src/config.dart';
import 'package:proxie/src/storage/memory_store.dart';
import 'package:proxie/src/storage/sqlite_store.dart';
import 'package:proxie/src/storage/store.dart';
import 'package:proxie/src/worker/isolate_worker.dart';
import 'package:proxie/src/worker/worker.dart';

/// Native implementation of `spawnProxieWorker` in `worker_factory.dart`:
/// an isolate over a SQLite store under [supportDir], or over memory when
/// history is not persisted.
Future<ProxieWorker> spawnProxieWorker(
  ProxieConfig config, {
  String? supportDir,
  Duration startupTimeout = const Duration(seconds: 30),
}) async {
  if (!config.persistHistory) {
    return await IsolateWorker.spawn(
      config,
      MemoryStore.new,
      startupTimeout: startupTimeout,
    );
  }
  // Plugins are unavailable in background isolates: resolve the path here.
  final base = supportDir ?? (await getApplicationSupportDirectory()).path;
  return await IsolateWorker.spawn(
    config,
    _sqliteOpener(
      '$base${Platform.pathSeparator}proxie',
      config.spillThreshold,
    ),
    startupTimeout: startupTimeout,
  );
}

// A plain function so the closure captures only the two values below and
// stays sendable to the worker isolate.
ProxieStore Function() _sqliteOpener(String dir, int spillThreshold) => () {
  Directory(dir).createSync(recursive: true);
  final sep = Platform.pathSeparator;
  return SqliteStore.open(
    '$dir${sep}proxie.db',
    spillDir: '$dir${sep}spill',
    spillThreshold: spillThreshold,
  );
};
