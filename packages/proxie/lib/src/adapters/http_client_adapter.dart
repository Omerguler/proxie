import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:proxie/src/adapters/body_capture.dart';
import 'package:proxie/src/adapters/capture_adapter.dart';
import 'package:proxie/src/adapters/capture_marker.dart';
import 'package:proxie/src/core/decision.dart';
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

const _simulatedNoConnection = 'Connection failed (simulated by Proxie)';
const _simulatedTimeout = 'Request timed out (simulated by Proxie)';

/// A `package:http` client that records calls into an attached engine.
///
/// Wrap the app's client: `ProxieHttpClient(inner: http.Client())`. While no
/// engine is attached every request goes straight to `inner` untouched.
///
/// A streamed response is recorded when the app finishes (or cancels) reading
/// it; one the app never listens to stays pending in the inspector.
///
/// Responses handed to the app are rebuilt `StreamedResponse`s that keep the
/// final URL (`BaseResponseWithUrl.url`) but not `IOStreamedResponse`'s
/// `detachSocket`.
class ProxieHttpClient extends http.BaseClient implements ProxieCaptureAdapter {
  /// Wraps [inner], or a new `http.Client` when it is null. Calls are recorded
  /// under [name]; give each client its own when an app lists several in
  /// `Proxie.init`, since Edit & resend finds the client by that name.
  ProxieHttpClient({http.Client? inner, this.name = adapterName})
    : _inner = inner ?? http.Client();

  final http.Client _inner;
  ProxieEngine? _engine;

  /// The default [name].
  static const String adapterName = 'http';

  @override
  final String name;

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
    if (engine == null) return await _inner.send(request);

    // Headers are read after finalize(), which may set them (multipart).
    final bytes = await request.finalize().toBytes();
    final callId = engine.newCallId();
    final ProxieRequest captured;
    final _AbortFlag aborted;
    final RequestDecision decision;
    try {
      captured = ProxieRequest(
        method: request.method,
        url: request.url,
        headers: _toProxieHeaders(request.headers),
        body: ProxieBody.from(
          bytes,
          _header(request.headers, 'content-type'),
          cap: engine.config.teeCap,
        ),
      );
      aborted = _watchAbort(engine, callId, request);
      decision = await engine.onRequest(callId, name, captured);
    } on Object catch (e, st) {
      // Recording must never break live traffic: send it on, unrecorded.
      developer.log(
        'Proxie capture failed',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
      final out = http.Request(request.method, request.url)
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection
        ..headers.addAll(request.headers)
        ..bodyBytes = bytes;
      return await runMarkedCaptured(() => _inner.send(out));
    }
    aborted.check(request.url);
    switch (decision) {
      case AbortRequest(:final error):
        throw http.ClientException(error.message, request.url);
      case MockDecision(:final action):
        return await _mock(engine, callId, request, action, aborted);
      case Proceed(request: final proceeded):
        return await _proceed(
          engine,
          callId,
          request,
          captured,
          proceeded,
          bytes,
          aborted,
        );
    }
  }

