import 'dart:convert';
import 'dart:typed_data';

/// Marks a packed byte buffer: `{"\u0000proxie_bytes": "<base64>"}`.
const _marker = '\u0000proxie_bytes';

/// Prefix escaping real map keys that start with NUL, so no stored key can
/// be mistaken for [_marker].
const _nul = '\u0000';

/// Encodes [value] as JSON, storing [Uint8List]s as base64 instead of number
/// arrays (about a quarter of the size).
String encodeJsonBytes(Object? value) => jsonEncode(_pack(value));

/// Decodes JSON written by [encodeJsonBytes], restoring the byte buffers.
///
/// Throws a [FormatException] on malformed JSON or base64.
Object? decodeJsonBytes(String json) => _unpack(jsonDecode(json));

Object? _escapeKey(Object? k) =>
    k is String && k.startsWith(_nul) ? '$_nul$k' : k;

Object? _unescapeKey(Object? k) =>
    k is String && k.startsWith(_nul) ? k.substring(1) : k;

Object? _pack(Object? v) => switch (v) {
  Uint8List() => {_marker: base64Encode(v)},
  Map() => {for (final e in v.entries) _escapeKey(e.key): _pack(e.value)},
  List() => [for (final x in v) _pack(x)],
  _ => v,
};

Object? _unpack(Object? v) => switch (v) {
  Map() when v.length == 1 && v[_marker] is String => base64Decode(
    v[_marker] as String,
  ),
  Map() => {for (final e in v.entries) _unescapeKey(e.key): _unpack(e.value)},
  List() => [for (final x in v) _unpack(x)],
  _ => v,
};
