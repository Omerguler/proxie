## 0.1.0

- Initial release: `ProxieDioInterceptor` records Dio calls into Proxie, with
  Map Local mocks, request and response breakpoints, and replay.
- `ProxieDio.install(dio)` adds the interceptor and keeps the `HttpOverrides`
  adapter from recording the same call twice. It takes a `name` for apps with
  several Dios, and changes nothing when Proxie is compiled out.
