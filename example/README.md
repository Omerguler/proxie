# example

Example app for Proxie. See the [root README](../README.md) for usage.

Each button sends one request and shows the result under it. Together they use
all three capture adapters: `package:http`, Dio and `dart:io` `HttpClient`.
`HttpClient GET` is not available on the web. `Big JSON (5 MB)` is answered
locally by a Map Local rule, which is created the first time you tap it. The
other buttons need network access.

## Run and build

Proxie is on by default only in debug builds. Profile and release builds
capture nothing unless they are built with `--dart-define=PROXIE=true`.

Debug (no flag needed):

```sh
flutter run -d chrome
flutter run -d windows

flutter build web --debug
flutter build windows --debug
```

Profile:

```sh
flutter build web --profile --dart-define=PROXIE=true
flutter build windows --profile --dart-define=PROXIE=true
```

Release:

```sh
flutter build web --release --dart-define=PROXIE=true
flutter build windows --release --dart-define=PROXIE=true
```

Without the flag, a profile or release build shows no bubble and records no
calls. The network buttons still return results, so the app looks like it works,
but `Big JSON (5 MB)` reports that Proxie is not running.

On Windows, building with plugins needs Developer Mode, for symlink support:
run `start ms-settings:developers` to open the setting.

## End-to-end tests

Neither suite needs network access: the requests go to fixed answers in the
browser, or to a local server.

```sh
# Web, in Chromium. Builds the example first, on every run.
cd ../e2e
npm ci
npx playwright install chromium
npx playwright test

# Windows, the only desktop run so far. Overwrites the clipboard.
cd ../example
flutter test integration_test -d windows
```
