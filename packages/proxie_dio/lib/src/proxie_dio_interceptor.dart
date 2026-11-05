import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:proxie/adapter.dart';

import 'package:proxie_dio/src/dio_bodies.dart';

part 'proxie_dio_install.dart';

/// `RequestOptions.extra` key holding the id of the call Proxie records.
const _callIdKey = 'proxie.callId';

/// `RequestOptions.extra` key marking a Proxie replay, which is not recorded.
const _replayKey = 'proxie.replay';

const _simulatedNoConnection = 'Connection failed (simulated by Proxie)';
const _simulatedTimeout = 'Request timed out (simulated by Proxie)';

final _defaultTransformer = SyncTransformer();

/// A Dio [Interceptor] that records calls into an attached Proxie engine.
///
/// Prefer [ProxieDio.install]: it adds this interceptor last (so it records
/// requests as the app's interceptors left them) and a response and error
/// observer first (so responses and errors are recorded before app
/// interceptors such as retry or auth refresh act on them), keeps the
/// `HttpOverrides` adapter from recording the same call again, and enables
/// [replay].
///
/// Added by hand (`dio.interceptors.add(ProxieDioInterceptor())`) it records
/// as well, but responses and errors only once they reach it: a retry or
/// auth-refresh interceptor placed before it that handles an error hides
/// that attempt, which is then recorded as `superseded` when the same
/// request is sent again (or stays pending if it is not). With
/// `ProxieHttpOverridesAdapter` attached each call is also recorded twice,
/// bodies are encoded with Dio's default transformer, and [replay] needs a
/// `replayClient`.
///
/// While no engine is attached every request, response and error passes
/// through untouched.
///
/// Mocked responses, breakpoint edits and simulated failures are handed on
/// with `callFollowing…Interceptor` set where Dio allows it, so the app's
/// interceptors see them as they would see real responses and errors.
///
/// Limitations:
/// - Request bodies sent as [FormData] or a [Stream] are recorded as a text
///   placeholder (marked truncated, so they cannot be replayed or edited).
/// - Edits to a request body that was stored truncated (over the capture
///   cap) are ignored: the app's full body is sent.
/// - [ResponseType.stream] responses are not read: their body is recorded
///   empty and marked truncated, and response breakpoints cannot edit them.
/// - Response bodies are recorded as Dio decoded them (decoded JSON is
///   encoded again), not as the raw bytes received.
/// - A call stays pending if an interceptor that runs after this one in the
///   request phase completes it without calling the following interceptors,
///   for example a cache interceptor added after [ProxieDio.install] that
///   answers from its cache. Add such interceptors before installing.
class ProxieDioInterceptor extends Interceptor implements ProxieCaptureAdapter {
  /// Creates the interceptor; [replay] sends with [replayClient] when given,
  /// otherwise with the Dio given to [ProxieDio.install].
  ProxieDioInterceptor({Dio? replayClient}) : _replayClient = replayClient;

  final Dio? _replayClient;

  /// The Dio this interceptor was last installed on by [ProxieDio.install].
  Dio? _installed;
  ProxieEngine? _engine;

  @override
  String get name => 'dio';

  /// True when a Dio to replay with is known: `replayClient` or the one
  /// given to [ProxieDio.install].
  @override
  bool get supportsReplay => _replayClient != null || _installed != null;

  @override
  void attach(ProxieEngine engine) => _engine = engine;

  @override
  void detach() => _engine = null;

