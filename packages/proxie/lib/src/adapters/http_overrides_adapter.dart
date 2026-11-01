import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/engine.dart';
import '../model/body.dart';
import '../model/request.dart';
import '../model/response.dart';
import 'capture_adapter.dart';
import 'capture_marker.dart';
import 'io/proxie_http_client.dart';
import 'io/http_tokens.dart';

/// Captures every `dart:io` [HttpClient] the app creates, and so every
/// library built on it, by installing an [HttpOverrides] as
/// [HttpOverrides.global].
///
/// [attach] chains to the overrides current at that time (keeping the app's
/// own client setup, such as certificate pinning or a user agent) and
/// [detach] restores them. While detached every client and request is a
/// pure pass-through, including ones created while attached.
///
/// Limitations:
/// - Code running inside [HttpOverrides.runZoned] with its own overrides
///   bypasses capture.
/// - Requests are buffered until `close()`, so connection errors surface
///   from `close()` rather than from opening the request.
/// - A streamed response the app never listens to leaves the call pending.
/// - `abort()` before `close()` sends and records nothing.
class ProxieHttpOverridesAdapter implements ProxieCaptureAdapter {
  _ProxieHttpOverrides? _overrides;
  ProxieEngine? _engine;

  @override
  String get name => 'io';

  @override
  bool get supportsReplay => true;

  @override
  void attach(ProxieEngine engine) {
    _engine = engine;
    final current = _overrides;
    if (current != null) {
      current.engine = engine;
      return;
    }
    final overrides = _ProxieHttpOverrides(HttpOverrides.current, name)
      ..engine = engine;
    _overrides = overrides;
    HttpOverrides.global = overrides;
  }

  @override
  void detach() {
    _engine = null;
    final overrides = _overrides;
    if (overrides == null) return;
    _overrides = null;
    // Clients it created stay pass-through for good.
    overrides.engine = null;
    // Restore only if nobody replaced the global overrides since.
    if (identical(_globalOverrides(), overrides)) {
      HttpOverrides.global = overrides.previous;
    }
  }

  /// Sends [request] with a fresh client from the overrides Proxie chains to
  /// (not captured) and returns the full response.
  ///
  /// The `host` header is left to the client, since the URL may have been
  /// edited; `content-length` is the body's length.
  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    if (request.body.truncated) {
      throw StateError('Cannot replay: request body was truncated');
    }
    final cap = _engine?.config.teeCap ?? defaultBodyCap;
    return runMarkedCaptured(() async {
      final client = _overrides?.createInner(null) ?? HttpClient();
      try {
        final out = await client.openUrl(request.method, request.url);
        for (final e in request.headers.entries) {
          if (e.key == HttpHeaders.contentLengthHeader ||
              e.key == HttpHeaders.transferEncodingHeader ||
              e.key == HttpHeaders.hostHeader) {
            continue;
          }
          out.headers.set(e.key, e.value);
        }
        final bytes = request.body.bytes;
        out.contentLength = bytes.length;
        if (bytes.isNotEmpty) out.add(bytes);
        final res = await out.close();
        final body = await res.fold(
          BytesBuilder(copy: false),
          (b, chunk) => b..add(chunk),
        );
        return ProxieResponse(
          statusCode: res.statusCode,
          reasonPhrase: res.reasonPhrase,
          headers: headersToMap(res.headers),
          body: ProxieBody.from(
            body.takeBytes(),
            res.headers[HttpHeaders.contentTypeHeader]?.first,
            cap: cap,
          ),
        );
      } finally {
        client.close();
      }
    });
  }
}

/// The global overrides as set, ignoring any zone overrides.
HttpOverrides? _globalOverrides() => Zone.root.run(() => HttpOverrides.current);

class _ProxieHttpOverrides extends HttpOverrides {
  _ProxieHttpOverrides(this.previous, this.adapterName);

  /// The overrides current when attached; null for `dart:io`'s default.
  final HttpOverrides? previous;
  final String adapterName;

  /// The engine clients from these overrides capture into; null once
  /// detached.
  ProxieEngine? engine;

  /// A client as [previous] (or `dart:io`) would create it.
  HttpClient createInner(SecurityContext? context) =>
      previous?.createHttpClient(context) ?? super.createHttpClient(context);

  @override
  HttpClient createHttpClient(SecurityContext? context) => ProxieIoHttpClient(
    createInner(context),
    engine: () => engine,
    adapterName: adapterName,
  );

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}
