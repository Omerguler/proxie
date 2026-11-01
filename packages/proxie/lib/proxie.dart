/// Proxie: in-app HTTP inspector for Flutter.
library;

export 'src/adapters/capture_adapter.dart';
export 'src/adapters/capture_marker.dart';
export 'src/adapters/http_client_adapter.dart';
export 'src/adapters/http_overrides_stub.dart'
    if (dart.library.io) 'src/adapters/http_overrides_adapter.dart';
export 'src/core/body_classifier.dart' show classifyBody;
export 'src/config.dart';
export 'src/core/breakpoint_controller.dart';
export 'src/core/curl.dart';
export 'src/core/decision.dart';
export 'src/core/engine.dart';
export 'src/core/masking.dart';
export 'src/core/presets.dart';
export 'src/core/rule.dart';
export 'src/core/url_matcher.dart';
export 'src/json/json_commands.dart';
export 'src/json/json_document.dart';
export 'src/json/json_row.dart';
export 'src/model/body.dart';
export 'src/model/call.dart';
export 'src/model/request.dart' hide normalizeHeaders, copyHeaders;
export 'src/model/response.dart';
export 'src/storage/call_query.dart';
export 'src/storage/memory_store.dart';
export 'src/storage/store.dart';
export 'src/worker/commands.dart';
export 'src/worker/worker.dart';
export 'src/worker/worker_factory.dart';

/// Current package version.
const kProxieVersion = '0.1.0';
