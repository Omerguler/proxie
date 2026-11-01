/// Dio adapter for Proxie: records Dio calls into the Proxie inspector.
///
/// ```dart
/// final dio = Dio();
/// ProxieDio.install(dio);
/// ```
library;

export 'src/proxie_dio_interceptor.dart' show ProxieDio, ProxieDioInterceptor;
