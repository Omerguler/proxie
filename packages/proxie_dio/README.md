# proxie_dio

[Dio](https://pub.dev/packages/dio) adapter for [Proxie](https://pub.dev/packages/proxie),
the in-app HTTP inspector for Flutter. Every Dio request and response shows up
in the Proxie overlay, and Proxie's Map Local rules and breakpoints apply to
Dio calls.

## Install

```yaml
dependencies:
  dio: ^5.11.0
  proxie: ^0.1.0
  proxie_dio: ^0.1.0
```

## Use

```dart
import 'package:dio/dio.dart';
import 'package:proxie_dio/proxie_dio.dart';

final dio = Dio();
final proxie = ProxieDio.install(dio);
```

`ProxieDio.install` adds a `ProxieDioInterceptor` to the Dio and wraps its
`httpClientAdapter`, so a call is recorded once even when Proxie's
`HttpOverrides` adapter is active too, and replays go through the same Dio.
Install it after the interceptors you want recorded requests to include
(for example one that adds an auth header), since it records what reaches it.

The returned interceptor implements `ProxieCaptureAdapter`: it captures once
it is attached to a Proxie engine and passes everything through untouched
while detached.

You can add the interceptor yourself instead
(`dio.interceptors.add(ProxieDioInterceptor(replayClient: dio))`), but then
Proxie's `HttpOverrides` adapter records each call a second time, and request
bodies are encoded with Dio's default transformer.

## What you get

- Requests and responses with headers and bodies. Request bodies are recorded
  as Dio sends them (JSON, form-urlencoded, strings, bytes).
- Map Local: mocked responses reach the app as real Dio responses, decoded per
  `responseType`; statuses that fail `validateStatus` become
  `DioException.badResponse`. Simulated timeouts and lost connections become
  `DioExceptionType.connectionTimeout` and `connectionError`.
- Breakpoints: edits to the method, URL, headers and body of a request, and to
  the status, headers and body of a response, are what the app and server see.
  A response breakpoint can turn an error status into a success and back.
- Aborts at a breakpoint fail the call with `DioExceptionType.unknown`.
- Replay with the installed Dio (or `replayClient`); replays are not recorded.

## Limitations

- `FormData` and `Stream` request bodies are recorded as a short text
  placeholder (`multipart/form-data: N fields, M files`, `streamed body`) and
  cannot be replayed. Sending such a request on unchanged from a breakpoint
  keeps the original body.
- `ResponseType.stream` responses are not read: the body is recorded empty and
  marked truncated, and response breakpoints do not pause them.
- Response bodies are recorded from Dio's decoded data (decoded JSON is encoded
  again), so formatting may differ from the bytes on the wire.
- Bodies over the capture cap (5 MB) are stored truncated; the app still gets
  the whole body.
- Setting `dio.httpClientAdapter` after `install` removes the wrapper that
  prevents double recording; install again afterwards.
- A call stays pending in the inspector if another interceptor completes it
  without calling the interceptors after it.
