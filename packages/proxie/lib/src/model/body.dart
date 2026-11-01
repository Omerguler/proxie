import 'dart:convert';
import 'dart:typed_data';

/// How a captured body should be presented.
enum BodyKind { empty, json, text, binary, image }

/// A captured HTTP body.
class ProxieBody {
  const ProxieBody({
    required this.bytes,
    this.contentType,
    required this.kind,
    this.truncated = false,
    int? originalLength,
  }) : originalLength = originalLength ?? bytes.length;

  /// A body with no content.
  factory ProxieBody.empty() =>
      ProxieBody(bytes: Uint8List(0), kind: BodyKind.empty);

  factory ProxieBody.fromMap(Map<dynamic, dynamic> map) {
    final raw = map['bytes'];
    return ProxieBody(
      bytes: raw is Uint8List
          ? raw
          : Uint8List.fromList((raw as List).cast<int>()),
      contentType: map['contentType'] as String?,
      kind: BodyKind.values.byName(map['kind'] as String),
      truncated: map['truncated'] as bool? ?? false,
      originalLength: map['originalLength'] as int?,
    );
  }

  final Uint8List bytes;
  final String? contentType;
  final BodyKind kind;
  final bool truncated;
  final int originalLength;

  /// The body decoded as UTF-8, or null when it is not valid UTF-8.
  String? get text {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toMap() => {
    'bytes': bytes,
    'contentType': contentType,
    'kind': kind.name,
    'truncated': truncated,
    'originalLength': originalLength,
  };
}
