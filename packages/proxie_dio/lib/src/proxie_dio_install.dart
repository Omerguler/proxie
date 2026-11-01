part of 'proxie_dio_interceptor.dart';

/// Sets Proxie up on a [Dio].
abstract final class ProxieDio {
  /// Adds [interceptor] (a new one by default) to [dio] and wraps
  /// `dio.httpClientAdapter` so the requests it records are not recorded
  /// again by `ProxieHttpOverridesAdapter`. Returns the interceptor; attach
  /// it to an engine to start capturing.
  ///
  /// The interceptor remembers [dio] and replays with it. Installing on a
  /// Dio that already has a [ProxieDioInterceptor] returns that one and
  /// changes nothing. Setting `dio.httpClientAdapter` afterwards removes the
  /// wrapper.
  static ProxieDioInterceptor install(
    Dio dio, {
    ProxieDioInterceptor? interceptor,
  }) {
    final existing = dio.interceptors.whereType<ProxieDioInterceptor>();
    final installed = existing.isEmpty
        ? (interceptor ?? ProxieDioInterceptor())
        : existing.first;
    if (existing.isEmpty) dio.interceptors.add(installed);
    if (dio.httpClientAdapter is! _ProxieMarkingAdapter) {
      dio.httpClientAdapter = _ProxieMarkingAdapter(dio.httpClientAdapter);
    }
    installed._installed = dio;
    return installed;
  }
}

/// Runs the fetches of calls Proxie records (and replays) inside
/// [runMarkedCaptured], so lower-level Proxie adapters skip them; other
/// fetches run as they are.
class _ProxieMarkingAdapter implements HttpClientAdapter {
  _ProxieMarkingAdapter(this.inner);

  final HttpClientAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final extra = options.extra;
    if (extra[_callIdKey] is String || extra[_replayKey] == true) {
      return runMarkedCaptured(
        () => inner.fetch(options, requestStream, cancelFuture),
      );
    }
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
}
