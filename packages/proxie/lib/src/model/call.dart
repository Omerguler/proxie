import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// Markers describing how a call was handled.
enum CallTag {
  /// The call was paused at a breakpoint.
  breakpoint,

  /// The call was answered by a Map Local rule.
  mapLocal,

  /// The request or response was changed at a breakpoint, or a replayed
  /// request was changed before it was sent.
  edited,

  /// A new call made by sending an earlier call's request again from the
  /// inspector's "Edit & resend"; no rules apply to it.
  replayed,

  /// A body was cut at the capture cap.
  truncated,
}

/// A transport-level failure of a call.
class ProxieError {
  /// Creates an error of kind [type] with a readable [message].
  const ProxieError({required this.type, required this.message});

  /// Decodes an error written by [toMap].
  factory ProxieError.fromMap(Map<dynamic, dynamic> map) => ProxieError(
    type: map['type'] as String,
    message: map['message'] as String,
  );

  /// The kind of failure, such as `timeout`, `no_connection`, `aborted`,
  /// `cancelled` or `stream_error`.
  final String type;

  /// A description of the failure for people.
  final String message;

  /// Encodes this error as plain data for storage and isolate messages.
  Map<String, Object?> toMap() => {'type': type, 'message': message};
}

/// One captured request/response exchange.
class ProxieCall {
  /// Creates a call record; [tags] is copied into an unmodifiable set.
  ProxieCall({
    required this.id,
    required this.sessionId,
    required this.adapter,
    required this.request,
    required this.startedAt,
    this.response,
    this.error,
    this.duration,
    Set<CallTag> tags = const {},
  }) : tags = Set.unmodifiable(tags);

  /// Decodes a call written by [toMap].
  factory ProxieCall.fromMap(Map<dynamic, dynamic> map) {
    final response = map['response'] as Map?;
    final error = map['error'] as Map?;
    final micros = map['durationMicros'] as int?;
    return ProxieCall(
      id: map['id'] as String,
      sessionId: map['sessionId'] as int,
      adapter: map['adapter'] as String,
      request: ProxieRequest.fromMap(map['request'] as Map),
      response: response == null ? null : ProxieResponse.fromMap(response),
      error: error == null ? null : ProxieError.fromMap(error),
      startedAt: DateTime.parse(map['startedAt'] as String),
      duration: micros == null ? null : Duration(microseconds: micros),
      tags: {
        for (final t in (map['tags'] as List? ?? const []).cast<String>())
          CallTag.values.byName(t),
      },
    );
  }

  /// Identifies the call; unique within its engine.
  final String id;

  /// The session the call was recorded in.
  final int sessionId;

  /// The name of the adapter that captured the call, such as `http` or
  /// `dio`.
  final String adapter;

  /// The request as sent, after any breakpoint edits.
  final ProxieRequest request;

  /// The response as the app received it; null while pending or when the
  /// call failed before one arrived.
  final ProxieResponse? response;

  /// Why the call failed; null when it did not.
  final ProxieError? error;

  /// When the request started.
  final DateTime startedAt;

  /// Time from start to completion; includes time spent paused at breakpoints.
  final Duration? duration;

  /// Unmodifiable.
  final Set<CallTag> tags;

  /// A copy with the given fields replaced; the `clear` flags reset the
  /// nullable ones to null.
  ProxieCall copyWith({
    String? id,
    int? sessionId,
    String? adapter,
    ProxieRequest? request,
    ProxieResponse? response,
    bool clearResponse = false,
    ProxieError? error,
    bool clearError = false,
    DateTime? startedAt,
    Duration? duration,
    bool clearDuration = false,
    Set<CallTag>? tags,
  }) => ProxieCall(
    id: id ?? this.id,
    sessionId: sessionId ?? this.sessionId,
    adapter: adapter ?? this.adapter,
    request: request ?? this.request,
    response: clearResponse ? null : (response ?? this.response),
    error: clearError ? null : (error ?? this.error),
    startedAt: startedAt ?? this.startedAt,
    duration: clearDuration ? null : (duration ?? this.duration),
    tags: tags ?? this.tags,
  );

  /// Encodes this call as plain data for storage and isolate messages.
  Map<String, Object?> toMap() => {
    'id': id,
    'sessionId': sessionId,
    'adapter': adapter,
    'request': request.toMap(),
    'response': response?.toMap(),
    'error': error?.toMap(),
    'startedAt': startedAt.toIso8601String(),
    'durationMicros': duration?.inMicroseconds,
    'tags': [for (final t in tags) t.name],
  };
}
