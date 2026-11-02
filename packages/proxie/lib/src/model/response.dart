import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/request.dart';

/// A captured HTTP response.
class ProxieResponse {
  ProxieResponse({
    required this.statusCode,
    required Map<String, List<String>> headers,
    required this.body,
    this.reasonPhrase,
  }) : headers = normalizeHeaders(headers);

  factory ProxieResponse.fromMap(Map<dynamic, dynamic> map) => ProxieResponse._(
    map['statusCode'] as int,
    map['reasonPhrase'] as String?,
    normalizeHeaders(map['headers'] as Map),
    ProxieBody.fromMap(map['body'] as Map),
  );

  // Takes headers that are already normalized and unmodifiable.
  ProxieResponse._(this.statusCode, this.reasonPhrase, this.headers, this.body);

  final int statusCode;
  final String? reasonPhrase;

  /// Header names are lowercase; the map and its lists are unmodifiable.
  final Map<String, List<String>> headers;
  final ProxieBody body;

  ProxieResponse copyWith({
    int? statusCode,
    String? reasonPhrase,
    bool clearReasonPhrase = false,
    Map<String, List<String>>? headers,
    ProxieBody? body,
  }) => ProxieResponse(
    statusCode: statusCode ?? this.statusCode,
    reasonPhrase: clearReasonPhrase
        ? null
        : (reasonPhrase ?? this.reasonPhrase),
    headers: headers ?? this.headers,
    body: body ?? this.body,
  );

  Map<String, Object?> toMap() => {
    'statusCode': statusCode,
    'reasonPhrase': reasonPhrase,
    'headers': copyHeaders(headers),
    'body': body.toMap(),
  };
}
