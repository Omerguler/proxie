import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../storage/memory_store.dart';
import '../storage/sqlite_store.dart';
import '../storage/store.dart';
import 'isolate_worker.dart';
import 'worker.dart';

Future<ProxieWorker> spawnProxieWorker(
  ProxieConfig config, {
  String? supportDir,
}) async {
  if (!config.persistHistory) {
    return IsolateWorker.spawn(config, MemoryStore.new);
  }
  // Plugins are unavailable in background isolates: resolve the path here.
  final base = supportDir ?? (await getApplicationSupportDirectory()).path;
  return IsolateWorker.spawn(
    config,
    _sqliteOpener(
      '$base${Platform.pathSeparator}proxie',
      config.spillThreshold,
    ),
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
