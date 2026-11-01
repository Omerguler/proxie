import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/decision.dart';
import '../core/engine.dart';
import '../core/rule.dart';
import '../model/body.dart';
import '../model/call.dart';
import '../model/request.dart';
import '../model/response.dart';
import 'capture_adapter.dart';
import 'capture_marker.dart';

const _simulatedNoConnection = 'Connection failed (simulated by Proxie)';
const _simulatedTimeout = 'Request timed out (simulated by Proxie)';

/// A `package:http` client that records calls into an attached engine.
///
/// Wrap the app's client: `ProxieHttpClient(inner: http.Client())`. While no
/// engine is attached every request goes straight to [inner] untouched.
class ProxieHttpClient extends http.BaseClient implements ProxieCaptureAdapter {
  ProxieHttpClient({http.Client? inner}) : _inner = inner ?? http.Client();

  final http.Client _inner;
  ProxieEngine? _engine;

  @override
  String get name => 'http';

  @override
  bool get supportsReplay => true;

  @override
  void attach(ProxieEngine engine) => _engine = engine;

  @override
  void detach() => _engine = null;

  @override
  void close() => _inner.close();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final engine = _engine;
    if (engine == null) return _inner.send(request);

    // Headers are read after finalize(), which may set them (multipart).
    final bytes = await request.finalize().toBytes();
    final callId = engine.newCallId();
    final captured = ProxieRequest(
      method: request.method,
      url: request.url,
      headers: _toProxieHeaders(request.headers),
      body: ProxieBody.from(
        bytes,
        _header(request.headers, 'content-type'),
        cap: engine.config.teeCap,
      ),
    );
    final decision = await engine.onRequest(callId, name, captured);
    switch (decision) {
      case AbortRequest(:final error):
        throw http.ClientException(error.message, request.url);
      case Mock(:final action):
        return _mock(engine, callId, request, action);
      case Proceed(request: final proceeded):
        return _proceed(engine, callId, request, captured, proceeded, bytes);
    }
  }

  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    final out = http.Request(request.method, request.url)
      ..headers.addAll(_toHttpHeaders(request.headers))
      ..bodyBytes = request.body.bytes;
    final res = await runMarkedCaptured(() => _inner.send(out));
    final bytes = await res.stream.toBytes();
    return ProxieResponse(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      headers: _toProxieHeaders(res.headers),
      body: ProxieBody.from(
        bytes,
        _header(res.headers, 'content-type'),
        cap: _engine?.config.teeCap ?? defaultBodyCap,
      ),
    );
  }

  Future<http.StreamedResponse> _mock(
    ProxieEngine engine,
    String callId,
    http.BaseRequest request,
    MapLocalAction action,
  ) async {
    if (action.delay > Duration.zero) await Future<void>.delayed(action.delay);
    switch (action.failure) {
      case SimulatedFailure.timeout:
        engine.onError(
          callId,
          const ProxieError(type: 'timeout', message: _simulatedTimeout),
        );
        throw TimeoutException(_simulatedTimeout);
      case SimulatedFailure.noConnection:
        engine.onError(
          callId,
          const ProxieError(
            type: 'no_connection',
            message: _simulatedNoConnection,
          ),
        );
        throw http.ClientException(_simulatedNoConnection, request.url);
      case null:
        break;
    }
    final mocked =
        action.response ??
        ProxieResponse(statusCode: 200, headers: {}, body: ProxieBody.empty());
    final out = await _respond(engine, callId, request.url, mocked);
    return _streamed(out, out.body.bytes, request);
  }

  Future<http.StreamedResponse> _proceed(
    ProxieEngine engine,
    String callId,
    http.BaseRequest request,
    ProxieRequest captured,
    ProxieRequest proceeded,
    Uint8List bytes,
  ) async {
    final bool buffer;
    final http.StreamedResponse res;
    try {
      final out = _outgoing(request, captured, proceeded, bytes);
      buffer = _hasResponseBreakpoint(engine, proceeded);
      res = await runMarkedCaptured(() => _inner.send(out));
    } catch (e) {
      engine.onError(
        callId,
        ProxieError(
          type: e is TimeoutException ? 'timeout' : 'network',
          message: '$e',
        ),
      );
      rethrow;
    }
    if (!buffer) return _tee(engine, callId, request, res);

    final Uint8List body;
    try {
      body = await res.stream.toBytes();
    } catch (e) {
      engine.onError(callId, ProxieError(type: 'stream_error', message: '$e'));
      rethrow;
    }
    final received = ProxieResponse(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      headers: _toProxieHeaders(res.headers),
      body: ProxieBody.from(
        body,
        _header(res.headers, 'content-type'),
        cap: engine.config.teeCap,
      ),
    );
    final out = await _respond(engine, callId, request.url, received);
    return _streamed(
      out,
      _keepsFull(received.body, out.body) ? body : out.body.bytes,
      request,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
    );
  }

  /// Rebuilds the request to send, keeping the app's headers and full body
  /// unless they were edited at a breakpoint.
  http.Request _outgoing(
    http.BaseRequest original,
    ProxieRequest captured,
    ProxieRequest proceeded,
    Uint8List bytes,
  ) {
    final out = http.Request(proceeded.method, proceeded.url)
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection;
    if (identical(proceeded, captured) ||
        identical(proceeded.headers, captured.headers)) {
      for (final e in original.headers.entries) {
        if (e.key.toLowerCase() != 'content-length') {
          out.headers[e.key] = e.value;
        }
      }
    } else {
      out.headers.addAll(_toHttpHeaders(proceeded.headers));
    }
    // The body length defines content-length.
    out.bodyBytes = _keepsFull(captured.body, proceeded.body)
        ? bytes
        : proceeded.body.bytes;
    return out;
  }

  /// Streams [res] to the app unchanged while keeping a copy of at most
  /// `teeCap` bytes, reported when the stream ends.
  http.StreamedResponse _tee(
    ProxieEngine engine,
    String callId,
    http.BaseRequest request,
    http.StreamedResponse res,
  ) {
    final cap = engine.config.teeCap;
    // One byte past the cap marks the copy as truncated and lets
    // ProxieBody.from back the cut up to a character boundary.
    final keepLimit = cap + 1;
    final kept = BytesBuilder();
    var total = 0;
    var finished = false;
    StreamSubscription<List<int>>? upstream;

    ProxieResponse snapshot() {
      final b = ProxieBody.from(
        kept.toBytes(),
        _header(res.headers, 'content-type'),
        cap: cap,
      );
      return ProxieResponse(
        statusCode: res.statusCode,
        reasonPhrase: res.reasonPhrase,
        headers: _toProxieHeaders(res.headers),
        body: ProxieBody(
          bytes: b.bytes,
          contentType: b.contentType,
          kind: b.kind,
          truncated: b.truncated,
          originalLength: total,
        ),
      );
    }

    void fail(String type, String message) {
      if (finished) return;
      finished = true;
      engine.onError(
        callId,
        ProxieError(type: type, message: message),
        response: snapshot(),
      );
    }

    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        upstream = res.stream.listen(
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
              engine
                  .onResponse(callId, snapshot())
                  .then<void>(
                    (_) {},
                    onError: (Object e, StackTrace st) => developer.log(
                      'Proxie response recording failed',
                      error: e,
                      stackTrace: st,
                    ),
                  );
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

    return http.StreamedResponse(
      controller.stream,
      res.statusCode,
      contentLength: res.contentLength,
      request: request,
      headers: res.headers,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
      reasonPhrase: res.reasonPhrase,
    );
  }

  Future<ProxieResponse> _respond(
    ProxieEngine engine,
    String callId,
    Uri url,
    ProxieResponse res,
  ) async {
    try {
      return await engine.onResponse(callId, res);
    } on ProxieAbortedException catch (e) {
      throw http.ClientException(e.error.message, url);
    }
  }

  bool _hasResponseBreakpoint(ProxieEngine engine, ProxieRequest req) {
    try {
      return engine.rules.responseBreakpointFor(req) != null;
    } catch (_) {
      // The engine logs and ignores failing rule lookups as well.
      return false;
    }
  }
}

