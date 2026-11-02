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
  /// Creates a query; with no arguments it matches every call.
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

  /// Which outcomes to keep.
  final StatusFilter status;

  /// Keep only calls whose response body is JSON.
  final bool onlyJson;

  /// Drop calls whose response body is binary or an image.
  final bool hideBinary;

  /// Drop calls whose response body is larger than this many bytes.
  final int? maxSize;

  /// Keep only calls from this session; null keeps all sessions.
  final int? sessionId;

  /// Adapter names to keep. Empty keeps all.
  final Set<String> adapters;

  /// A copy with the given filters replaced; the `clear` flags reset the
  /// nullable ones to null.
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
  /// Creates a summary; most callers use [CallSummary.fromCall].
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

  /// The summary of [call].
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

  /// The call's id.
  final String id;

  /// The session the call was recorded in.
  final int sessionId;

  /// The request method, such as `GET`.
  final String method;

  /// The request URL as text.
  final String url;

  /// Null while pending, or when the call failed without a response.
  final int? statusCode;

  /// Milliseconds from start to outcome; null while pending.
  final int? durationMs;

  /// Response body length on the wire; 0 without a response.
  final int responseSize;

  /// Response body kind; [BodyKind.empty] without a response.
  final BodyKind kind;

  /// What Proxie did to the call, such as breakpoint or Map Local.
  final Set<CallTag> tags;

  /// When the request started.
  final DateTime startedAt;

  /// The name of the adapter that captured the call.
  final String adapter;

  /// Whether the call ended with an error.
  final bool hasError;
}
