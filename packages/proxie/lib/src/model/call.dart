import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// Markers describing how a call was handled.
enum CallTag { breakpoint, mapLocal, edited, replayed, truncated }

/// A transport-level failure of a call.
class ProxieError {
  const ProxieError({required this.type, required this.message});

  factory ProxieError.fromMap(Map<dynamic, dynamic> map) => ProxieError(
    type: map['type'] as String,
    message: map['message'] as String,
  );

  final String type;
  final String message;

  Map<String, Object?> toMap() => {'type': type, 'message': message};
}

/// One captured request/response exchange.
class ProxieCall {
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

  final String id;
  final int sessionId;
  final String adapter;
  final ProxieRequest request;
  final ProxieResponse? response;
  final ProxieError? error;
  final DateTime startedAt;

  /// Time from start to completion; includes time spent paused at breakpoints.
  final Duration? duration;

  /// Unmodifiable.
  final Set<CallTag> tags;

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