  /// Records the call as cancelled when the app aborts [request], which also
  /// releases any pause; the returned flag tells the steps that follow.
  _AbortFlag _watchAbort(
    ProxieEngine engine,
    String callId,
    http.BaseRequest request,
  ) {
    final flag = _AbortFlag();
    if (request case http.Abortable(:final abortTrigger?)) {
      void abort() {
        flag.aborted = true;
        guardRecording(
          () => engine.onError(
            callId,
            const ProxieError(
              type: 'cancelled',
              message: 'Request aborted by the app',
            ),
          ),
        );
      }

      unawaited(
        abortTrigger.then((_) => abort(), onError: (Object _) => abort()),
      );
    }
    return flag;
  }

  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    if (request.body.truncated) {
      throw StateError('Cannot replay: request body was truncated');
    }
    final out = http.Request(request.method, request.url)
      ..headers.addAll(_toHttpHeaders(request.headers))
      ..bodyBytes = request.body.bytes;
    final res = await runMarkedCaptured(() => _inner.send(out));
    final bytes = await res.stream.toBytes();
    return ProxieResponse(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      headers: _responseHeaders(res),
      body: ProxieBody.from(
        bytes,
        _header(res.headers, 'content-type'),
        cap: _engine?.config.teeCap ?? defaultBodyCap,
      ),
    );
  }

  /// `package:http` wraps a connection failure, a `dart:io` connect timeout
  /// included, in a [http.ClientException] that does not say which it was,
  /// so only a [TimeoutException] is recorded as `timeout`.
  @override
  ProxieError classifyReplayError(Object error) => defaultReplayError(error);

  Future<http.StreamedResponse> _mock(
    ProxieEngine engine,
    String callId,
    http.BaseRequest request,
    MapLocalAction action,
    _AbortFlag aborted,
  ) async {
    if (action.delay > Duration.zero) await Future<void>.delayed(action.delay);
    aborted.check(request.url);
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
    aborted.check(request.url);
    return _streamed(out, out.body.bytes, request, url: request.url);
  }

  Future<http.StreamedResponse> _proceed(
    ProxieEngine engine,
    String callId,
    http.BaseRequest request,
    ProxieRequest captured,
    ProxieRequest proceeded,
    Uint8List bytes,
    _AbortFlag aborted,
  ) async {
    final bool buffer;
    final http.StreamedResponse res;
    try {
      final out = _outgoing(request, captured, proceeded, bytes);
      buffer = engine.hasResponseBreakpoint(proceeded);
      res = await runMarkedCaptured(() => _inner.send(out));
    } catch (e) {
      guardRecording(
        () => engine.onError(
          callId,
          ProxieError(
            type: e is TimeoutException ? 'timeout' : 'network',
            message: '$e',
          ),
        ),
      );
      rethrow;
    }
    if (!buffer) return _tee(engine, callId, request, res, res.stream);

    final Uint8List body;
    try {
      final read = await bufferForPause(
        res.stream,
        cap: engine.config.teeCap,
        timeout: engine.config.breakpointTimeout,
      );
      final rest = read.rest;
      if (rest != null) return _tee(engine, callId, request, res, rest);
      body = read.body!;
    } catch (e) {
      guardRecording(
        () => engine.onError(
          callId,
          ProxieError(type: 'stream_error', message: '$e'),
        ),
      );
      rethrow;
    }
    final received = ProxieResponse(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      headers: _responseHeaders(res),
      body: ProxieBody.from(
        body,
        _header(res.headers, 'content-type'),
        cap: engine.config.teeCap,
      ),
    );
    final out = await _respond(engine, callId, request.url, received);
    aborted.check(request.url);
    return _streamed(
      out,
      keepsFull(received.body, out.body) ? body : out.body.bytes,
      request,
      url: _finalUrl(res, request),
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
    );
  }

  /// Rebuilds the request to send, keeping the app's headers, full body and
  /// abort trigger unless they were edited at a breakpoint.
  http.Request _outgoing(
    http.BaseRequest original,
    ProxieRequest captured,
    ProxieRequest proceeded,
    Uint8List bytes,
  ) {
    final trigger = original is http.Abortable ? original.abortTrigger : null;
    final out =
        (trigger == null
              ? http.Request(proceeded.method, proceeded.url)
              : http.AbortableRequest(
                  proceeded.method,
                  proceeded.url,
                  abortTrigger: trigger,
                ))
          ..followRedirects = original.followRedirects
          ..maxRedirects = original.maxRedirects
          ..persistentConnection = original.persistentConnection;
    // Unedited (the engine hands back the same object): the app's headers as
    // given; edited: the breakpoint's headers.
    if (identical(proceeded, captured)) {
      for (final e in original.headers.entries) {
        if (e.key.toLowerCase() != 'content-length') {
          out.headers[e.key] = e.value;
        }
      }
    } else {
      out.headers.addAll(_toHttpHeaders(proceeded.headers));
    }
    // The body length defines content-length.
    out.bodyBytes = keepsFull(captured.body, proceeded.body)
        ? bytes
        : proceeded.body.bytes;
    return out;
  }

  /// Streams [source], the body of [res], to the app unchanged while keeping a
  /// copy of at most `teeCap` bytes, reported when the stream ends.
  http.StreamedResponse _tee(
    ProxieEngine engine,
    String callId,
    http.BaseRequest request,
    http.StreamedResponse res,
    Stream<List<int>> source,
  ) {
    final cap = engine.config.teeCap;
    ProxieResponse snapshot(
      Uint8List kept,
      int total, {
      bool partial = false,
    }) => ProxieResponse(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      headers: _responseHeaders(res),
      body: teedBody(
        kept,
        total,
        _header(res.headers, 'content-type'),
        cap: cap,
        partial: partial,
      ),
    );

    final stream = teeStream(
      source,
      cap: cap,
      // The app already has the bytes: record without breakpoints.
      onDone: (kept, total) =>
          engine.recordResponse(callId, snapshot(kept, total)),
      onFail: (type, message, kept, total) => engine.onError(
        callId,
        ProxieError(type: type, message: message),
        response: snapshot(kept, total, partial: true),
      ),
    );

    return _ProxieStreamedResponse(
      stream,
      res.statusCode,
      url: _finalUrl(res, request),
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
}

/// Whether the app aborted the request of a call.
class _AbortFlag {
  bool aborted = false;

  /// Fails the way an aborted `package:http` client does.
  void check(Uri url) {
    if (aborted) throw http.RequestAbortedException(url);
  }
}

/// A response for the app built from [res] with [bytes] as the body.
http.StreamedResponse _streamed(
  ProxieResponse res,
  Uint8List bytes,
  http.BaseRequest request, {
  required Uri url,
  bool isRedirect = false,
  bool persistentConnection = true,
}) => _ProxieStreamedResponse(
  Stream.value(bytes),
  res.statusCode,
  url: url,
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

String? _header(Map<String, String> headers, String name) {
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == name) return e.value;
  }
  return null;
}

Map<String, List<String>> _toProxieHeaders(Map<String, String> headers) => {
  for (final e in headers.entries) e.key: [e.value],
};

/// Response headers with `set-cookie` split back into its separate values.
///
/// Only `set-cookie` is split: other headers keep the value the app sees,
/// since splitting on commas would break dates such as `date` or `expires`.
Map<String, List<String>> _responseHeaders(http.BaseResponse res) {
  final headers = _toProxieHeaders(res.headers);
  for (final key in headers.keys.toList()) {
    if (key.toLowerCase() == 'set-cookie') {
      headers[key] = res.headersSplitValues[key] ?? headers[key]!;
    }
  }
  return headers;
}

Uri _finalUrl(http.BaseResponse res, http.BaseRequest request) =>
    res is http.BaseResponseWithUrl ? res.url : request.url;

/// A [http.StreamedResponse] that reports the final [url], like the ones
/// `package:http` clients return (its own `StreamedResponseV2` is private).
class _ProxieStreamedResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _ProxieStreamedResponse(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  });

  @override
  final Uri url;
}

/// Joins multi-valued headers; content-length is left to the body.
Map<String, String> _toHttpHeaders(Map<String, List<String>> headers) => {
  for (final e in headers.entries)
    if (e.key != 'content-length') e.key: e.value.join(', '),
};