  Transformer get _transformer =>
      _installed?.transformer ?? _defaultTransformer;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final engine = _engine;
    final previous = options.extra[_callIdKey];
    if (engine == null || options.extra[_replayKey] == true) {
      // Only drop a stale id of ours, so the adapter does not mark the call.
      if (previous != null) options.extra.remove(_callIdKey);
      return handler.next(options);
    }
    if (previous is String) {
      // The same options sent again (for example by a retry interceptor
      // placed before this one) before the earlier attempt reached us.
      engine.onError(
        previous,
        const ProxieError(
          type: 'superseded',
          message: 'Sent again before this attempt completed (retried)',
        ),
      );
    }
    final callId = engine.newCallId();
    options.extra[_callIdKey] = callId;
    final ProxieRequest captured;
    final RequestDecision decision;
    try {
      captured = ProxieRequest(
        method: options.method,
        url: options.uri,
        headers: requestHeaders(options.headers),
        body: await captureRequestBody(
          options,
          _transformer,
          cap: engine.config.teeCap,
        ),
      );
      decision = await engine.onRequest(callId, name, captured);
    } on Object catch (e, st) {
      // Capturing must never break the request: the call is recorded as
      // failed ('unknown') and the request is sent on unchanged.
      developer.log('Proxie capture failed', error: e, stackTrace: st);
      _safeOnError(
        engine,
        callId,
        ProxieError(type: 'unknown', message: 'Proxie capture failed: $e'),
      );
      _finish(options);
      if (!handler.isCompleted) handler.next(options);
      return;
    }
    if (handler.isCompleted) return;
    try {
      switch (decision) {
        case AbortRequest(:final error):
          _finish(options);
          handler.reject(_aborted(options, error), true);
        case Mock(:final action):
          await _mock(engine, callId, options, action, handler);
        case Proceed(request: final proceeded):
          if (!identical(proceeded, captured)) {
            _applyRequest(options, captured, proceeded);
          }
          handler.next(options);
      }
    } on Object catch (e, st) {
      // Applying the decision failed (ignored when already recorded).
      developer.log('Proxie decision failed', error: e, stackTrace: st);
      _safeOnError(
        engine,
        callId,
        ProxieError(type: 'unknown', message: 'Proxie failed: $e'),
      );
      _finish(options);
      if (!handler.isCompleted) {
        handler.reject(
          DioException(requestOptions: options, error: e, stackTrace: st),
          true,
        );
      }
    }
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) => _observeResponse(response, handler);

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) =>
      _observeError(err, handler);

  Future<void> _observeResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final engine = _engine;
    final options = response.requestOptions;
    final callId = options.extra[_callIdKey];
    if (engine == null || callId is! String) return handler.next(response);

    final ProxieResponse? out;
    try {
      out = await _respond(engine, callId, response);
    } on ProxieAbortedException catch (e) {
      _finish(options);
      return handler.reject(_aborted(options, e.error), true);
    } on _DecodeFailure catch (f) {
      _finish(options);
      if (handler.isCompleted) return;
      return handler.reject(f.toDioException(options), true);
    } on Object catch (e, st) {
      developer.log('Proxie response capture failed', error: e, stackTrace: st);
      _finish(options);
      if (!handler.isCompleted) handler.next(response);
      return;
    }
    _finish(options);
    if (handler.isCompleted) return;
    if (out == null) return handler.next(response);
    if (options.validateStatus(response.statusCode)) {
      return handler.next(response);
    }
    handler.reject(
      DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: options,
        response: response,
      ),
      true,
    );
  }

  Future<void> _observeError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final engine = _engine;
    final options = err.requestOptions;
    final callId = options.extra[_callIdKey];
    if (engine == null || callId is! String) return handler.next(err);

    final response = err.response;
    if (err.type == DioExceptionType.badResponse && response != null) {
      // An HTTP response, not a transport failure: recorded as a response,
      // and a response breakpoint may still turn it into a success.
      final ProxieResponse? out;
      try {
        out = await _respond(engine, callId, response);
      } on ProxieAbortedException catch (e) {
        _finish(options);
        return handler.next(_aborted(options, e.error));
      } on _DecodeFailure catch (f) {
        _finish(options);
        if (handler.isCompleted) return;
        return handler.next(f.toDioException(options));
      } on Object catch (e, st) {
        developer.log(
          'Proxie response capture failed',
          error: e,
          stackTrace: st,
        );
        _finish(options);
        if (!handler.isCompleted) handler.next(err);
        return;
      }
      _finish(options);
      if (handler.isCompleted) return;
      if (out == null) return handler.next(err);
      if (options.validateStatus(response.statusCode)) {
        // Dio 5.11 offers no callFollowingResponseInterceptor here.
        return handler.resolve(response);
      }
      return handler.next(
        DioException.badResponse(
          statusCode: response.statusCode ?? 0,
          requestOptions: options,
          response: response,
        ),
      );
    }

    _finish(options);
    engine.onError(
      callId,
      _recordedError(err),
      response: response == null ? null : _snapshot(engine, response),
    );
    handler.next(err);
  }

  /// Sends [request] again with `replayClient` (or the Dio given to
  /// [ProxieDio.install]) and returns the full response, without recording
  /// it. Every status is returned as a response.
  ///
  /// Other interceptors on that Dio still run.
  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    if (request.body.truncated) {
      throw StateError('Cannot replay: request body was truncated');
    }
    final dio = _replayClient ?? _installed;
    if (dio == null) {
      throw StateError(
        'Cannot replay: no Dio to send with; pass replayClient or use '
        'ProxieDio.install',
      );
    }
    final base = dio.options;
    final bytes = request.body.bytes;
    final options = RequestOptions(
      method: request.method,
      path: request.url.toString(),
      headers: {
        for (final e in request.headers.entries)
          if (e.key != Headers.contentLengthHeader)
            e.key: e.value.length == 1 ? e.value.single : e.value,
      },
      data: bytes.isEmpty ? null : Uint8List.fromList(bytes),
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
      extra: {_replayKey: true},
      connectTimeout: base.connectTimeout,
      sendTimeout: base.sendTimeout,
      receiveTimeout: base.receiveTimeout,
      followRedirects: base.followRedirects,
      maxRedirects: base.maxRedirects,
      persistentConnection: base.persistentConnection,
      preserveHeaderCase: base.preserveHeaderCase,
    );
    final res = await runMarkedCaptured(() => dio.fetch<List<int>>(options));
    final data = res.data;
    return ProxieResponse(
      statusCode: res.statusCode ?? 0,
      reasonPhrase: res.statusMessage,
      headers: res.headers.map,
      body: ProxieBody.from(
        data == null ? Uint8List(0) : Uint8List.fromList(data),
        res.headers.value(Headers.contentTypeHeader),
        cap: _engine?.config.teeCap ?? defaultBodyCap,
      ),
    );
  }

  /// A [DioException] is recorded the same way as a live call's.
  @override
  ProxieError classifyReplayError(Object error) =>
      error is DioException ? _recordedError(error) : defaultReplayError(error);

  /// Answers [options] per [action] without the network.
  Future<void> _mock(
    ProxieEngine engine,
    String callId,
    RequestOptions options,
    MapLocalAction action,
    RequestInterceptorHandler handler,
  ) async {
    if (action.delay > Duration.zero) await Future<void>.delayed(action.delay);
    switch (action.failure) {
      case SimulatedFailure.timeout:
        engine.onError(
          callId,
          const ProxieError(type: 'timeout', message: _simulatedTimeout),
        );
        _finish(options);
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
            message: _simulatedTimeout,
          ),
          true,
        );
      case SimulatedFailure.noConnection:
        engine.onError(
          callId,
          const ProxieError(
            type: 'no_connection',
            message: _simulatedNoConnection,
          ),
        );
        _finish(options);
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: _simulatedNoConnection,
          ),
          true,
        );
      case null:
        break;
    }
    final mocked =
        action.response ??
        ProxieResponse(statusCode: 200, headers: {}, body: ProxieBody.empty());
    final ProxieResponse out;
    try {
      out = await engine.onResponse(callId, mocked);
    } on ProxieAbortedException catch (e) {
      _finish(options);
      return handler.reject(_aborted(options, e.error), true);
    }
    _finish(options);
    if (handler.isCompleted) return;
    final response = Response<dynamic>(
      requestOptions: options,
      statusCode: out.statusCode,
      statusMessage: out.reasonPhrase,
      headers: _dioHeaders(options, out.headers),
      data: await decodeResponseData(
        options,
        _transformer,
        out.body.bytes,
        out.statusCode,
        out.headers,
      ),
    );
    if (options.validateStatus(out.statusCode)) {
      return handler.resolve(response, true);
    }
    handler.reject(
      DioException.badResponse(
        statusCode: out.statusCode,
        requestOptions: options,
        response: response,
      ),
      true,
    );
  }

  /// Reports [response] for [callId] and writes breakpoint edits back into
  /// it. Returns the response the engine handed back, or null for a
  /// [ResponseType.stream] response, which is only recorded.
  Future<ProxieResponse?> _respond(
    ProxieEngine engine,
    String callId,
    Response<dynamic> response,
  ) async {
    final data = response.data;
    if (data is ResponseBody) {
      engine.recordResponse(
        callId,
        ProxieResponse(
          statusCode: response.statusCode ?? 0,
          reasonPhrase: response.statusMessage,
          headers: response.headers.map,
          body: streamedResponseBody(
            data,
            response.headers.value(Headers.contentTypeHeader),
          ),
        ),
      );
      return null;
    }
    final captured = _snapshot(engine, response);
    final out = await engine.onResponse(callId, captured);
    if (!identical(out, captured)) {
      await _applyResponse(response, captured, out);
    }
    return out;
  }

  ProxieResponse _snapshot(ProxieEngine engine, Response<dynamic> response) =>
      ProxieResponse(
        statusCode: response.statusCode ?? 0,
        reasonPhrase: response.statusMessage,
        headers: response.headers.map,
        body: ProxieBody.from(
          encodeResponseData(
            response.data,
            response.requestOptions.responseType,
          ),
          response.headers.value(Headers.contentTypeHeader),
          cap: engine.config.teeCap,
        ),
      );

  /// Writes the parts of [out] edited at a breakpoint into [response].
  Future<void> _applyResponse(
    Response<dynamic> response,
    ProxieResponse captured,
    ProxieResponse out,
  ) async {
    final options = response.requestOptions;
    response
      ..statusCode = out.statusCode
      ..statusMessage = out.reasonPhrase;
    if (!sameHeaders(captured.headers, out.headers)) {
      response.headers = _dioHeaders(options, out.headers);
    }
    if (!sameBytes(captured.body.bytes, out.body.bytes)) {
      try {
        response.data = await decodeResponseData(
          options,
          _transformer,
          out.body.bytes,
          out.statusCode,
          out.headers,
        );
      } catch (e, st) {
        throw _DecodeFailure(e, st);
      }
    }
  }
}

