import 'dart:convert';
import 'dart:typed_data';

import 'json_nodes.dart';
import 'json_row.dart';

/// Parses RFC 8259 JSON from UTF-8 [bytes] straight into [JsonNodes],
/// without recursion. Scalars are not converted: nodes point at their
/// source text, so numbers keep their exact spelling. Duplicate member
/// names are kept as separate members. A leading UTF-8 BOM is skipped.
///
/// Throws a [FormatException] whose offset is a byte offset into [bytes].
JsonNodes parseJson(Uint8List bytes) => _Parser(bytes).parse();

// Byte values.
const _tab = 0x09, _lf = 0x0A, _cr = 0x0D, _space = 0x20;
const _quote = 0x22, _comma = 0x2C, _minus = 0x2D, _plus = 0x2B;
const _dot = 0x2E, _zero = 0x30, _nine = 0x39, _colon = 0x3A;
const _openBracket = 0x5B, _backslash = 0x5C, _closeBracket = 0x5D;
const _openBrace = 0x7B, _closeBrace = 0x7D;
const _lowerE = 0x65, _upperE = 0x45;

const _objectFlags = 0; // JsonKind.object.index
final _arrayFlags = JsonKind.array.index;
final _stringFlags = JsonKind.string.index;
final _numberFlags = JsonKind.number.index;
final _booleanFlags = JsonKind.boolean.index;
final _nullFlags = JsonKind.nullValue.index;

class _Parser {
  _Parser(this.b) : nodes = JsonNodes(b.length ~/ 6 + 16);

  final Uint8List b;
  final JsonNodes nodes;
  final Map<String, int> _keyIds = {};

  int pos = 0;

  /// Open containers and the last child linked into each.
  final List<int> _open = [];
  final List<int> _last = [];

  /// The innermost open container still needs its first element.
  bool _needFirst = false;

  // Results of the last [_string] scan.
  bool _escaped = false;
  bool _nonAscii = false;

  Never _fail(String message, [int? offset]) =>
      throw FormatException(message, null, offset ?? pos);

