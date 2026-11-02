import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';

/// Which outcomes a [CallQuery] keeps.
enum StatusFilter {
  /// No filtering by outcome.
  all,

  /// Responses with status 200-399 and no error.
  success,

  /// Responses with status >= 400, or calls that failed with an error.
  errors,
}

/// Filters for listing calls. Unset or empty filters match everything.
class CallQuery {
  const CallQuery({
    this.text,
    this.methods = const {},
    this.status = StatusFilter.all,
    this.onlyJson = false,
    this.hideBinary = false,
    this.maxSize,
    this.sessionId,
    this.adapters = const {},
  });

  /// Case-insensitive substring searched in the URL and in the response body
  /// when its kind is text or json (never binary or image bodies). Every
  /// store must do both. Null or empty means no text filter.
  final String? text;

  /// HTTP methods to keep, compared case-insensitively. Empty keeps all.
  final Set<String> methods;
  final StatusFilter status;

  /// Keep only calls whose response body is JSON.
  final bool onlyJson;

  /// Drop calls whose response body is binary or an image.
  final bool hideBinary;

  /// Drop calls whose response body is larger than this many bytes.
  final int? maxSize;
  final int? sessionId;

  /// Adapter names to keep. Empty keeps all.
  final Set<String> adapters;

  CallQuery copyWith({
    String? text,
    bool clearText = false,
    Set<String>? methods,
    StatusFilter? status,
    bool? onlyJson,
    bool? hideBinary,
    int? maxSize,
    bool clearMaxSize = false,
    int? sessionId,
    bool clearSessionId = false,
    Set<String>? adapters,
  }) => CallQuery(
    text: clearText ? null : (text ?? this.text),
    methods: methods ?? this.methods,
    status: status ?? this.status,
    onlyJson: onlyJson ?? this.onlyJson,
    hideBinary: hideBinary ?? this.hideBinary,
    maxSize: clearMaxSize ? null : (maxSize ?? this.maxSize),
    sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
    adapters: adapters ?? this.adapters,
  );
}

/// The list-row view of a call: everything but the bodies.
class CallSummary {
  const CallSummary({
    required this.id,
    required this.sessionId,
    required this.method,
    required this.url,
    required this.statusCode,
    required this.durationMs,
    required this.responseSize,
    required this.kind,
    required this.tags,
    required this.startedAt,
    required this.adapter,
    this.hasError = false,
  });

  factory CallSummary.fromCall(ProxieCall call) {
    final body = call.response?.body;
    return CallSummary(
      id: call.id,
      sessionId: call.sessionId,
      method: call.request.method,
      url: call.request.url.toString(),
      statusCode: call.response?.statusCode,
      durationMs: call.duration?.inMilliseconds,
      responseSize: body?.originalLength ?? 0,
      kind: body?.kind ?? BodyKind.empty,
      tags: Set.unmodifiable(call.tags),
      startedAt: call.startedAt,
      adapter: call.adapter,
      hasError: call.error != null,
    );
  }

  final String id;
  final int sessionId;
  final String method;
  final String url;

  /// Null while pending, or when the call failed without a response.
  final int? statusCode;
  final int? durationMs;

  /// Response body length on the wire; 0 without a response.
  final int responseSize;

  /// Response body kind; [BodyKind.empty] without a response.
  final BodyKind kind;
  final Set<CallTag> tags;
  final DateTime startedAt;
  final String adapter;
  final bool hasError;
}