/// Writes the parts of [proceeded] edited at a breakpoint into [options].
///
/// An edited URL becomes the full `path` (so `baseUrl` no longer applies)
/// with no separate query parameters. Edited headers keep the app's casing
/// for names it already used. An edited body is sent as its bytes, and so is
/// the recorded body when only the content type changed (Dio would encode
/// the app's data differently for the new type). Unchanged bytes keep the
/// app's data (a [FormData] or stream behind a placeholder). Edits to a body
/// stored truncated are refused, and so is a content-type change for it:
/// only part of the body is known.
void _applyRequest(
  RequestOptions options,
  ProxieRequest captured,
  ProxieRequest proceeded,
) {
  if (proceeded.method != captured.method) options.method = proceeded.method;
  if (proceeded.url != captured.url) {
    options
      ..path = proceeded.url.toString()
      ..queryParameters = {};
  }
  const ct = Headers.contentTypeHeader;
  final typeChanged = !_sameValues(captured.headers[ct], proceeded.headers[ct]);
  var headers = proceeded.headers;
  if (captured.body.truncated && typeChanged) {
    // Dio would encode the app's data anew for the new type, into bytes the
    // inspector never showed.
    developer.log(
      'Proxie: content-type edit on a truncated request body ignored; '
      'the original content type is sent',
    );
    final original = captured.headers[ct];
    headers = {
      for (final e in proceeded.headers.entries)
        if (e.key != ct) e.key: e.value,
      ct: ?original,
    };
  }
  if (!sameHeaders(captured.headers, headers)) {
    final names = {for (final k in options.headers.keys) k.toLowerCase(): k};
    final contentType = headers[ct];
    options
      ..headers = {
        for (final e in headers.entries)
          names[e.key] ?? e.key: e.value.length == 1 ? e.value.single : e.value,
      }
      // Clears Dio's default content type too when it was removed.
      ..contentType = contentType?.join(', ');
  }
  final bodyEdited = !sameBytes(captured.body.bytes, proceeded.body.bytes);
  if (captured.body.truncated) {
    if (bodyEdited) {
      developer.log(
        'Proxie: edit to a truncated request body ignored; '
        'the original body is sent',
      );
    }
    return;
  }
  final data = options.data;
  final reencoded =
      typeChanged && data != null && data is! FormData && data is! Stream;
  if (bodyEdited || reencoded) {
    final bytes = proceeded.body.bytes;
    options.data = bytes.isEmpty ? null : Uint8List.fromList(bytes);
  }
}

