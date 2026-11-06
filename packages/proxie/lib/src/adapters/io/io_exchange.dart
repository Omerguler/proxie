import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:proxie/src/adapters/body_capture.dart';
import 'package:proxie/src/adapters/capture_marker.dart';
import 'package:proxie/src/adapters/io/buffered_request.dart';
import 'package:proxie/src/adapters/io/http_tokens.dart';
import 'package:proxie/src/adapters/io/proxie_client_response.dart';
import 'package:proxie/src/core/decision.dart';
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

const _simulatedNoConnection = 'Connection failed (simulated by Proxie)';
const _simulatedTimeout = 'Request timed out (simulated by Proxie)';

/// Runs one closed [BufferedHttpClientRequest] through the engine: records
/// the request, then sends it to the real client, answers from a Map Local
/// rule, or fails it, and hands back the response for the app.
///
/// With no `engine` the request is sent to `inner` as given, unrecorded.
///
/// A response is fully buffered only when a response breakpoint matches the
/// (possibly edited) request, and only up to `teeCap` bytes or the breakpoint
/// timeout (see `bufferForPause`); otherwise it streams through with a copy of
/// at most `teeCap` bytes recorded when the app finishes reading. A streamed
/// response the app never listens to leaves the call pending.
class IoExchange {
  /// Creates the exchange for [request] with its buffered body [bytes].
  IoExchange({
    required BufferedHttpClientRequest request,
    required HttpClient inner,
    required ProxieEngine? engine,
    required String adapterName,
    required Uint8List bytes,
    void Function()? onOpened,
  }) : _request = request,
       _onOpened = onOpened,
       _inner = inner,
       _engine = engine,
       _adapterName = adapterName,
       _bytes = bytes;

  final BufferedHttpClientRequest _request;
  final HttpClient _inner;
  final ProxieEngine? _engine;
  final String _adapterName;
  final void Function()? _onOpened;

  /// The body to send; released once sent, so uploads are held only until
  /// then.
  Uint8List _bytes;
  String? _callId;
  Object? _abortError;

  /// The real request, once opened on [_inner].
  HttpClientRequest? real;

  /// Stops the exchange: records it as cancelled and aborts [real].
  void abort(Object error, StackTrace? stackTrace) {
    if (_abortError != null) return;
    _abortError = error;
    final callId = _callId;
    if (callId != null) {
      guardRecording(
        () => _engine?.onError(
          callId,
          const ProxieError(
            type: 'cancelled',
            message: 'Request aborted by the app',
          ),
        ),
      );
    }
    real?.abort(error, stackTrace);
  }

  /// Records and sends the request, or answers or fails it per the
  /// engine's decision, and returns the response for the app.
  Future<HttpClientResponse> run() async {
    final engine = _engine;
    if (engine == null) {
      return await _send(_request.method, _request.uri, null, _bytes);
    }
    final callId = engine.newCallId();
    _callId = callId;
    final ProxieRequest captured;
    final RequestDecision decision;
    try {
      captured = ProxieRequest(
        method: _request.method,
        url: _request.uri,
        headers: _recordedHeaders(),
        body: ProxieBody.from(
          _bytes,
          _request.headers[HttpHeaders.contentTypeHeader]?.first,
          cap: engine.config.teeCap,
        ),
      );
      decision = await engine.onRequest(callId, _adapterName, captured);
    } on Object catch (e, st) {
      // Recording must never break live traffic: send it on, unrecorded.
      developer.log(
        'Proxie capture failed',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
      _checkNotAborted();
      return await _send(_request.method, _request.uri, null, _bytes);
    }
    _checkNotAborted();
    switch (decision) {
      case AbortRequest(:final error):
        throw HttpException(error.message, uri: _request.uri);
      case MockDecision(:final action):
        return await _mock(engine, callId, action);
      case Proceed(request: final proceeded):
        return await _proceed(engine, callId, captured, proceeded);
    }
  }

  Future<HttpClientResponse> _mock(
    ProxieEngine engine,
    String callId,
    MapLocalAction action,
  ) async {
    _bytes = Uint8List(0);
    if (action.delay > Duration.zero) {
      await Future<void>.delayed(action.delay);
      _checkNotAborted();
    }
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
        throw const SocketException(_simulatedNoConnection);
      case null:
        break;
    }
    final mocked =
        action.response ??
        ProxieResponse(statusCode: 200, headers: {}, body: ProxieBody.empty());
    final out = await _respond(engine, callId, mocked);
    return ProxieClientResponse.buffered(
      out,
      out.body.bytes,
      method: _request.method,
    );
  }

