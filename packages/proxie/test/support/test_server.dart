import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A local HTTP server for adapter tests.
///
/// Routes:
/// - `/json` → `{"hello":"world"}`
/// - `/echo` → JSON `{method, uri, headers, body}` (body is the UTF-8 request
///   body)
/// - `/big?mb=N` → N MB of `a` in 64 KB chunks, `text/plain`
/// - `/status/<code>` → that status with a JSON body
/// - `/redirect` → 302 to the absolute `/json` URL
/// - `/cookies` → two `Set-Cookie` headers (one with an `Expires` date)
/// - `/stream` → `text/plain` chunks of 1 KB every 10 ms for up to 10 s (or
///   until the server closes)
/// - `/drop` → promises 100 bytes of `text/plain`, sends `partial`, then
///   closes the connection
class TestServer {
  TestServer._(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  /// Requests received, by path.
  final hits = <String, int>{};

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  int hitsFor(String path) => hits[path] ?? 0;

  /// Completes once no client connection is open, or throws a [StateError]
  /// after [timeout].
  Future<void> waitForNoConnections({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final sw = Stopwatch()..start();
    while (_server.connectionsInfo().total > 0) {
      if (sw.elapsed > timeout) throw StateError('Connections still open');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  var _closed = false;

  Future<void> close() {
    _closed = true;
    return _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    hits[path] = hitsFor(path) + 1;
    final res = req.response;
    try {
      final body = await req.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (b, chunk) => b..add(chunk),
      );
      if (path == '/json') {
        res.headers.contentType = ContentType.json;
        res.write('{"hello":"world"}');
      } else if (path == '/echo') {
        final headers = <String, String>{};
        req.headers.forEach((name, values) => headers[name] = values.join(','));
        res.headers.contentType = ContentType.json;
        res.write(
          jsonEncode({
            'method': req.method,
            'uri': req.uri.toString(),
            'headers': headers,
            'body': utf8.decode(body.takeBytes(), allowMalformed: true),
          }),
        );
      } else if (path == '/big') {
        final mb = int.parse(req.uri.queryParameters['mb'] ?? '1');
        res.headers.contentType = ContentType.text;
        res.contentLength = mb * 1024 * 1024;
        final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 0x61);
        for (var i = 0; i < mb * 16; i++) {
          res.add(chunk);
          await res.flush();
        }
      } else if (path == '/redirect') {
        res.statusCode = HttpStatus.found;
        res.headers.set(HttpHeaders.locationHeader, url('/json').toString());
      } else if (path == '/cookies') {
        res.headers
          ..add('set-cookie', 'a=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT')
          ..add('set-cookie', 'b=2');
        res.headers.contentType = ContentType.text;
        res.write('ok');
      } else if (path == '/stream') {
        res.headers.contentType = ContentType.text;
        final chunk = Uint8List(1024)..fillRange(0, 1024, 0x62);
        for (var i = 0; i < 1000 && !_closed; i++) {
          res.add(chunk);
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      } else if (path == '/drop') {
        final socket = await res.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\ncontent-length: 100\r\n'
          'content-type: text/plain\r\n\r\npartial',
        );
        await socket.flush();
        socket.destroy();
        return;
      } else if (path.startsWith('/status/')) {
        final code = int.parse(path.substring('/status/'.length));
        res.statusCode = code;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'status': code}));
      } else {
        res.statusCode = HttpStatus.notFound;
      }
      await res.close();
    } catch (_) {
      // The client went away mid-response; nothing to do.
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

/// Starts a [TestServer] on 127.0.0.1 with an ephemeral port.
Future<TestServer> startTestServer() async =>
    TestServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
