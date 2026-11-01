import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../model/response.dart';
import 'proxie_http_headers.dart';

/// The [HttpClientResponse] Proxie hands to the app.
///
/// Two modes:
/// - [ProxieClientResponse.buffered]: built from a [ProxieResponse] (a Map
///   Local mock, or a real response held at a response breakpoint). The body
///   is delivered as one chunk and `content-length` is its length.
///   [redirect] and [detachSocket] throw [UnsupportedError].
/// - [ProxieClientResponse.streamed]: wraps the real response, delegating
///   every member and replacing only the body stream (a capture tee).
class ProxieClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  /// A response delivering [bytes] as described by [response].
  ///
  /// [response]'s headers are kept with every value separate, except that
  /// `content-length` is set to the delivered length and `transfer-encoding`
  /// is dropped. Values describing the real exchange ([redirects],
  /// [compressionState], ...) come from [real] when the response was
  /// received from the network.
  ProxieClientResponse.buffered(
    ProxieResponse response,
    Uint8List bytes, {
    HttpClientResponse? real,
  }) : _real = null,
       // Single-subscription like a real response; no chunk when empty.
       _body = Stream.fromIterable([if (bytes.isNotEmpty) bytes]),
       statusCode = response.statusCode,
       reasonPhrase = response.reasonPhrase ?? real?.reasonPhrase ?? '',
       contentLength = bytes.length,
       headers = ProxieHttpHeaders.fromMap({
         for (final e in response.headers.entries)
           if (e.key != HttpHeaders.contentLengthHeader &&
               e.key != HttpHeaders.transferEncodingHeader)
             e.key: e.value,
         HttpHeaders.contentLengthHeader: ['${bytes.length}'],
       }),
       compressionState =
           real?.compressionState ??
           HttpClientResponseCompressionState.notCompressed,
       persistentConnection = real?.persistentConnection ?? true,
       isRedirect = real?.isRedirect ?? false,
       redirects = List.unmodifiable(real?.redirects ?? const []),
       certificate = real?.certificate,
       connectionInfo = real?.connectionInfo;

  /// [real] with its body replaced by [body].
  ProxieClientResponse.streamed(HttpClientResponse real, Stream<List<int>> body)
    : _real = real,
      _body = body,
      statusCode = real.statusCode,
      reasonPhrase = real.reasonPhrase,
      contentLength = real.contentLength,
      headers = real.headers,
      compressionState = real.compressionState,
      persistentConnection = real.persistentConnection,
      isRedirect = real.isRedirect,
      redirects = real.redirects,
      certificate = real.certificate,
      connectionInfo = real.connectionInfo;

  final HttpClientResponse? _real;
  final Stream<List<int>> _body;

  @override
  final int statusCode;
  @override
  final String reasonPhrase;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers;
  @override
  final HttpClientResponseCompressionState compressionState;
  @override
  final bool persistentConnection;
  @override
  final bool isRedirect;
  @override
  final List<RedirectInfo> redirects;
  @override
  final X509Certificate? certificate;
  @override
  final HttpConnectionInfo? connectionInfo;

  @override
  List<Cookie> get cookies {
    final real = _real;
    if (real != null) return real.cookies;
    // Unparsable values are skipped rather than failing the app.
    final cookies = <Cookie>[];
    for (final v in headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      try {
        cookies.add(Cookie.fromSetCookieValue(v));
      } on Object {
        // Skip it.
      }
    }
    return cookies;
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) {
    final real = _real;
    if (real == null) {
      throw UnsupportedError('A Proxie-built response cannot be redirected');
    }
    return real.redirect(method, url, followLoops);
  }

  @override
  Future<Socket> detachSocket() {
    final real = _real;
    if (real == null) {
      throw UnsupportedError('A Proxie-built response has no socket');
    }
    return real.detachSocket();
  }
}
