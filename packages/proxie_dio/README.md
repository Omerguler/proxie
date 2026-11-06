# proxie_dio

[Dio](https://pub.dev/packages/dio) adapter for [Proxie](https://pub.dev/packages/proxie),
the in-app HTTP inspector for Flutter. Every Dio request and response shows up
in the Proxie overlay, and Proxie's Map Local rules and breakpoints apply to
Dio calls.

## Install

```yaml
dependencies:
  dio: ^5.11.1
  proxie: ^0.1.0
  proxie_dio: ^0.1.0
```

## Use

```dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie_dio/proxie_dio.dart';

final dio = Dio();

void main() {
  // After adding your own interceptors.
  final adapter = ProxieDio.install(dio);
  Proxie.init(adapters: [adapter]);
  runApp(MaterialApp(builder: Proxie.wrap, home: const Home()));
}
```

`ProxieDio.install` adds a `ProxieDioInterceptor` at the end of
`dio.interceptors` and a response/error observer at the front, and wraps the
Dio's `httpClientAdapter`:

- Requests are recorded as your interceptors left them (with the auth header
  your interceptor added, for example), and request breakpoints and mocks act
  on that final request.
- Responses and errors are recorded before your interceptors see them, so a
  retry or auth-refresh interceptor cannot hide the failed attempt: the 401 or
  500 is recorded, and the retried request is recorded as its own call.
- A call is recorded once even when Proxie's `HttpOverrides` adapter is active
  too, and replays go through the same Dio.

Call `install` after adding your own interceptors. An interceptor added later
runs after Proxie's request side; if it answers requests itself without
calling the following interceptors (a cache interceptor serving from its
cache, for example), those calls stay pending in the inspector.
`install` on a Dio that already has a `ProxieDioInterceptor` (added by hand)
reuses it and moves it to the end of the list.

The returned interceptor implements `ProxieCaptureAdapter`: pass it to
`Proxie.init`. It captures from then on, and passes everything through untouched
before that or when Proxie is off. When Proxie is compiled out (a release build
without `--dart-define=PROXIE=true`), `install` leaves your Dio as it found it.

Where it is on, `dio.httpClientAdapter` is Proxie's wrapper, so a cast such as
`dio.httpClientAdapter as IOHttpClientAdapter` fails. Configure the adapter, for
certificate pinning say, before calling `install`.

With several Dios, give each its own name so a resend goes through the one that
made the call, `ProxieDio.install(authDio, name: 'auth')`, and list each in
`Proxie.init`.

You can add the interceptor yourself instead
(`dio.interceptors.add(ProxieDioInterceptor(replayClient: dio))`), but then it
sees responses and errors only when they reach its place in the list: an
interceptor before it that handles an error (a retry, say) hides that attempt,
which is recorded as `superseded` if the same request is sent again. Proxie's
`HttpOverrides` adapter also records each call a second time, and request
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
- Aborts at a breakpoint fail the call with `DioExceptionType.connectionError`
  and the message `Aborted by Proxie`.
- Edit & resend goes through the installed Dio (or `replayClient`) and is recorded
  as a new call with a `REPLAY` chip. The interceptor's `replay` method itself
  records nothing.

## Limitations

- `FormData` and `Stream` request bodies are recorded as a short text
  placeholder (`multipart/form-data: N fields, M files`, `streamed body`) and
  cannot be replayed or edited. Sending such a request on unchanged from a
  breakpoint keeps the original body.
- Edits to a request body stored truncated (over the 5 MB capture cap) are
  ignored and the full original body is sent.
- An edited body that does not decode for the response type (for example
  invalid JSON under a JSON content type) reaches the app as a `String`.
- `ResponseType.stream` responses are not read: the body is recorded empty and
  marked truncated, and response breakpoints do not pause them.
- Response bodies are recorded from Dio's decoded data (decoded JSON is encoded
  again), so formatting may differ from the bytes on the wire.
- Bodies over the capture cap (5 MB) are stored truncated; the app still gets
  the whole body.
- Setting `dio.httpClientAdapter` after `install` removes the wrapper that
  prevents double recording; install again afterwards.
- A call stays pending in the inspector if an interceptor added after
  `install` (or, without `install`, any interceptor after Proxie's) completes
  it without calling the following interceptors, as cache interceptors do.
- Dio cannot hand a response that a breakpoint turned from an error status
  into a success on to later response interceptors; the call completes with
  it directly.
