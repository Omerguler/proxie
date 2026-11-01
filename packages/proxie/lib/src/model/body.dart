import 'dart:convert';
import 'dart:typed_data';

import '../core/body_classifier.dart';

/// Default render/tee cap for captured bodies (5 MB).
const int defaultBodyCap = 5 * 1024 * 1024;

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

  /// Classifies [bytes] and keeps at most [cap] of them.
  factory ProxieBody.from(
    Uint8List bytes,
    String? contentType, {
    int cap = defaultBodyCap,
  }) {
    final kind = classifyBody(bytes, contentType);
    final truncated = bytes.length > cap;
    var end = truncated ? cap : bytes.length;
    if (truncated && (kind == BodyKind.text || kind == BodyKind.json)) {
      // The body was classified as valid UTF-8 in full, so back the cut up to
      // a character boundary (skip continuation bytes 10xxxxxx) to keep `text`
      // decodable.
      while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
    }
    return ProxieBody(
      bytes: Uint8List.sublistView(bytes, 0, end),
      contentType: contentType,
      kind: kind,
      truncated: truncated,
      originalLength: bytes.length,
    );
  }

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
