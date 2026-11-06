# Proxie

An HTTP inspector that lives inside your Flutter app. It records your app's
calls and lets you search them, read the JSON, mock a response, pause a call at
a breakpoint and send it again. All of it happens on the device.

There is no proxy to run and no certificate to install, because Proxie sits in
your app's HTTP client rather than on the network. That also sets its limit: it
only sees traffic that goes through a client it wraps
([limitations](#limitations)).

![Call list and JSON response](https://raw.githubusercontent.com/Omerguler/proxie/main/packages/proxie/doc/screenshots/dark-03-list-detail-json-1280.png)

## What it does

- **Call list**: search URLs and bodies, filter by method, errors, JSON, binary
  or size. History survives restarts on native platforms.
- **Call detail**: JSON tree with search, raw text, images, headers, a timing
  view, and copy as cURL.
- **Map Local**: answer matching calls locally with a saved response, a delay or
  a simulated failure.
- **Breakpoints**: pause a request or a response, edit it, then execute, continue
  or abort. A call nobody acts on continues unchanged after 60 seconds, so your
  app never hangs.
- **Edit & resend**: change a recorded request and send it again as a new call.
- **Masking**: sensitive headers and JSON values are replaced in everything
  Proxie stores or shows. Live traffic is never changed.

## Install

```sh
flutter pub add proxie
```

Add `proxie_dio` too if you use Dio. Proxie needs Flutter 3.38 or later.

## Setup

```dart
import 'package:flutter/material.dart';
import 'package:proxie/proxie.dart';

void main() {
  Proxie.init(adapters: [ProxieHttpOverridesAdapter()]);
  runApp(MaterialApp(builder: Proxie.wrap, home: const Home()));
}
```

That's the whole setup. A bubble appears over your app; tap it to open the
inspector, or call `Proxie.open()`. Call `init` before `runApp`, and there's no
need to await it.

`ProxieHttpOverridesAdapter` needs `dart:io`, so it records nothing on the web.
Use one of the adapters below there.

## Adapters

| Client | Use | From | Platforms |
|---|---|---|---|
| `dart:io` `HttpClient`, and libraries built on it | `ProxieHttpOverridesAdapter()` | `proxie` | Native. Does nothing on the web. |
| `package:http` | `Proxie.httpClient()` or `ProxieHttpClient(inner: ...)` | `proxie` | All |
| Dio | `ProxieDio.install(dio)` | `proxie_dio` | All |
| Anything else | [your own adapter](#add-a-capture-adapter) | your code | Up to you |

You can combine them, and a call is still recorded once.

```dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:proxie/proxie.dart';
import 'package:proxie_dio/proxie_dio.dart';

final dio = Dio();
final http.Client client = Proxie.httpClient();

void main() {
  // Add your own Dio interceptors before this line.
  final dioAdapter = ProxieDio.install(dio);
  Proxie.init(adapters: [ProxieHttpOverridesAdapter(), dioAdapter]);
  runApp(MaterialApp(builder: Proxie.wrap, home: const Home()));
}
```

A client from `Proxie.httpClient()` records calls without being listed in
`adapters`, but Edit & resend then uses Proxie's built-in client, which skips
anything your own client does. To resend through your client, create a
`ProxieHttpClient` and list it in `adapters`.

## Navigation

By default the inspector is drawn above your whole app and never touches your
navigation stack. Three other options exist:

```dart
// Push onto your navigator. GoRouter and AutoRoute expose the key this needs.
Proxie.init(navigation: ProxieNavigation.navigatorKey(rootKey));

// Show and remove the page your own way.
Proxie.init(
  navigation: ProxieNavigation.custom(
    push: showPage,
    pop: hidePage,
  ),
);

// Use your own adapter (below).
Proxie.init(navigation: ProxieNavigation.adapter(MyNavigation(rootKey)));
```

In overlay mode, add `Proxie.navigatorObserver` to your root navigator's
observers if your app uses predictive back page transitions, or if it calls
`init` after `runApp`. Otherwise a back gesture can pop your route as well as
closing the inspector.

## Extend it in one file

### Add a capture adapter

Implement `ProxieCaptureAdapter` from `package:proxie/adapter.dart`. This one
covers a client that takes a `ProxieRequest` and returns a `ProxieResponse`; a
real adapter also converts to and from its client's own types, using
`ProxieBody.from` for the bodies.

```dart
import 'package:proxie/adapter.dart';

class MyClientAdapter implements ProxieCaptureAdapter {
  MyClientAdapter(this._send);

  final Future<ProxieResponse> Function(ProxieRequest) _send;
  ProxieEngine? _engine;

  @override
  String get name => 'my_client';

  @override
  bool get supportsReplay => true;

  @override
  void attach(ProxieEngine engine) => _engine = engine;

  @override
  void detach() => _engine = null;

  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    if (request.body.truncated) {
      throw StateError('Cannot replay: request body was truncated');
    }
    return runMarkedCaptured(() => _send(request));
  }

  @override
  ProxieError classifyReplayError(Object error) => defaultReplayError(error);

  /// What your app calls instead of the client.
  Future<ProxieResponse> send(ProxieRequest request) async {
    final engine = _engine;
    if (engine == null) return _send(request);
    final id = engine.newCallId();
    switch (await engine.onRequest(id, name, request)) {
      case AbortRequest(:final error):
        throw Exception(error.message);
      case MockDecision(:final action):
        await Future<void>.delayed(action.delay);
        if (action.failure case final failure?) {
          final error = ProxieError(type: failure.name, message: 'Simulated');
          engine.onError(id, error);
          throw Exception(error.message);
        }
        return engine.onResponse(
          id,
          action.response ??
              ProxieResponse(
                statusCode: 200,
                headers: const {},
                body: ProxieBody.empty(),
              ),
        );
      case Proceed(request: final edited):
        final ProxieResponse response;
        try {
          response = await runMarkedCaptured(() => _send(edited));
        } on Object catch (error) {
          engine.onError(id, classifyReplayError(error));
          rethrow;
        }
        // Throws ProxieAbortedException if a breakpoint aborts the response.
        return engine.onResponse(id, response);
    }
  }
}
```

Then pass it in: `Proxie.init(adapters: [MyClientAdapter(mySend)])`.

### Add a navigation adapter

```dart
import 'package:flutter/material.dart';
import 'package:proxie/proxie.dart';

class MyNavigation implements ProxieNavigationAdapter {
  MyNavigation(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  Route<void>? _route;

  @override
  bool get isShowing => _route != null;

  @override
  void show(Widget inspector, {required VoidCallback onDismissed}) {
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      onDismissed();
      return;
    }
    final route = MaterialPageRoute<void>(builder: (_) => inspector);
    _route = route;
    // Runs when the page goes away. If hide() did that, _route has changed.
    navigator.push(route).whenComplete(() {
      if (identical(_route, route)) {
        _route = null;
        onDismissed();
      }
    });
  }

  @override
  void hide() {
    final route = _route;
    _route = null;
    if (route != null) route.navigator?.removeRoute(route);
  }
}
```

### Add a detail tab or a list badge

```dart
import 'package:flutter/material.dart';
import 'package:proxie/proxie.dart';

void registerProxieExtras() {
  ProxieSections.addDetailTab(
    ProxieDetailTab(
      id: 'trace',
      label: 'Trace',
      appliesTo: (call) => call.request.headers.containsKey('x-trace-id'),
      build: (context, call) =>
          SelectableText(call.request.headers['x-trace-id']!.join('\n')),
    ),
  );
  ProxieSections.addListBadge(
    ProxieListBadge(
      id: 'server-error',
      label: (call) => (call.statusCode ?? 0) >= 500 ? 'SERVER' : null,
    ),
  );
}
```

## Release builds

Proxie is on in debug builds only. In profile and release builds every entry
point does nothing, and the compiler removes Proxie's Dart code. To use it in
such a build, for an internal test build say, add the flag:

```sh
flutter build apk --dart-define=PROXIE=true
```

Don't ship that flag to users: anyone holding the app could open the inspector.
To turn Proxie off at runtime, use `Proxie.init(enabled: false)`; this can only
disable it, never enable it in a build without the flag.

The `sqlite3` native library is a dependency, so it stays in your build even
when Proxie is off. It's about 1.7 MB in a Windows release build. If that
matters, keep Proxie out of your release flavor's dependencies.

## Masking

By default these are replaced with `••••••` in stored and shown copies:

- **Headers**: `Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization`
- **JSON keys, at any depth**: `password`, `token`, `access_token`,
  `refresh_token`, `secret`

Names are case-insensitive. To add your own, include the defaults or they are
replaced:

```dart
Proxie.init(
  adapters: [ProxieHttpOverridesAdapter()],
  config: ProxieConfig(
    masking: ProxieMasking(
      headers: {...ProxieMasking.defaults.headers, 'X-Api-Key'},
      jsonKeys: {...ProxieMasking.defaults.jsonKeys, 'pin'},
    ),
  ),
);
```

Only those headers and JSON values are masked. **URLs, including query strings,
and non-JSON bodies such as form posts are stored as they are.** Native builds
keep them in a database in the app's support directory. A token in a query
string is therefore on disk until retention removes it; use
`ProxieConfig(persistHistory: false)` to keep history in memory only.

## Other defaults

`ProxieConfig` sets each of these.

| Setting | Default |
|---|---|
| Calls kept (`retentionCalls`, `retentionAge`) | 5,000 calls, 7 days |
| Captured per body (`teeCap`) | 5 MB; the app still gets every byte |
| Largest body rendered (`renderCap`) | 5 MB |
| Bodies editable as raw text (`rawEditableLimit`) | Below 1 MB |
| Bodies stored in files instead of the database (`spillThreshold`) | Over 256 KB |
| Breakpoint timeout (`breakpointTimeout`) | 60 seconds |
| List and detail side by side (`splitWidth`) | From 700 dp |
| Theme (`themeMode`) | Dark. Also light or system; never your app's theme. |

## Platforms

Only web and Windows have been run. The other platforms have never been run, so
treat them as unverified.

| Platform | Status | What that means |
|---|---|---|
| Web | Run in tests | Playwright in Chromium drives a build of the example app. Best-effort; see below. |
| Windows | Run in tests | Integration tests with the real worker isolate, SQLite and sockets. |
| Android, iOS, macOS, Linux | Should work, untested | They use the same native code path as Windows, but nobody has built or run Proxie on them. |

Reports from these platforms are welcome in the
[issue tracker](https://github.com/Omerguler/proxie/issues).

### Web is best-effort

- **No background isolate.** Parsing, search and storage run on the UI thread,
  so large bodies can make the app stutter.
- **No SQLite.** History is kept in memory and is gone after a reload.
  `persistHistory` has no effect.
- **No `dart:io`.** `ProxieHttpOverridesAdapter` does nothing, so use
  `Proxie.httpClient()` or `proxie_dio`.
- **CORS still applies**, because the browser sends the requests. A header you
  add or edit at a breakpoint can fail the preflight, and Proxie only sees the
  response headers the browser exposes. Real CORS behaviour isn't covered by the
  tests, which answer requests from fixtures.
- **No monospace font.** Proxie bundles no fonts, so code text falls back to the
  browser's default sans face.

## Limitations

- **Native and WebView traffic isn't visible.** Proxie sees Dart HTTP clients
  only, so requests made by native SDKs or WebViews never reach it. The same
  goes for native-backed clients such as `cronet_http` and `cupertino_http`,
  unless you wrap them with `ProxieHttpClient(inner: ...)`, which hasn't been
  run.
- **HTTP only.** WebSocket and gRPC calls aren't inspected.
- **Masked values aren't stored, so you retype them.** A Map Local rule made from
  a captured call is pre-filled from the masked copy; the editor warns you but
  still lets you save. Edit & resend refuses a masked header until you retype it,
  and sends a masked JSON body value as it is after a warning.
- **Map Local refuses invalid header names** when you save a rule.
- **Cancel on Edit & resend mostly just stops waiting.** It closes the connection
  only for Proxie's built-in client. Through an adapter the request carries on,
  and either way it may already have reached the server.
- **Resent calls skip your rules**, so no breakpoint or Map Local applies. When
  the original adapter can't resend, the built-in client skips your interceptors
  too.
- **Bodies over 5 MB are stored truncated.** A truncated request body can't be
  resent until you replace it.
- **A streamed response your app never reads stays pending** in the list.
- **Rules set in code aren't saved on their own.** `engine.rules` is live but
  only reaches storage when the inspector next saves a rule.

Dio has limits of its own; see the
[`proxie_dio` README](https://pub.dev/packages/proxie_dio).

## More screenshots

| Paused at a breakpoint | Timing |
|---|---|
| ![Request breakpoint editor](https://raw.githubusercontent.com/Omerguler/proxie/main/packages/proxie/doc/screenshots/dark-18-breakpoint-editor.png) | ![Timing tab](https://raw.githubusercontent.com/Omerguler/proxie/main/packages/proxie/doc/screenshots/dark-05-timing.png) |

| Light theme | Phone width |
|---|---|
| ![Light theme](https://raw.githubusercontent.com/Omerguler/proxie/main/packages/proxie/doc/screenshots/light-03-list-detail-json-1280.png) | ![Call list at phone width](https://raw.githubusercontent.com/Omerguler/proxie/main/packages/proxie/doc/screenshots/dark-21-phone-list.png) |

## Example

The [example app](https://github.com/Omerguler/proxie/tree/main/example) uses all
three adapters, and its README covers running the end-to-end tests.

## License

MIT
