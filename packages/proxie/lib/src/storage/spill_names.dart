import 'dart:convert';

/// Every name [spillFileName] can produce; anything else in the spill
/// directory is left alone by the orphan sweep.
final spillFileNamePattern = RegExp(r'^[a-z0-9_-]+\.(req|res)\.[a-z0-9]+$');

final _reservedName = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$');

String _esc(int byte) => '_${byte.toRadixString(16).padLeft(2, '0')}';

/// A file name for one spilled body of the call [callId], safe on every
/// platform: `<escaped id>.<which>.<unique>`.
///
/// Names are all lowercase, so they stay distinct on case-insensitive file
/// systems: bytes other than `a-z`, `0-9` and `-` (uppercase letters
/// included) become `_xx` in hex, which keeps the mapping one-to-one. Ids
/// whose escaped form is over 120 characters use `_r<seq>` instead, which
/// no escaped id can produce ('r' is not a hex digit). [unique] must be
/// lowercase alphanumeric and differ per write, so a new body never
/// overwrites a file an existing row still points to.
String spillFileName(String callId, int seq, String which, String unique) {
  final bytes = utf8.encode(callId);
  final b = StringBuffer();
  for (final byte in bytes) {
    final safe =
        (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        byte == 0x2D;
    b.write(safe ? String.fromCharCode(byte) : _esc(byte));
  }
  var name = b.toString();
  if (name.isEmpty) {
    name = '_';
  } else if (_reservedName.hasMatch(name)) {
    // Windows device names (CON, NUL, ...) are reserved even with an
    // extension; escaping the first letter keeps the name decodable.
    name = '${_esc(bytes.first)}${name.substring(1)}';
  }
  if (name.length > 120) name = '_r$seq';
  return '$name.$which.$unique';
}
