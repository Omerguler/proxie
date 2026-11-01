import 'body.dart';
import 'request.dart';

/// A captured HTTP response.
class ProxieResponse {
  ProxieResponse({
    required this.statusCode,
    this.reasonPhrase,
    required Map<String, List<String>> headers,
    required this.body,
  }) : headers = normalizeHeaders(headers);

  factory ProxieResponse.fromMap(Map<dynamic, dynamic> map) => ProxieResponse(
    statusCode: map['statusCode'] as int,
    reasonPhrase: map['reasonPhrase'] as String?,
    headers: normalizeHeaders(map['headers'] as Map),
    body: ProxieBody.fromMap(map['body'] as Map),
  );

  final int statusCode;
  final String? reasonPhrase;

  /// Header names are lowercase.
  final Map<String, List<String>> headers;
  final ProxieBody body;

  ProxieResponse copyWith({
    int? statusCode,
    String? reasonPhrase,
    Map<String, List<String>>? headers,
    ProxieBody? body,
  }) => ProxieResponse(
    statusCode: statusCode ?? this.statusCode,
    reasonPhrase: reasonPhrase ?? this.reasonPhrase,
    headers: headers ?? this.headers,
    body: body ?? this.body,
  );

  Map<String, Object?> toMap() => {
    'statusCode': statusCode,
    'reasonPhrase': reasonPhrase,
    'headers': headers,
    'body': body.toMap(),
  };
}
