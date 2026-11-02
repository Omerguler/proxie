import 'dart:io';

/// Deletes [dir] recursively, retrying for up to about half a second.
///
/// Windows may briefly hold just-closed files (pending deletes, virus
/// scanners, the search indexer), which makes a recursive delete fail with
/// "directory is not empty". A leftover temp directory is harmless, so the
/// last failure is swallowed rather than failing the test's teardown.
Future<void> deleteTempDir(Directory dir) async {
  for (var attempt = 0; attempt < 10 && dir.existsSync(); attempt++) {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