  JsonNodes parse() {
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      pos = 3;
    }
    _ws();
    _value(-1, -1);
    while (_open.isNotEmpty) {
      _ws();
      final top = _open.last;
      final isObject = (nodes.flags[top] & kindMask) == _objectFlags;
      if (_needFirst) {
        _needFirst = false;
        _element(top, isObject);
        continue;
      }
      if (pos >= b.length) _fail('Unexpected end of input');
      final c = b[pos];
      if (c == _comma) {
        pos++;
        _ws();
        _element(top, isObject);
      } else if (c == (isObject ? _closeBrace : _closeBracket)) {
        pos++;
        _open.removeLast();
        _last.removeLast();
      } else {
        _fail('Unexpected character');
      }
    }
    _ws();
    if (pos != b.length) _fail('Unexpected character');
    nodes.trim();
    return nodes;
  }

  void _ws() {
    while (pos < b.length) {
      final c = b[pos];
      if (c != _space && c != _lf && c != _cr && c != _tab) return;
      pos++;
    }
  }

  void _element(int container, bool isObject) {
    if (isObject) {
      final key = _key();
      _value(container, key);
    } else {
      _value(container, nodes.childCount[container]);
    }
  }

  /// A member name and its colon; returns the interned key id.
  int _key() {
    if (pos >= b.length) _fail('Unexpected end of input');
    if (b[pos] != _quote) _fail('Unexpected character');
    final start = pos;
    _string();
    final String key;
    if (_escaped) {
      key = decodeJsonString(b, start);
    } else if (_nonAscii) {
      key = utf8.decode(Uint8List.sublistView(b, start + 1, pos - 1));
    } else {
      key = String.fromCharCodes(b, start + 1, pos - 1);
    }
    var id = _keyIds[key];
    if (id == null) {
      id = nodes.keys.length;
      nodes.keys.add(key);
      _keyIds[key] = id;
    }
    _ws();
    if (pos >= b.length) _fail('Unexpected end of input');
    if (b[pos] != _colon) _fail('Unexpected character');
    pos++;
    _ws();
    return id;
  }

  /// One value at [pos]; containers are opened and left for the main loop.
  void _value(int parent, int keyOrIndex) {
    if (pos >= b.length) _fail('Unexpected end of input');
    final start = pos;
    final c = b[pos];
    switch (c) {
      case _openBrace || _openBracket:
        final id = _node(
          parent,
          c == _openBrace ? _objectFlags : _arrayFlags,
          keyOrIndex,
          start,
        );
        pos++;
        _ws();
        if (pos < b.length &&
            b[pos] == (c == _openBrace ? _closeBrace : _closeBracket)) {
          pos++;
          return;
        }
        _open.add(id);
        _last.add(-1);
        _needFirst = true;
      case _quote:
        _string();
        _node(
          parent,
          _stringFlags | (_escaped ? escapedFlag : 0),
          keyOrIndex,
          start,
        );
      case 0x74: // t
        _literal(const [0x74, 0x72, 0x75, 0x65]);
        _node(parent, _booleanFlags, keyOrIndex, start);
      case 0x66: // f
        _literal(const [0x66, 0x61, 0x6C, 0x73, 0x65]);
        _node(parent, _booleanFlags, keyOrIndex, start);
      case 0x6E: // n
        _literal(const [0x6E, 0x75, 0x6C, 0x6C]);
        _node(parent, _nullFlags, keyOrIndex, start);
      default:
        if (c == _minus || (c >= _zero && c <= _nine)) {
          _number();
          _node(parent, _numberFlags, keyOrIndex, start);
        } else {
          _fail('Unexpected character');
        }
    }
  }

  int _node(int parent, int flags, int keyOrIndex, int start) {
    final id = nodes.add(parent, flags, keyOrIndex, start);
    if (parent != -1) {
      final top = _last.length - 1;
      final prev = _last[top];
      if (prev == -1) {
        nodes.firstChild[parent] = id;
      } else {
        nodes.nextSibling[prev] = id;
      }
      _last[top] = id;
      nodes.childCount[parent]++;
      // Children start collapsed: one row each.
      nodes.inner[parent]++;
    }
    return id;
  }

  void _literal(List<int> word) {
    for (var i = 0; i < word.length; i++) {
      if (pos >= b.length) _fail('Unexpected end of input');
      if (b[pos] != word[i]) _fail('Unexpected character');
      pos++;
    }
  }

  void _number() {
    if (b[pos] == _minus) pos++;
    if (pos >= b.length) _fail('Unexpected end of input');
    if (b[pos] == _zero) {
      pos++;
    } else if (_isDigit(b[pos])) {
      _digits();
    } else {
      _fail('Invalid number');
    }
    if (pos < b.length && b[pos] == _dot) {
      pos++;
      _requireDigits();
    }
    if (pos < b.length && (b[pos] == _lowerE || b[pos] == _upperE)) {
      pos++;
      if (pos < b.length && (b[pos] == _plus || b[pos] == _minus)) pos++;
      _requireDigits();
    }
  }

  void _requireDigits() {
    if (pos >= b.length) _fail('Unexpected end of input');
    if (!_isDigit(b[pos])) _fail('Invalid number');
    _digits();
  }

  void _digits() {
    while (pos < b.length && _isDigit(b[pos])) {
      pos++;
    }
  }

  /// Scans the string starting at the quote at [pos]; leaves [pos] after the
  /// closing quote and sets [_escaped] / [_nonAscii].
  void _string() {
    final start = pos;
    _escaped = false;
    _nonAscii = false;
    pos++;
    while (true) {
      if (pos >= b.length) _fail('Unterminated string', start);
      final c = b[pos];
      if (c == _quote) {
        pos++;
        return;
      }
      if (c == _backslash) {
        _escaped = true;
        pos++;
        if (pos >= b.length) _fail('Unterminated string', start);
        switch (b[pos]) {
          case _quote || _backslash || 0x2F || 0x62 || 0x66 || 0x6E || 0x72:
          case 0x74:
            pos++;
          case 0x75: // u
            pos++;
            for (var i = 0; i < 4; i++) {
              if (pos >= b.length) _fail('Unterminated string', start);
              if (_hex(b[pos]) < 0) _fail('Invalid \\u escape');
              pos++;
            }
          default:
            _fail('Invalid escape');
        }
      } else if (c < 0x20) {
        _fail('Control character in string');
      } else if (c < 0x80) {
        pos++;
      } else {
        _nonAscii = true;
        _utf8();
      }
    }
  }

  /// Validates one multi-byte UTF-8 sequence at [pos] (RFC 3629: no
  /// overlongs, surrogates or code points above U+10FFFF).
  void _utf8() {
    final c = b[pos];
    int n;
    var lo = 0x80, hi = 0xBF;
    if (c >= 0xC2 && c <= 0xDF) {
      n = 1;
    } else if (c >= 0xE0 && c <= 0xEF) {
      n = 2;
      if (c == 0xE0) lo = 0xA0;
      if (c == 0xED) hi = 0x9F;
    } else if (c >= 0xF0 && c <= 0xF4) {
      n = 3;
      if (c == 0xF0) lo = 0x90;
      if (c == 0xF4) hi = 0x8F;
    } else {
      _fail('Invalid UTF-8');
    }
    final at = pos;
    if (at + n >= b.length) _fail('Invalid UTF-8', at);
    final second = b[at + 1];
    if (second < lo || second > hi) _fail('Invalid UTF-8', at);
    for (var i = 2; i <= n; i++) {
      if ((b[at + i] & 0xC0) != 0x80) _fail('Invalid UTF-8', at);
    }
    pos = at + n + 1;
  }
}

