import 'dart:convert';
import 'dart:typed_data';

import '../model/body.dart';

const _sniffLength = 512;

/// Decides how [bytes] should be presented, using [contentType] first and
/// falling back to sniffing the leading bytes.
BodyKind classifyBody(Uint8List bytes, String? contentType) {
  if (bytes.isEmpty) return BodyKind.empty;
  if (_isImage(bytes)) return BodyKind.image;

  final mime = contentType?.split(';').first.trim().toLowerCase();
  if (mime != null && mime.isNotEmpty) {
    if (mime.startsWith('image/') && mime != 'image/svg+xml') {
      return BodyKind.binary;
    }
    final isJson = mime == 'application/json' || mime.endsWith('+json');
    final isText =
        mime.startsWith('text/') ||
        mime == 'image/svg+xml' ||
        mime == 'application/xml' ||
        mime == 'application/javascript' ||
        mime == 'application/x-www-form-urlencoded' ||
        mime.endsWith('+xml');
    if (isJson || isText) {
      if (!_isUtf8(bytes)) return BodyKind.binary;
      return isJson ? BodyKind.json : BodyKind.text;
    }
  }

  final head = Uint8List.sublistView(
    bytes,
    0,
    bytes.length < _sniffLength ? bytes.length : _sniffLength,
  );
  if (head.contains(0)) return BodyKind.binary;
  if (!_isUtf8(head, mayBeCut: bytes.length > head.length)) {
    return BodyKind.binary;
  }
  for (final b in head) {
    if (b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d) continue;
    return b == 0x7b || b == 0x5b ? BodyKind.json : BodyKind.text;
  }
  return BodyKind.text;
}

bool _isUtf8(Uint8List bytes, {bool mayBeCut = false}) {
  // A cut sniff window can end inside a multi-byte character; allow dropping
  // up to three trailing bytes in that case.
  final maxTrim = mayBeCut ? 3 : 0;
  for (var trim = 0; trim <= maxTrim && trim < bytes.length; trim++) {
    try {
      utf8.decode(
        Uint8List.sublistView(bytes, 0, bytes.length - trim),
        allowMalformed: false,
      );
      return true;
    } on FormatException {
      // try the next trim
    }
  }
  return false;
}

bool _startsWith(Uint8List b, List<int> magic, [int offset = 0]) {
  if (b.length < offset + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (b[offset + i] != magic[i]) return false;
  }
  return true;
}

bool _isImage(Uint8List b) =>
    _startsWith(b, const [0x89, 0x50, 0x4e, 0x47]) || // PNG
    _startsWith(b, const [0xff, 0xd8, 0xff]) || // JPEG
    _startsWith(b, const [0x47, 0x49, 0x46, 0x38]) || // GIF8
    (_startsWith(b, const [0x52, 0x49, 0x46, 0x46]) && // RIFF....WEBP
        _startsWith(b, const [0x57, 0x45, 0x42, 0x50], 8));
