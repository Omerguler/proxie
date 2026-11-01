import 'dart:convert';
import 'dart:typed_data';

import '../model/body.dart';

const _sniffLength = 512;

/// Whether [contentType] is `text/*` declaring a Latin-1 charset.
bool isLatin1Text(String? contentType) {
  if (contentType == null) return false;
  final parts = contentType.split(';');
  if (!parts.first.trim().toLowerCase().startsWith('text/')) return false;
  for (final p in parts.skip(1)) {
    final i = p.indexOf('=');
    if (i < 0 || p.substring(0, i).trim().toLowerCase() != 'charset') continue;
    final v = p.substring(i + 1).trim().toLowerCase().replaceAll('"', '');
    return v == 'iso-8859-1' ||
        v == 'latin1' ||
        v == 'iso_8859-1' ||
        v == 'iso8859-1';
  }
  return false;
}

/// Decides how [bytes] should be presented, using [contentType] first and
/// falling back to sniffing the leading bytes.
///
/// Set [mayBeCut] when [bytes] is a prefix of a longer body, so an incomplete
/// UTF-8 sequence at the very end is tolerated.
BodyKind classifyBody(
  Uint8List bytes,
  String? contentType, {
  bool mayBeCut = false,
}) {
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
      if (isLatin1Text(contentType)) return BodyKind.text;
      if (!_isUtf8(bytes, mayBeCut: mayBeCut)) return BodyKind.binary;
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
  final end = bytes.length - (mayBeCut ? _incompleteTail(bytes) : 0);
  try {
    utf8.decode(Uint8List.sublistView(bytes, 0, end), allowMalformed: false);
    return true;
  } on FormatException {
    return false;
  }
}

/// Length (1-3) of a trailing byte run that is a valid but incomplete UTF-8
/// sequence, or 0 when the end of [b] is not such a prefix.
int _incompleteTail(Uint8List b) {
  final n = b.length;
  for (var back = 1; back <= 3 && back <= n; back++) {
    final c = b[n - back];
    if ((c & 0xC0) == 0x80) continue; // continuation: keep looking for lead
    final need = c >= 0xF0 && c <= 0xF4
        ? 4
        : c >= 0xE0
        ? (c <= 0xEF ? 3 : 0)
        : c >= 0xC2 && c <= 0xDF
        ? 2
        : 0;
    if (need <= back) return 0; // complete sequence, ASCII or invalid lead
    if (back > 1) {
      final s = b[n - back + 1];
      final lo = c == 0xE0 ? 0xA0 : (c == 0xF0 ? 0x90 : 0x80);
      final hi = c == 0xED ? 0x9F : (c == 0xF4 ? 0x8F : 0xBF);
      if (s < lo || s > hi) return 0;
    }
    return back;
  }
  return 0;
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
    _startsWith(b, const [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) || // GIF87a
    _startsWith(b, const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) || // GIF89a
    (_startsWith(b, const [0x52, 0x49, 0x46, 0x46]) && // RIFF....WEBP
        _startsWith(b, const [0x57, 0x45, 0x42, 0x50], 8));