bool _isDigit(int c) => c >= _zero && c <= _nine;

int _hex(int c) {
  if (c >= _zero && c <= _nine) return c - _zero;
  final l = c | 0x20;
  if (l >= 0x61 && l <= 0x66) return l - 0x61 + 10;
  return -1;
}

/// Offset just past the closing quote of the valid string at [quote].
int jsonStringEnd(Uint8List b, int quote) {
  var p = quote + 1;
  while (true) {
    final c = b[p];
    if (c == _quote) return p + 1;
    p += c == _backslash ? 2 : 1;
  }
}

/// Offset just past the valid number starting at [start].
int jsonNumberEnd(Uint8List b, int start) {
  var p = start;
  while (p < b.length) {
    final c = b[p];
    if (!_isDigit(c) &&
        c != _minus &&
        c != _plus &&
        c != _dot &&
        c != _lowerE &&
        c != _upperE) {
      break;
    }
    p++;
  }
  return p;
}

/// Decodes the valid JSON string at [quote], stopping once at least
/// [maxUnits] UTF-16 code units have been produced.
String decodeJsonString(
  Uint8List b,
  int quote, {
  int maxUnits = 1 << 50,
  bool escaped = true,
}) {
  final start = quote + 1;
  if (!escaped) {
    // No escapes: the first quote ends it. A code unit takes at most three
    // bytes, so this window yields at least maxUnits units when cut.
    final limit = maxUnits >= b.length ? b.length : start + maxUnits * 3;
    var p = start;
    while (p < b.length && p < limit && b[p] != _quote) {
      p++;
    }
    if (p < b.length && b[p] != _quote) {
      // Cut: back up to a character boundary.
      while (p > start && (b[p] & 0xC0) == 0x80) {
        p--;
      }
    }
    return utf8.decode(Uint8List.sublistView(b, start, p));
  }
  final out = StringBuffer();
  var units = 0;
  var p = start;
  while (units < maxUnits) {
    final c = b[p];
    if (c == _quote) break;
    if (c == _backslash) {
      final e = b[p + 1];
      p += 2;
      final int code;
      switch (e) {
        case 0x62:
          code = 0x08;
        case 0x66:
          code = 0x0C;
        case 0x6E:
          code = 0x0A;
        case 0x72:
          code = 0x0D;
        case 0x74:
          code = 0x09;
        case 0x75:
          code =
              _hex(b[p]) << 12 |
              _hex(b[p + 1]) << 8 |
              _hex(b[p + 2]) << 4 |
              _hex(b[p + 3]);
          p += 4;
        default:
          code = e; // " \ /
      }
      out.writeCharCode(code);
      units++;
    } else if (c < 0x80) {
      out.writeCharCode(c);
      p++;
      units++;
    } else {
      int cp;
      int n;
      if (c < 0xE0) {
        cp = c & 0x1F;
        n = 1;
      } else if (c < 0xF0) {
        cp = c & 0x0F;
        n = 2;
      } else {
        cp = c & 0x07;
        n = 3;
      }
      for (var i = 1; i <= n; i++) {
        cp = cp << 6 | (b[p + i] & 0x3F);
      }
      p += n + 1;
      out.writeCharCode(cp);
      units += cp > 0xFFFF ? 2 : 1;
    }
  }
  return out.toString();
}
