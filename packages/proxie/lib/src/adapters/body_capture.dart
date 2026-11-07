import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:proxie/src/model/body.dart';

/// Runs [record], a step that records a call and is not needed by the app,
/// and logs what it throws: recording must never break live traffic.
void guardRecording(void Function() record) {
  try {
    record();
  } on Object catch (e, st) {
    developer.log(
      'Proxie capture failed',
      name: 'proxie',
      error: e,
      stackTrace: st,
    );
  }
}

/// Streams [source] through unchanged while keeping a copy of its first
/// bytes for capture.
///
/// One byte past [cap] is kept, which marks the copy as truncated and lets
/// [ProxieBody.from] back the cut up to a character boundary (see
/// [teedBody]). When [source] ends, [onDone] gets the copy and the total
/// byte count. A stream error (type `stream_error`, forwarded to the
/// listener afterwards) or the listener cancelling early (type `cancelled`,
/// which also cancels [source]) calls [onFail] once instead. What [onDone] and
/// [onFail] throw is logged and otherwise ignored.
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
    guardRecording(() => onFail(type, message, kept.toBytes(), total));
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
            guardRecording(() => onDone(kept.toBytes(), total));
          }
          unawaited(controller.close());
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

/// Reads [source] for a response breakpoint, which needs the whole body.
///
/// Gives the `body` when [source] ends holding at most [cap] bytes within
/// [timeout]. Otherwise it may never end (server-sent events, say) and a pause
/// could not start: gives up and hands back `rest`, which is every byte of
/// [source], those read so far first, for streaming on as usual. A stream
/// error before that fails the returned future.
Future<({Uint8List? body, Stream<List<int>>? rest})> bufferForPause(
  Stream<List<int>> source, {
  required int cap,
  required Duration timeout,
}) {
  final result = Completer<({Uint8List? body, Stream<List<int>>? rest})>();
  final held = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> upstream;
  late final Timer timer;
  void giveUp() {
    timer.cancel();
    upstream.pause();
    late final StreamController<List<int>> rest;
    rest = StreamController<List<int>>(
      onListen: () {
        final kept = held.takeBytes();
        if (kept.isNotEmpty) rest.add(kept);
        upstream
          ..onData(rest.add)
          ..onError(rest.addError)
          ..onDone(() => unawaited(rest.close()))
          ..resume();
      },
      onPause: upstream.pause,
      onResume: upstream.resume,
      onCancel: upstream.cancel,
    );
    result.complete((body: null, rest: rest.stream));
  }

  timer = Timer(timeout, giveUp);
  upstream = source.listen(
    (chunk) {
      held.add(chunk);
      if (held.length > cap) giveUp();
    },
    onError: (Object e, StackTrace st) {
      timer.cancel();
      unawaited(upstream.cancel());
      result.completeError(e, st);
    },
    onDone: () {
      timer.cancel();
      result.complete((body: held.takeBytes(), rest: null));
    },
  );
  return result.future;
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
