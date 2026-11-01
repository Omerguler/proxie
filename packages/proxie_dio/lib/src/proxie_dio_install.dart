part of 'proxie_dio_interceptor.dart';

/// Sets Proxie up on a [Dio].
abstract final class ProxieDio {
  /// Sets [interceptor] (a new one by default) up on [dio] and returns it;
  /// attach it to an engine to start capturing.
  ///
  /// - The interceptor is added at the end of `dio.interceptors`, so requests
  ///   are recorded (and paused, mocked or edited) as the app's interceptors
  ///   left them.
  /// - A response and error observer is inserted at the front, so responses
  ///   and errors are recorded (and paused or edited) before the app's
  ///   interceptors, such as retry or auth refresh, act on them.
  /// - `dio.httpClientAdapter` is wrapped so the requests Proxie records are
  ///   not recorded again by `ProxieHttpOverridesAdapter`.
  ///
  /// The interceptor remembers [dio] and replays with it. Install after
  /// adding the app's own interceptors: one added later runs after Proxie's
  /// request side, and if it answers requests itself without calling the
  /// following interceptors (a cache, say) those calls stay pending.
  ///
  /// Installing again is a no-op that returns the installed interceptor;
  /// passing a different [interceptor] then throws an [ArgumentError].
  /// Setting `dio.httpClientAdapter` afterwards removes the adapter wrapper;
  /// install again to restore it.
  static ProxieDioInterceptor install(
    Dio dio, {
    ProxieDioInterceptor? interceptor,
  }) {
    final existing = dio.interceptors.whereType<ProxieDioInterceptor>();
    final ProxieDioInterceptor installed;
    if (existing.isEmpty) {
      installed = interceptor ?? ProxieDioInterceptor();
      dio.interceptors.add(installed);
    } else {
      installed = existing.first;
      if (interceptor != null && !identical(interceptor, installed)) {
        throw ArgumentError.value(
          interceptor,
          'interceptor',
          'This Dio already has a different ProxieDioInterceptor',
        );
      }
    }
    final observed = dio.interceptors.whereType<_ProxieDioObserver>().any(
      (o) => identical(o.target, installed),
    );
    if (!observed) dio.interceptors.insert(0, _ProxieDioObserver(installed));
    if (dio.httpClientAdapter is! _ProxieMarkingAdapter) {
      dio.httpClientAdapter = _ProxieMarkingAdapter(dio.httpClientAdapter);
    }
    installed._installed = dio;
    return installed;
  }
}

/// Records responses and errors for [target] from the front of the
/// interceptor list; requests pass straight on.
///
/// Once it has handled a call the call id is gone, so [target]'s own
/// response and error callbacks pass that call through.
class _ProxieDioObserver extends Interceptor {
  _ProxieDioObserver(this.target);

  final ProxieDioInterceptor target;

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) => target._observeResponse(response, handler);

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) =>
      target._observeError(err, handler);
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
