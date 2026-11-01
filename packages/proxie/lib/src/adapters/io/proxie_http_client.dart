import 'dart:async';
import 'dart:io';

import '../../core/engine.dart';
import '../capture_marker.dart';
import 'buffered_request.dart';
import 'http_tokens.dart';

/// An [HttpClient] that captures its requests into the engine returned by
/// [engine], delegating everything else to [inner].
///
/// Requests opened while no engine is attached, or inside
/// [runMarkedCaptured] (already captured by a higher-level adapter), are the
/// inner client's own requests, untouched. Others are
/// [BufferedHttpClientRequest]s, which send nothing until closed.
///
/// Because those open their inner request late, [close] keeps `dart:io`'s
/// promise that requests opened before it still complete: a non-forced
/// close stops new requests at once but closes [inner] only after every
/// pending buffered request has opened its inner request (or ended). A
/// forced close aborts pending buffered requests (recorded as cancelled)
/// and force-closes [inner].
class ProxieIoHttpClient implements HttpClient {
  ProxieIoHttpClient(
    this.inner, {
    required ProxieEngine? Function() engine,
    required String adapterName,
  }) : _engineOf = engine,
       _adapterName = adapterName;

  /// The client that sends the requests.
  final HttpClient inner;
  final ProxieEngine? Function() _engineOf;
  final String _adapterName;
  bool _closing = false;
  bool _innerClosed = false;

  /// Buffered requests that may still open a request on [inner].
  final _pending = <BufferedHttpClientRequest>{};
  bool _hasConnectionFactory = false;

  bool get _passThrough => _engineOf() == null || isProxieCaptured();

  @override
  Duration get idleTimeout => inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => inner.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) => inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => inner.autoUncompress;

  @override
  set autoUncompress(bool value) => inner.autoUncompress = value;

  @override
  String? get userAgent => inner.userAgent;

  @override
  set userAgent(String? value) => inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => inner.authenticate = f;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => inner.addCredentials(url, realm, credentials);

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) {
    _hasConnectionFactory = f != null;
    inner.connectionFactory = f;
  }

  @override
  set findProxy(String Function(Uri url)? f) => inner.findProxy = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => inner.authenticateProxy = f;

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => inner.badCertificateCallback = callback;

  @override
  set keyLog(Function(String line)? callback) => inner.keyLog = callback;

  @override
  void close({bool force = false}) {
    _closing = true;
    if (force) {
      for (final request in _pending.toList()) {
        request.abort(
          HttpException('Client closed forcefully', uri: request.uri),
        );
      }
      _pending.clear();
      _closeInner(force: true);
    } else if (_pending.isEmpty) {
      _closeInner(force: false);
    }
  }

  void _settled(BufferedHttpClientRequest request) {
    _pending.remove(request);
    if (_closing && _pending.isEmpty) _closeInner(force: false);
  }

  void _closeInner({required bool force}) {
    if (_innerClosed && !force) return;
    _innerClosed = true;
    inner.close(force: force);
  }

  void _checkOpen() {
    if (_closing) throw StateError('Client is closed');
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) {
    _checkOpen();
    if (_passThrough) return inner.open(method, host, port, path);
    // Splits path, query and fragment like dart:io does.
    var fragmentStart = path.length;
    var queryStart = path.length;
    for (var i = path.length - 1; i >= 0; i--) {
      final char = path.codeUnitAt(i);
      if (char == 0x23) {
        fragmentStart = i;
        queryStart = i;
      } else if (char == 0x3f) {
        queryStart = i;
      }
    }
    String? query;
    if (queryStart < fragmentStart) {
      query = path.substring(queryStart + 1, fragmentStart);
      path = path.substring(0, queryStart);
    }
    return _buffered(
      method,
      Uri(scheme: 'http', host: host, port: port, path: path, query: query),
    );
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    _checkOpen();
    if (_passThrough) return inner.openUrl(method, url);
    return _buffered(method, url);
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('get', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('post', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('put', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('put', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('delete', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('delete', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('patch', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('patch', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('head', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('head', url);

  /// Validates like `dart:io` (throwing synchronously) and returns a request
  /// that sends on close.
  Future<HttpClientRequest> _buffered(String method, Uri url) {
    url = url.removeFragment();
    if (!isHttpToken(method)) throw ArgumentError.value(method, 'method');
    if (method != 'CONNECT') {
      if (url.host.isEmpty) {
        throw ArgumentError('No host specified in URI $url');
      } else if (!_hasConnectionFactory &&
          !url.isScheme('http') &&
          !url.isScheme('https')) {
        throw ArgumentError("Unsupported scheme '${url.scheme}' in URI $url");
      }
    }
    final request = BufferedHttpClientRequest(
      method: method.toUpperCase(),
      uri: url,
      inner: inner,
      engine: _engineOf,
      adapterName: _adapterName,
      onSettled: _settled,
    );
    _pending.add(request);
    return Future.value(request);
  }
}