/// A response for the app built from [res] with [bytes] as the body.
http.StreamedResponse _streamed(
  ProxieResponse res,
  Uint8List bytes,
  http.BaseRequest request, {
  bool isRedirect = false,
  bool persistentConnection = true,
}) => http.StreamedResponse(
  Stream.value(bytes),
  res.statusCode,
  contentLength: bytes.length,
  request: request,
  headers: {
    ..._toHttpHeaders(res.headers),
    'content-length': '${bytes.length}',
  },
  isRedirect: isRedirect,
  persistentConnection: persistentConnection,
  reasonPhrase: res.reasonPhrase,
);

/// Whether [after] is still the capped copy [before] of a body that was
/// longer, so the full original bytes should be sent instead.
bool _keepsFull(ProxieBody before, ProxieBody after) {
  if (identical(before, after)) return true;
  if (!before.truncated || !after.truncated) return false;
  if (before.bytes.length != after.bytes.length) return false;
  for (var i = 0; i < before.bytes.length; i++) {
    if (before.bytes[i] != after.bytes[i]) return false;
  }
  return true;
}

String? _header(Map<String, String> headers, String name) {
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == name) return e.value;
  }
  return null;
}

Map<String, List<String>> _toProxieHeaders(Map<String, String> headers) => {
  for (final e in headers.entries) e.key: [e.value],
};

/// Joins multi-valued headers; content-length is left to the body.
Map<String, String> _toHttpHeaders(Map<String, List<String>> headers) => {
  for (final e in headers.entries)
    if (e.key != 'content-length') e.key: e.value.join(', '),
};