  Future<HttpClientResponse> _proceed(
    ProxieEngine engine,
    String callId,
    ProxieRequest captured,
    ProxieRequest proceeded,
  ) async {
    final bool buffer;
    final HttpClientResponse res;
    try {
      buffer = engine.hasResponseBreakpoint(proceeded);
      res = identical(proceeded, captured)
          ? await _send(_request.method, _request.uri, null, _bytes)
          : await _send(
              proceeded.method,
              proceeded.url,
              proceeded.headers,
              keepsFull(captured.body, proceeded.body)
                  ? _bytes
                  : proceeded.body.bytes,
            );
    } catch (e) {
      if (_abortError == null) {
        guardRecording(
          () => engine.onError(
            callId,
            ProxieError(
              type: e is TimeoutException ? 'timeout' : 'network',
              message: '$e',
            ),
          ),
        );
      }
      rethrow;
    }
    if (_abortError != null) {
      // Aborted while the response was arriving: drop it.
      unawaited(res.listen(null).cancel());
      _checkNotAborted();
    }
    if (!buffer) return _tee(engine, callId, res, res);

    final Uint8List body;
    try {
      final read = await bufferForPause(
        res,
        cap: engine.config.teeCap,
        timeout: engine.config.breakpointTimeout,
      );
      final rest = read.rest;
      if (rest != null) {
        _checkNotAborted();
        return _tee(engine, callId, res, rest);
      }
      body = read.body!;
    } catch (e) {
      if (_abortError == null) {
        guardRecording(
          () => engine.onError(
            callId,
            ProxieError(type: 'stream_error', message: '$e'),
          ),
        );
      }
      rethrow;
    }
    _checkNotAborted();
    final received = ProxieResponse(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      headers: headersToMap(res.headers),
      body: ProxieBody.from(
        body,
        res.headers[HttpHeaders.contentTypeHeader]?.first,
        cap: engine.config.teeCap,
      ),
    );
    final out = await _respond(engine, callId, received);
    final full = keepsFull(received.body, out.body);
    return ProxieClientResponse.buffered(
      out,
      full ? body : out.body.bytes,
      method: proceeded.method,
      real: res,
      owned: full,
    );
  }

  /// Opens the real request on [_inner] and sends it.
  ///
  /// With null [edited] headers the app's request is copied as written
  /// (headers with their spelling, cookies, body framing); otherwise the
  /// edited headers replace the real request's and `content-length` is the
  /// length of [bytes].
  Future<HttpClientResponse> _send(
    String method,
    Uri url,
    Map<String, List<String>>? edited,
    Uint8List bytes,
  ) => runMarkedCaptured(() async {
    final app = _request;
    final HttpClientRequest out;
    try {
      out = await _inner.openUrl(method, url);
    } finally {
      _onOpened?.call();
    }
    real = out;
    final abortError = _abortError;
    if (abortError != null) {
      out.abort(abortError);
      // abort() takes any Object; rethrow it as given, as dart:io does.
      // ignore: only_throw_errors
      throw abortError;
    }
    out
      ..followRedirects = app.followRedirects
      ..maxRedirects = app.maxRedirects
      ..bufferOutput = app.bufferOutput;
    if (edited == null) {
      _copyHeaders(out.headers, app.headers.toMap());
      out
        ..persistentConnection = app.persistentConnection
        ..contentLength = app.contentLength;
      if (app.contentLength < 0) {
        out.headers.chunkedTransferEncoding =
            app.headers.chunkedTransferEncoding;
      }
      out.cookies.addAll(app.cookies);
    } else {
      // Cookies are already in the edited `cookie` header.
      _copyHeaders(out.headers, edited);
      out.contentLength = bytes.length;
    }
    if (bytes.isNotEmpty) out.add(bytes);
    _bytes = Uint8List(0);
    return await out.close();
  });

