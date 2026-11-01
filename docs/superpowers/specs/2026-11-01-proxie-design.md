# Proxie — Design

Date: 2026-11-01
Owner: Omer Guler (github.com/Omerguler)
Repo: https://github.com/Omerguler/proxie

## 1. Intent

Proxie is an **in-app HTTP inspector and debugger for Flutter**, published on
pub.dev. It gives developers Proxyman-style powers (inspect, breakpoints, Map
Local, copy as cURL) **without a proxy and without installing certificates**.

Why: on company devices behind a corporate VPN, installing a root certificate
or routing traffic through a desktop proxy triggers security reviews or is
outright forbidden. Proxie runs inside the app, hooks the Dart HTTP layer
directly, and therefore needs nothing from the device or the network.

Proxie is a **general-purpose public package**, not tailored to one company's
stack. It must cover the most-used Flutter HTTP clients and be easy to extend.

## 2. Goals

1. Capture every HTTP call made through supported clients and show it in a
   modern, adaptive in-app UI.
2. **Breakpoints**: pause a request before it is sent and/or a response before
   the app receives it; edit method, URL, query, headers, body, status code.
3. **Map Local**: answer matching requests with a stored response, without
   touching the network.
4. **Copy**: copy as cURL, copy request body, copy response body, copy headers,
   copy URL.
5. **Filtering**: text search, method/status/type filters, and hide/collapse
   responses that are too large or binary.
6. **Fast JSON viewing and editing** at multi-megabyte sizes, including a
   schema-aware tree editor.
7. **Persistent history**: captured traffic survives app restarts so past
   requests can be turned into rules.
8. **Extensible by adapters**: adding a new HTTP client or router means adding
   one file (or one small package) with minimal changes elsewhere.
9. **Zero impact on the host app's performance**: heavy work runs in a worker
   isolate.

## 3. Non-goals

- Not a system-wide proxy; does not see traffic from other apps.
- Does not see traffic that bypasses Dart's HTTP stack (WebViews, native SDKs,
  `cronet_http`, `cupertino_http`, platform channels). Documented clearly.
- No remote/desktop companion app in v1.
- No WebSocket / gRPC inspection in v1.
- No HAR import/export in v1 (good later addition; the data model must not
  prevent it).

## 4. Anti-goals (failure even if it "works")

- Proxie noticeably slows down or janks the host app.
- Installing Proxie forces unrelated heavy dependencies (Dio, codegen, native
  database binaries needing setup) onto apps that don't use them, or causes
  version-resolution conflicts.
- Proxie is accidentally active in a production/release build.
- Opening a 2–10 MB JSON response freezes the UI.
- Proxie breaks or pollutes the host app's navigation stack or theme.

## 5. Constraints

- Flutter stable 3.47.x / Dart 3.13.x (current toolchain on the dev machine).
- Platforms: Android, iOS, macOS, Windows, Linux, Web. On web, `dart:io`
  `HttpOverrides` does not exist; capture there works only through the `http`
  and Dio adapters. Storage on web falls back as described in §9.
- Published to pub.dev under package names `proxie` and `proxie_dio` (both
  verified free on 2026-11-01).
- License: MIT (my call).
- Only Proxie's own dependencies: `sqlite3` (3.x, uses build hooks — no setup
  for users), `http`, `path_provider`. `proxie_dio` adds only `dio`.
  No code generation required of users.

## 6. Package layout (decided)

One GitHub repo, Dart pub workspace (monorepo):

```
proxie/                      (repo root, workspace)
  packages/
    proxie/                  core + UI + storage + dart:io adapter + http adapter
    proxie_dio/              Dio interceptor adapter
  example/                   Flutter example app using all adapters
  docs/
```

Rationale (agreed with owner): Dart has no optional dependencies, so a single
package depending on Dio would force Dio onto every user and risk version
conflicts. Users still get a single-call setup.

## 7. Public API shape

```dart
void main() {
  Proxie.init(
    adapters: [ProxieHttpOverridesAdapter()],   // dart:io HttpClient (default)
    navigation: ProxieNavigation.overlay(),     // default; or .navigatorKey(key)
    enabled: kDebugMode,                        // default
  );
  runApp(MyApp());
}

MaterialApp(
  builder: Proxie.wrap,   // draws bubble + inspector overlay
  ...
);

// http package
final client = Proxie.httpClient(inner: http.Client());

// Dio (proxie_dio)
dio.interceptors.add(ProxieDioInterceptor());
```

Exact names are the builder's call as long as setup stays this small.

## 8. Architecture

### 8.1 Layers

1. **Core engine** (no knowledge of any HTTP client): the canonical data model
   (`ProxieRequest`, `ProxieResponse`, `ProxieCall`), rule matching
   (breakpoints, Map Local), filter/size/binary policy, event stream.