bool _sameValues(List<String>? a, List<String>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A failure decoding an edited response body, handed to the app as Dio
/// hands over its own decoding failures.
class _DecodeFailure implements Exception {
  _DecodeFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  DioException toDioException(RequestOptions options) => DioException(
    requestOptions: options,
    error: error,
    stackTrace: stackTrace,
  );
}

/// [ProxieEngine.onError] that never throws: recording must not break the
/// request.
void _safeOnError(ProxieEngine engine, String callId, ProxieError error) {
  try {
    engine.onError(callId, error);
  } on Object catch (e, st) {
    developer.log('Proxie could not record an error', error: e, stackTrace: st);
  }
}

/// Marks the call behind [options] as finished, so later interceptor
/// callbacks for it (and the marking adapter) pass through.
void _finish(RequestOptions options) => options.extra.remove(_callIdKey);

/// The error the app gets for a call aborted at a breakpoint; [error]'s
/// message is kept as `DioException.error`.
DioException _aborted(RequestOptions options, ProxieError error) =>
    DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: error.message,
      message: 'Aborted by Proxie',
    );

Headers _dioHeaders(RequestOptions options, Map<String, List<String>> h) =>
    Headers.fromMap({
      for (final e in h.entries) e.key: List.of(e.value),
    }, preserveHeaderCase: options.preserveHeaderCase);

/// What [err] is recorded as, for live calls and replays alike.
ProxieError _recordedError(DioException err) => ProxieError(
  type: _errorType(err.type),
  message: err.message ?? err.error?.toString() ?? err.type.name,
);

String _errorType(DioExceptionType type) => switch (type) {
  DioExceptionType.connectionTimeout ||
  DioExceptionType.sendTimeout ||
  DioExceptionType.receiveTimeout ||
  DioExceptionType.transformTimeout => 'timeout',
  DioExceptionType.cancel => 'cancelled',
  DioExceptionType.connectionError => 'network',
  DioExceptionType.badCertificate => 'bad_certificate',
  DioExceptionType.badResponse => 'bad_response',
  DioExceptionType.unknown => 'unknown',
};