  /// Makes [target]'s headers equal [wanted], keeping the names' spelling
  /// from the app. Body framing headers are left to the caller; `host` is
  /// kept as the real request computed it for its URL unless the app set a
  /// different one.
  void _copyHeaders(HttpHeaders target, Map<String, List<String>> wanted) {
    const framing = {
      HttpHeaders.contentLengthHeader,
      HttpHeaders.transferEncodingHeader,
    };
    final present = <String>[];
    target.forEach((name, _) => present.add(name.toLowerCase()));
    for (final name in present) {
      if (framing.contains(name) || name == HttpHeaders.hostHeader) continue;
      if (!wanted.containsKey(name)) target.removeAll(name);
    }
    final source = _request.headers;
    final defaultHost = _request.uri.host.contains(':')
        ? '[${_request.uri.host}]'
        : _request.uri.host;
    for (final e in wanted.entries) {
      final name = e.key;
      if (framing.contains(name)) continue;
      if (name == HttpHeaders.hostHeader &&
          e.value.length == 1 &&
          _isDefaultHost(e.value.single, defaultHost)) {
        continue;
      }
      target.set(source.originalName(name), e.value, preserveHeaderCase: true);
      if (source.isNoFolding(name)) target.noFolding(name);
    }
  }

  bool _isDefaultHost(String value, String host) {
    final uri = _request.uri;
    final defaultPort = uri.isScheme('https')
        ? HttpClient.defaultHttpsPort
        : HttpClient.defaultHttpPort;
    return value == (uri.port == defaultPort ? host : '$host:${uri.port}');
  }

  /// Streams [source], the body of [res], to the app unchanged while keeping
  /// a copy of at most `teeCap` bytes, reported when the stream ends.
  HttpClientResponse _tee(
    ProxieEngine engine,
    String callId,
    HttpClientResponse res,
    Stream<List<int>> source,
  ) {
    final cap = engine.config.teeCap;
    final headers = headersToMap(res.headers);
    final contentType = res.headers[HttpHeaders.contentTypeHeader]?.first;
    ProxieResponse snapshot(
      Uint8List kept,
      int total, {
      bool partial = false,
    }) => ProxieResponse(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      headers: headers,
      body: teedBody(kept, total, contentType, cap: cap, partial: partial),
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
    return ProxieClientResponse.streamed(res, stream);
  }

  /// The app's headers as recorded, with [BufferedHttpClientRequest.cookies]
  /// added as a `cookie` value the way `dart:io` sends them.
  Map<String, List<String>> _recordedHeaders() {
    final headers = _request.headers.toMap();
    final cookies = _request.cookies;
    if (cookies.isNotEmpty) {
      (headers[HttpHeaders.cookieHeader] ??= []).add(
        cookies.map((c) => '${c.name}=${c.value}').join('; '),
      );
    }
    return headers;
  }

  Future<ProxieResponse> _respond(
    ProxieEngine engine,
    String callId,
    ProxieResponse res,
  ) async {
    try {
      return await engine.onResponse(callId, res);
    } on ProxieAbortedException catch (e) {
      throw HttpException(e.error.message, uri: _request.uri);
    }
  }

  void _checkNotAborted() {
    final error = _abortError;
    // abort() takes any Object; rethrow it as given, as dart:io does.
    // ignore: only_throw_errors
    if (error != null) throw error;
  }
}
