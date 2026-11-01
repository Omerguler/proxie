## 0.1.0

- Initial release: `ProxieDioInterceptor` records Dio calls into Proxie, with
  Map Local mocks, request and response breakpoints, and replay.
- `ProxieDio.install(dio)` adds the interceptor and keeps the `HttpOverrides`
  adapter from recording the same call twice.
