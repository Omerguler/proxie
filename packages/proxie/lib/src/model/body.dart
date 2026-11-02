import 'dart:convert';
import 'dart:typed_data';

import 'package:proxie/src/core/body_classifier.dart';

/// Default render/tee cap for captured bodies (5 MB).
const int defaultBodyCap = 5 * 1024 * 1024;

/// How a captured body should be presented.
enum BodyKind {
  /// No content.
  empty,

  /// Valid JSON, shown as a tree.
  json,

  /// Readable text, shown as is.
  text,

  /// Anything else, shown as bytes.
  binary,

  /// An image the inspector can preview.
  image,
}

/// A captured HTTP body.
class ProxieBody {
  /// Creates a body; [originalLength] defaults to the length of [bytes].
  const ProxieBody({
    required this.bytes,
    required this.kind,
    this.contentType,
    this.truncated = false,
    int? originalLength,
  }) : originalLength = originalLength ?? bytes.length;

  /// Classifies [bytes] and keeps at most [cap] of them.
  factory ProxieBody.from(
    Uint8List bytes,
    String? contentType, {
    int cap = defaultBodyCap,
  }) {
    final truncated = bytes.length > cap;
    final window = truncated ? Uint8List.sublistView(bytes, 0, cap) : bytes;
    // Declared text/json types are validated in full over the kept bytes
    // (a cut at the cap may land inside a multi-byte character, which is
    // tolerated here and trimmed below); anything else is only sniffed in its
    // first 512 bytes, so the decode check further down covers the rest.
    var kind = classifyBody(window, contentType, mayBeCut: truncated);
    var end = window.length;
    if (truncated &&
        (kind == BodyKind.text || kind == BodyKind.json) &&
        !isLatin1Text(contentType)) {
      // Back the cut up to a character boundary (skip continuation bytes
      // 10xxxxxx) to keep `text` decodable.
      while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
    }
    var body = ProxieBody(
      // An owned copy, so later changes to the caller's buffer do not leak in.
      bytes: Uint8List.fromList(Uint8List.sublistView(bytes, 0, end)),
      contentType: contentType,
      kind: kind,
      truncated: truncated,
      originalLength: bytes.length,
    );
    // Sniffed bodies are only checked in their first 512 bytes; a text/json
    // body that still does not decode is presented as binary. Declared types
    // were already validated in full by classifyBody.
    if (!isDeclaredTextual(contentType) &&
        (kind == BodyKind.text || kind == BodyKind.json) &&
        body.text == null) {
      kind = BodyKind.binary;
      body = ProxieBody(
        bytes: body.bytes,
        contentType: contentType,
        kind: kind,
        truncated: truncated,
        originalLength: bytes.length,
      );
    }
    return body;
  }

  /// A body with no content.
  factory ProxieBody.empty() =>
      ProxieBody(bytes: Uint8List(0), kind: BodyKind.empty);

  /// Decodes a body written by [toMap].
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

  /// The captured content; only its start when [truncated] is set.
  final Uint8List bytes;

  /// The `content-type` header value, if any.
  final String? contentType;

  /// How the inspector presents the body.
  final BodyKind kind;

  /// Whether [bytes] holds only the start of a longer body.
  final bool truncated;

  /// Length on the wire before any capping. Masking and other rewrites keep
  /// this value; it is not recomputed from [bytes].
  final int originalLength;

  /// The body decoded as UTF-8 (Latin-1 for `text/*` declaring that charset),
  /// or null when it is not valid in that encoding.
  String? get text {
    try {
      if (isLatin1Text(contentType)) return latin1.decode(bytes);
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return null;
    }
  }

  /// Encodes this body as plain data for storage and isolate messages; the
  /// bytes are copied.
  Map<String, Object?> toMap() => {
    'bytes': Uint8List.fromList(bytes),
    'contentType': contentType,
    'kind': kind.name,
    'truncated': truncated,
    'originalLength': originalLength,
  };
}
