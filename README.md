# Proxie

An HTTP inspector that lives inside your Flutter app: no proxy, no certificates.

| Package | What it is |
|---|---|
| [`proxie`](packages/proxie) | The inspector and the adapters for `dart:io` and `package:http`. Start with [its README](packages/proxie/README.md). |
| [`proxie_dio`](packages/proxie_dio) | The Dio adapter. |
| [`example`](example) | A demo app using all three adapters, and how to run the end-to-end tests. |

Only web and Windows have been run so far.

## Develop

This is a pub workspace, using Flutter 3.47.9.

```sh
flutter pub get
dart analyze
(cd packages/proxie && flutter test)
(cd packages/proxie_dio && flutter test)
(cd example && flutter test)
(cd e2e && npm ci && npx playwright install chromium && npm test)
```

## License

MIT