2. **Capture adapters** — one file each, implementing a small interface:
   convert client request → `ProxieRequest`, ask the engine for a decision
   (`proceed(editedRequest)`, `mockResponse(response)`, `abort(error)`), then
   convert the real/edited/mocked `ProxieResponse` back to the client's type.
   v1 set:
   - `ProxieHttpOverridesAdapter` — `dart:io` `HttpClient` via `HttpOverrides`.
     Also catches libraries built on `HttpClient`.
   - `ProxieHttpClient` — wraps `package:http` `Client` (works on web).
   - `ProxieDioInterceptor` (package `proxie_dio`) — Dio interceptor (works on
     web).
   - GraphQL / Chopper / Retrofit are covered transitively through Dio/http.
3. **Navigation adapters** — how the inspector screen is shown:
   - `overlay` (default): Proxie draws its own `Overlay` inside `Proxie.wrap`;
     needs no router, cannot disturb the host navigation stack.
   - `navigatorKey(key)`: push Proxie routes through the host's root navigator.
     Works for GoRouter and AutoRoute because both accept a `navigatorKey`.
   - `custom(push: ..., pop: ...)`: callbacks for anything else.
   Adding a router = one new file implementing the interface.
4. **Worker isolate** — long-lived; owns SQLite, JSON parsing, schema
   inference, search, filtering, body spill files. The UI isolate sends small
   messages ("rows 40–80 matching filter F", "node X of call Y") and receives
   small results. Capture adapters on the UI isolate only forward metadata and
   body bytes (transferred, not copied, where possible via
   `TransferableTypedData`).
5. **UI** — renders only from the canonical model; list columns and detail
   tabs are registered sections so features/adapters can add their own.

### 8.2 Breakpoint flow

1. Adapter builds `ProxieRequest`, asks engine.
2. Engine matches rules (in-memory copy kept on UI isolate for zero-latency
   matching; source of truth in SQLite).
3. On request-breakpoint match: call is paused (adapter awaits a `Completer`),
   bubble pulses, editor opens automatically via the active navigation adapter.
4. User edits method / URL / query / headers / body, then **Execute**,
   **Abort** (app receives an error), or **Continue unchanged**.
5. Same for response breakpoints: edit status / headers / body before the app
   sees it.
6. Timeout (default 60 s, configurable) → continue unchanged, so a forgotten
   breakpoint never hangs the app forever.

### 8.3 Map Local flow

Rule matches → engine returns stored response (status, headers, body, optional
delay or simulated failure) → adapter returns it as if from the network. Call
is tagged `MAP` in the list.

## 9. Storage (decided: SQLite)

Owner wants history to survive restarts. Chosen over ObjectBox (native libs +
codegen forced on every host app, no web, version clashes), Hive CE (no
queries/indexes), Isar (unmaintained), Drift (codegen, no speed gain).

- `sqlite3` 3.x used synchronously **inside the worker isolate**.
- One DB file `proxie.db` in the app support directory.
- Tables (builder refines): `sessions` (one per app launch), `calls`
  (indexed: session, method, host, status, content type, size, started_at,
  source adapter, tags), `bodies` (small bodies as BLOB; bodies > ~256 KB
  stored as files with a path reference), `rules` (breakpoints, Map Local,
  presets as JSON), FTS5 index over URL + text bodies under a size cap.
- Retention: keep last 5,000 calls or 7 days, whichever first; configurable;
  trimmed in the worker.
- Web: `sqlite3_web` if workable; otherwise in-memory store with the same
  interface (history then does not survive reload on web — acceptable).

## 10. UI

### 10.1 Entry and layout (decided)

- Draggable **floating bubble** with live call count badge; tap → **full-screen
  inspector** (option A from mockups).
- **Adaptive**: phones show list → detail navigation; wide screens (≥ ~700 dp,
  builder may tune) show list + detail **split view**. Reacts live to rotation
  and window resizing.
- Own theme (dark default, light available); never inherits the host theme.

### 10.2 List

- Search box (URL, status, body text via FTS).
- Filter chips: All, JSON, Errors (≥400 or failed), Hide > N MB, Hide binary,
  per-method, per-adapter.
- Row: method badge, path (host on second line or tooltip), status color,
  duration, size, tags (`BREAK`, `MAP`, `EDITED`).
- Grouped by session ("Today 14:02 — 312 calls"); previous sessions available
  after restart.

### 10.3 Detail

Tabs: Response, Request, Headers, Timing. Actions:
- Copy as cURL, copy URL, copy request body, copy response body, copy headers.
- **Map Local from this response** (prefilled, opens editor).
- **Breakpoint on this URL** (prefilled pattern; choose request/response/both).
- Edit & resend.

### 10.4 Large / binary bodies

- Bodies over the render cap (default 5 MB, configurable) are stored but not
  rendered until the user taps "Show".
- Binary detection by content type plus byte sniffing; binary bodies shown as
  hex preview or image preview, never as text.

## 11. JSON viewing and editing (performance-critical)

Owner's prior experience: `re_editor` still struggled at a few MB. Likely cause
(my analysis): minified JSON is one enormous line, and whole-document
highlighting.

