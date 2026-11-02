import 'body.dart';

/// Lowercases header names and returns an unmodifiable deep copy.
Map<String, List<String>> normalizeHeaders(Map<dynamic, dynamic> headers) =>
    Map.unmodifiable({
      for (final e in headers.entries)
        (e.key as String).toLowerCase(): List<String>.unmodifiable(
          (e.value as List).cast<String>(),
        ),
    });

/// A mutable deep copy of [headers] for handing out in maps.
Map<String, List<String>> copyHeaders(Map<String, List<String>> headers) => {
  for (final e in headers.entries) e.key: List<String>.of(e.value),
};

/// A captured HTTP request.
class ProxieRequest {
  ProxieRequest({
    required this.method,
    required this.url,
    required Map<String, List<String>> headers,
    required this.body,
  }) : headers = normalizeHeaders(headers);

  factory ProxieRequest.fromMap(Map<dynamic, dynamic> map) => ProxieRequest._(
    map['method'] as String,
    Uri.parse(map['url'] as String),
    normalizeHeaders(map['headers'] as Map),
    ProxieBody.fromMap(map['body'] as Map),
  );

  // Takes headers that are already normalized and unmodifiable.
  ProxieRequest._(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;

  /// Header names are lowercase; the map and its lists are unmodifiable.
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
    'headers': copyHeaders(headers),
    'body': body.toMap(),
  };
}
