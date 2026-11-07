## 0.1.0

First release.

- Capture adapters for `dart:io` `HttpClient` (`ProxieHttpOverridesAdapter`) and
  `package:http` (`Proxie.httpClient`, `ProxieHttpClient`). Dio support is in
  `proxie_dio`. Write your own with `package:proxie/adapter.dart`.
- Inspector: call list with search and filters, JSON tree, raw text and image
  views, headers, timing, and copy as cURL.
- Map Local rules and presets, with delays and simulated failures.
- Request and response breakpoints. A call nobody acts on continues unchanged
  after 60 seconds.
- Edit & resend. Resent calls show a `REPLAY` chip and skip your rules.
- Masking of sensitive headers, JSON keys, query parameters and form fields in
  stored and shown copies.
- History in SQLite on a worker isolate on native platforms, and in memory on the
  UI thread on the web.
- Navigation through an overlay (default), a navigator key, your own callbacks or
  a `ProxieNavigationAdapter`.
- Off in profile and release builds unless built with
  `--dart-define=PROXIE=true`.

Behaviour worth knowing:

- Map Local refuses to save invalid header names.
- Masked values are not stored. A rule made from a captured call needs them
  retyped, and Edit & resend refuses a masked header, query value or form field
  until it is retyped.
- Only web and Windows have been run. Android, iOS, macOS and Linux have not.