- Parse + pretty-print + flatten in the worker isolate for anything > ~100 KB.
- **Tree view is the primary editor**: JSON flattened into an indexed row list;
  virtualized list with fixed row height builds only visible rows; collapsed
  nodes cost nothing; inline value editing; add/delete keys; edits apply as
  small patches to the worker's model, not full re-renders.
- **Schema-aware tree (owner request)**: for each array of objects, infer a
  merged schema (`{id: int, name: string, avatar?: string|null}`); show it on
  the array header; show "missing key" chips on items lacking keys their
  siblings have. One-tap ops: duplicate item, add missing key (type default or
  copy of a sibling value), add key to all items, remove key from all items,
  new item from schema. Inference runs in the worker.
- **Raw text view**: editable with highlighting of visible lines only for
  bodies < ~1 MB; above that, read-only virtualized line viewer with "Edit
  anyway".
- Search runs over the flattened index in the worker and jumps to the row.
- Both views are written in-house; no editor dependency.
- Target: scrolling/expanding a 10 MB JSON stays at 60 fps on a mid-range
  phone; opening it shows the first rows within ~1 s.

## 12. Rules and presets

- Rule match: URL wildcard or regex + optional method + optional host.
  Enable/disable toggle per rule. Persisted in SQLite.
- Built-in Map Local presets: 200 (captured body), 200 empty list, 201, 204,
  400, 401, 403, 404, 422 (field errors), 429 (Retry-After), 500, 503; and
  simulated timeout, no connection, slow network (+N ms).
- Users can save their own presets (e.g. company error envelope).

## 13. Safety

- **Enablement (owner decision 1A)**: active in debug builds by default. In
  profile/release builds Proxie is off unless built with
  `--dart-define=PROXIE=true`. The check is a compile-time constant
  (`bool.fromEnvironment('PROXIE')`) so that without the flag the capture,
  storage and UI code is tree-shaken out of release builds. When disabled,
  adapters are pass-through and nothing is built or stored.
- **Sensitive data (owner decision 2A)**: values are masked **before they are
  stored** (and therefore also in display and cURL copy), using a configurable
  list. Defaults: headers `Authorization`, `Cookie`, `Set-Cookie`,
  `Proxy-Authorization`; JSON body keys `password`, `token`, `access_token`,
  `refresh_token`, `secret` (case-insensitive). Plus a `persistHistory: false`
  switch that keeps traffic in memory only. No database encryption in v1.
  Note: masking applies to stored/displayed copies only; the live request the
  app sends is never altered by masking.

## 14. Testing and verification

- Unit tests (core engine, rule matching, cURL generation, schema inference,
  JSON flattening, storage) — TDD.
- Adapter tests against a local `HttpServer`.
- Widget tests for list/detail/editor, phone and tablet sizes.
- Performance test: open/scroll a generated 10 MB JSON.
- Example app built for web and driven by **Playwright** end-to-end tests
  (semantics enabled); `integration_test` for mobile/tablet.
- Owner asked for a "pstack" verification skill; it is not installed in this
  environment and must be installed by the owner via `/plugin` in an
  interactive Claude terminal. Until then, the superpowers
  verification-before-completion process plus the Playwright suite is used.

## 15. Publishing

- `pubspec.yaml` with repository/homepage/issue_tracker links, topics, screenshots.
- README with setup, adapter table, limitations, GIFs.
- CHANGELOG, LICENSE (MIT), example.
- `dart pub publish --dry-run` must pass with no warnings; target 160/160 pan
  points where achievable.
- Actual `dart pub publish` requires the owner's Google login in the browser;
  owner performs that step.

## 15a. Builder-check decisions (my calls, marked for owner review)

- **Streaming**: calls that match a breakpoint or Map Local rule are fully
  buffered (needed to edit). Calls that match no rule stream through untouched
  while a copy is teed into capture, capped at the render cap (default 5 MB);
  beyond the cap the stored body is marked truncated. SSE / chunked feeds keep
  working.
- **Double capture**: higher-level adapters (http, Dio) tag the request they
  capture (zone value / internal marker) so the `HttpOverrides` adapter skips
  calls already captured. One call = one row, one breakpoint hit.
- **Existing HttpOverrides**: Proxie chains to any `HttpOverrides.current`
  present at init (keeps the app's pinning/proxy settings), never replaces it.
- **Web**: best-effort. No worker isolate on web in v1; heavy work runs on the
  main thread in chunks (yielding between batches). The 60 fps / 10 MB target
  applies to native platforms. A web-worker backend can be added later behind
  the same worker interface.
- **Edit & resend**: replays through the original adapter when it supports
  replay (Dio and http adapters keep a reference to their client, so app
  interceptors/auth apply); otherwise falls back to a plain built-in client and
  says so in the UI.

## 16. Left to the builder

- Exact class/method names, file structure inside packages.
- SQLite schema details and migrations approach.
- Worker message protocol.
- Visual polish details within "dark, modern, colored method/status badges".
- Breakpoint thresholds (split width, size caps) within the stated defaults.
