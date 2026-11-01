import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/engine.dart';
import 'io_exchange.dart';
import 'proxie_http_headers.dart';

/// An [HttpClientRequest] that collects headers, cookies and body until
/// [close], then runs the call through the engine (see [IoExchange]).
///
/// Nothing is sent before [close]: connection errors surface from [close]
/// and [done] rather than from opening the request. Defaults match
/// `dart:io`: `host`, `accept-encoding: gzip`, the client's `user-agent`,
/// basic `authorization` from the URL's user info, and `content-length: 0`
/// for GET/HEAD or chunked transfer encoding otherwise.
class BufferedHttpClientRequest implements HttpClientRequest {
  BufferedHttpClientRequest({
    required this.method,
    required this.uri,
    required HttpClient inner,
    required ProxieEngine? Function() engine,
    required String adapterName,
  }) : _inner = inner,
       _engineOf = engine,
       _adapterName = adapterName,
       headers = ProxieHttpHeaders(
         defaultPort: uri.isScheme('https')
             ? HttpClient.defaultHttpsPort
             : HttpClient.defaultHttpPort,
       ) {
    // Errors reach whoever awaits close() or done; none is left unhandled.
    _done.future.ignore();
    var host = uri.host;
    if (host.contains(':')) host = '[$host]';
    headers
      ..host = host
      ..port = uri.port
      ..add(HttpHeaders.acceptEncodingHeader, 'gzip');
    final userAgent = inner.userAgent;
    if (userAgent != null) headers.add(HttpHeaders.userAgentHeader, userAgent);
    if (uri.userInfo.isNotEmpty) {
      final auth = base64Encode(utf8.encode(uri.userInfo));
      headers.set(HttpHeaders.authorizationHeader, 'Basic $auth');
    }
    if (method == 'GET' || method == 'HEAD') {
      contentLength = 0;
    } else {
      headers.chunkedTransferEncoding = true;
    }
  }

  final HttpClient _inner;
  final ProxieEngine? Function() _engineOf;
  final String _adapterName;
  final _body = BytesBuilder();
  final _done = Completer<HttpClientResponse>();
  IoExchange? _exchange;
  bool _closed = false;
  bool _aborted = false;
  bool _bound = false;
  (Object, StackTrace)? _sinkError;
  Encoding? _encoding;
  bool _followRedirects = true;
  int _maxRedirects = 5;
  bool _bufferOutput = true;

  @override
  final String method;

  @override
  final Uri uri;

  @override
  final ProxieHttpHeaders headers;

  @override
  final List<Cookie> cookies = [];

  @override
  bool get followRedirects => _followRedirects;

  @override
  set followRedirects(bool value) {
    _checkNotSent();
    _followRedirects = value;
  }

  @override
  int get maxRedirects => _maxRedirects;

  @override
  set maxRedirects(int value) {
    _checkNotSent();
    _maxRedirects = value;
  }

  @override
  bool get bufferOutput => _bufferOutput;

  @override
  set bufferOutput(bool value) {
    if (_closed) throw StateError('Header already sent');
    _bufferOutput = value;
  }

  @override
  int get contentLength => headers.contentLength;

  @override
  set contentLength(int value) => headers.contentLength = value;

  @override
  bool get persistentConnection => headers.persistentConnection;

  @override
  set persistentConnection(bool value) => headers.persistentConnection = value;

  /// The charset of `content-type` (ISO-8859-1 when none), fixed by the
  /// first [write] like `dart:io` does.
  @override
  Encoding get encoding {
    final latched = _encoding;
    if (latched != null) return latched;
    final charset = headers.contentType?.charset ?? 'iso-8859-1';
    return Encoding.getByName(charset) ?? latin1;
  }

  @override
  set encoding(Encoding value) =>
      throw StateError('IOSink encoding is not mutable');

  @override
  HttpConnectionInfo? get connectionInfo => _exchange?.real?.connectionInfo;

  @override
  Future<HttpClientResponse> get done => _done.future;

  @override
  void add(List<int> data) {
    _checkWritable();
    _body.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _checkWritable();
    _sinkError ??= (error, stackTrace ?? StackTrace.current);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _checkWritable();
    _bound = true;
    final completer = Completer<void>();
    stream.listen(
      _body.add,
      onError: (Object e, StackTrace st) {
        // Like dart:io, a failing stream fails the request too.
        _bound = false;
        _sinkError ??= (e, st);
        completer.completeError(e, st);
      },
      onDone: () {
        _bound = false;
        completer.complete();
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  @override
  void write(Object? object) {
    final string = '$object';
    if (string.isEmpty) return;
    _encoding ??= encoding;
    add(_encoding!.encode(string));
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    final iterator = objects.iterator;
    if (!iterator.moveNext()) return;
    if (separator.isEmpty) {
      do {
        write(iterator.current);
      } while (iterator.moveNext());
    } else {
      write(iterator.current);
      while (iterator.moveNext()) {
        write(separator);
        write(iterator.current);
      }
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  Future<void> flush() {
    if (_bound) throw StateError('StreamSink is bound to a stream');
    return Future.value();
  }

  @override
  Future<HttpClientResponse> close() {
    if (_bound) throw StateError('StreamSink is bound to a stream');
    if (!_closed) {
      _closed = true;
      headers.freeze();
      if (!_aborted) _send();
    }
    return done;
  }

  /// Aborts the call. Before the response arrives, [done] completes with
  /// [exception] (an [HttpException] by default), the real request (if
  /// opened) is aborted and the call is recorded as cancelled; afterwards it
  /// is forwarded to the real request, where it has no effect.
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    if (_done.isCompleted) {
      _exchange?.real?.abort(exception, stackTrace);
      return;
    }
    _aborted = true;
    final error = exception ?? const HttpException('Request has been aborted');
    _exchange?.abort(error, stackTrace);
    _done.completeError(error, stackTrace);
  }

  void _send() {
    final error = _sinkError;
    if (error != null) {
      _done.completeError(error.$1, error.$2);
      return;
    }
    final exchange = IoExchange(
      request: this,
      inner: _inner,
      engine: _engineOf(),
      adapterName: _adapterName,
      bytes: _body.takeBytes(),
    );
    _exchange = exchange;
    exchange.run().then(
      (res) {
        if (!_done.isCompleted) _done.complete(res);
      },
      onError: (Object e, StackTrace st) {
        if (!_done.isCompleted) _done.completeError(e, st);
      },
    );
  }

  void _checkWritable() {
    if (_closed) throw StateError('StreamSink is closed');
    if (_bound) throw StateError('StreamSink is bound to a stream');
  }

  void _checkNotSent() {
    if (_closed) throw StateError('Request already sent');
  }
}
