import 'dart:async';
import 'dart:typed_data';

import '../model/body.dart';

/// Streams [source] through unchanged while keeping a copy of its first
/// bytes for capture.
///
/// One byte past [cap] is kept, which marks the copy as truncated and lets
/// [ProxieBody.from] back the cut up to a character boundary (see
/// [teedBody]). When [source] ends, [onDone] gets the copy and the total
/// byte count. A stream error (type `stream_error`, forwarded to the
/// listener afterwards) or the listener cancelling early (type `cancelled`,
/// which also cancels [source]) calls [onFail] once instead.
///
/// Pause and resume are forwarded, so back-pressure still reaches [source].
Stream<List<int>> teeStream(
  Stream<List<int>> source, {
  required int cap,
  required void Function(Uint8List kept, int total) onDone,
  required void Function(String type, String message, Uint8List kept, int total)
  onFail,
}) {
  final keepLimit = cap + 1;
  final kept = BytesBuilder();
  var total = 0;
  var finished = false;
  StreamSubscription<List<int>>? upstream;

  void fail(String type, String message) {
    if (finished) return;
    finished = true;
    onFail(type, message, kept.toBytes(), total);
  }

  late final StreamController<List<int>> controller;
  controller = StreamController<List<int>>(
    onListen: () {
      upstream = source.listen(
        (chunk) {
          total += chunk.length;
          final room = keepLimit - kept.length;
          if (room > 0) {
            kept.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
          }
          controller.add(chunk);
        },
        onError: (Object e, StackTrace st) {
          fail('stream_error', '$e');
          controller.addError(e, st);
        },
        onDone: () {
          if (!finished) {
            finished = true;
            onDone(kept.toBytes(), total);
          }
          controller.close();
        },
      );
    },
    onPause: () => upstream?.pause(),
    onResume: () => upstream?.resume(),
    onCancel: () {
      fail('cancelled', 'Response stream cancelled by the app');
      return upstream?.cancel();
    },
  );
  return controller.stream;
}

/// The stored body for a [teeStream] copy of a [total]-byte stream.
///
/// A [partial] copy (the stream failed or was cancelled) is marked truncated:
/// it holds only the bytes received so far.
ProxieBody teedBody(
  Uint8List kept,
  int total,
  String? contentType, {
  required int cap,
  bool partial = false,
}) {
  final b = ProxieBody.from(kept, contentType, cap: cap);
  return ProxieBody(
    bytes: b.bytes,
    contentType: b.contentType,
    kind: b.kind,
    truncated: b.truncated || partial,
    originalLength: total,
  );
}

/// Whether [after] is still the capped copy [before] of a body that was
/// longer, so the full original bytes should be sent instead.
bool keepsFull(ProxieBody before, ProxieBody after) {
  if (identical(before, after)) return true;
  if (!before.truncated || !after.truncated) return false;
  if (before.bytes.length != after.bytes.length) return false;
  for (var i = 0; i < before.bytes.length; i++) {
    if (before.bytes[i] != after.bytes[i]) return false;
  }
  return true;
}
