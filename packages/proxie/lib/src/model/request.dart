import 'body.dart';

/// Lowercases header names, copying the value lists.
Map<String, List<String>> normalizeHeaders(Map<dynamic, dynamic> headers) => {
  for (final e in headers.entries)
    (e.key as String).toLowerCase(): List<String>.of(
      (e.value as List).cast<String>(),
    ),
};

/// A captured HTTP request.
class ProxieRequest {
  ProxieRequest({
    required this.method,
    required this.url,
    required Map<String, List<String>> headers,
    required this.body,
  }) : headers = normalizeHeaders(headers);

  factory ProxieRequest.fromMap(Map<dynamic, dynamic> map) => ProxieRequest(
    method: map['method'] as String,
    url: Uri.parse(map['url'] as String),
    headers: normalizeHeaders(map['headers'] as Map),
    body: ProxieBody.fromMap(map['body'] as Map),
  );

  final String method;
  final Uri url;

  /// Header names are lowercase.
  final Map<String, List<String>> headers;
  final ProxieBody body;

  ProxieRequest copyWith({
    String? method,
    Uri? url,
    Map<String, List<String>>? headers,
    ProxieBody? body,
  }) => ProxieRequest(
    method: method ?? this.method,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    body: body ?? this.body,
  );

  Map<String, Object?> toMap() => {
    'method': method,
    'url': url.toString(),
    'headers': headers,
    'body': body.toMap(),
  };
}
