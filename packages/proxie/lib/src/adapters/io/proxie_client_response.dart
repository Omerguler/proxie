import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:proxie/src/adapters/io/proxie_http_headers.dart';
import 'package:proxie/src/adapters/io/status_phrases.dart';
import 'package:proxie/src/model/response.dart';

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
  /// A response to a [method] request delivering [bytes] as described by
  /// [response].
  ///
  /// [response]'s headers are kept with every value separate (checked as
  /// received headers), except that `content-length` is set to the delivered
  /// length and `transfer-encoding` is dropped. When [real]'s body was
  /// decompressed by `dart:io`, the length is reported unknown (-1, no
  /// `content-length`) as `dart:io` does. For a mock (no [real]),
  /// `content-encoding` is dropped since the body is delivered as is, unless
  /// it declares gzip and the bytes are still gzip data: then it is kept and
  /// the response reports [HttpClientResponseCompressionState.compressed].
  ///
  /// The reason phrase is [response]'s, unless the status was edited and
  /// the phrase was not, in which case it is the standard one for the new
  /// status. [isRedirect] follows the status. Values describing the real
  /// exchange ([redirects], [compressionState], connection details) come
  /// from [real] when the response was received from the network; a mock's
  /// [persistentConnection] follows its `connection` header.
  ///
  /// [bytes] are copied unless [owned] says nobody else holds them.
  factory ProxieClientResponse.buffered(
    ProxieResponse response,
    Uint8List bytes, {
    required String method,
    HttpClientResponse? real,
    bool owned = false,
  }) {
    final body = owned ? bytes : Uint8List.fromList(bytes);
    final decompressed =
        real?.compressionState ==
        HttpClientResponseCompressionState.decompressed;
    final stillGzipped =
        real == null &&
        body.length >= 2 &&
        body[0] == 0x1f &&
        body[1] == 0x8b &&
        (response.headers[HttpHeaders.contentEncodingHeader] ?? const []).any(
          (v) => v.toLowerCase().contains('gzip'),
        );
    final headers = ProxieHttpHeaders.received({
      for (final e in response.headers.entries)
        if (e.key != HttpHeaders.contentLengthHeader &&
            e.key != HttpHeaders.transferEncodingHeader &&
            (real != null ||
                stillGzipped ||
                e.key != HttpHeaders.contentEncodingHeader))
          e.key: e.value,
      if (!decompressed) HttpHeaders.contentLengthHeader: ['${body.length}'],
    });
    final status = response.statusCode;
    var phrase = response.reasonPhrase;
    if (phrase == null ||
        (real != null &&
            status != real.statusCode &&
            phrase == real.reasonPhrase)) {
      phrase = reasonPhraseFor(status);
    }
    return ProxieClientResponse._(
      null,
      // Single-subscription like a real response; no chunk when empty.
      Stream.fromIterable([if (body.isNotEmpty) body]),
      statusCode: status,
      reasonPhrase: phrase,
      contentLength: decompressed ? -1 : body.length,
      headers: headers,
      compressionState:
          real?.compressionState ??
          (stillGzipped
              ? HttpClientResponseCompressionState.compressed
              : HttpClientResponseCompressionState.notCompressed),
      persistentConnection:
          real?.persistentConnection ?? headers.persistentConnection,
      isRedirect: isRedirectStatus(method, status),
      redirects: List.unmodifiable(real?.redirects ?? const []),
      certificate: real?.certificate,
      connectionInfo: real?.connectionInfo,
    );
  }

  ProxieClientResponse._(
    this._real,
    this._body, {
    required this.statusCode,
    required this.reasonPhrase,
    required this.contentLength,
    required this.headers,
    required this.compressionState,
    required this.persistentConnection,
    required this.isRedirect,
    required this.redirects,
    required this.certificate,
    required this.connectionInfo,
  });

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
