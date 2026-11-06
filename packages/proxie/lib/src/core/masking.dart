import 'dart:convert';
import 'dart:typed_data';

import 'package:proxie/src/core/body_classifier.dart' show isLatin1Text;
import 'package:proxie/src/json/json_parser.dart';
import 'package:proxie/src/json/json_row.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// Replacement for masked values.
const kMask = '••••••';

/// Replacement for masked query values, as it is written inside a URL.
const kMaskInUrl = '%E2%80%A2%E2%80%A2%E2%80%A2%E2%80%A2%E2%80%A2%E2%80%A2';

/// The content type of a URL-encoded form.
const kFormType = 'application/x-www-form-urlencoded';

/// Whether [contentType] names a URL-encoded form.
bool isFormType(String? contentType) =>
    contentType?.split(';').first.trim().toLowerCase() == kFormType;

/// [url] as people read it: masked query values show as [kMask].
String showMaskedUrl(String url) => url.replaceAll(kMaskInUrl, kMask);

/// Whether the URL text [url] holds a value masked at capture.
bool isMaskedUrl(String url) => url.contains(kMaskInUrl) || url.contains(kMask);

/// The fields of the URL-encoded form [text] whose value was masked at
/// capture, decoded, in order.
List<String> maskedFormFields(String text) => [
  for (final part in text.split(RegExp('[&;]')))
    if (part.endsWith('=$kMask') || part.endsWith('=$kMaskInUrl'))
      _decodeLeniently(part.substring(0, part.indexOf('='))),
];

final _badEscape = RegExp('%(?![0-9a-fA-F]{2})');
final _nonAscii = RegExp(r'[^\x00-\x7F]');

/// [s] with its query encoding undone, or as it is when that encoding is
/// malformed. Never throws.
String _decodeLeniently(String s) {
  if (_badEscape.hasMatch(s) || _nonAscii.hasMatch(s)) return s;
  return Uri.decodeQueryComponent(
    s,
    encoding: const Utf8Codec(allowMalformed: true),
  );
}

/// Masks sensitive values on stored/displayed copies: the [headers] and,
/// matched on the [jsonKeys] names, JSON values at any depth, query parameters
/// (in the URL and in URLs held by errors and by `Location`,
/// `Content-Location` and `Referer` headers) and URL-encoded form fields.
///
/// A body keeps every byte except the masked values: one with nothing to mask
/// comes back as the same object. `ProxieMasking(headers: {}, jsonKeys: {})`
/// turns masking off.
///
/// The [headers] and [jsonKeys] sets must not be mutated after construction:
/// their lowercased forms are computed once and cached.
class ProxieMasking {
  /// Creates a masking setup; the defaults cover common credentials.
  const ProxieMasking({
    this.headers = _defaultHeaders,
    this.jsonKeys = _defaultJsonKeys,
  });

  static const _defaultHeaders = {
    'Authorization',
    'Cookie',
    'Set-Cookie',
    'Proxy-Authorization',
  };
  static const _defaultJsonKeys = {
    'password',
    'token',
    'access_token',
    'refresh_token',
    'secret',
  };

  /// The default header and JSON key lists.
  static const defaults = ProxieMasking();

  /// Header names to mask (case-insensitive).
  final Set<String> headers;

  /// Names to mask (case-insensitive): JSON object keys at any depth, query
  /// parameters and form fields.
  final Set<String> jsonKeys;

  // Lowercased name sets and the fallback key matcher, computed once per
  // instance. Kept outside the instance so the class stays const-constructible.
  static final Expando<_Compiled> _cache = Expando<_Compiled>();

  _Compiled get _compiled => _cache[this] ??= _Compiled(headers, jsonKeys);

  /// A copy of [r] with sensitive headers, query parameters, form fields and
  /// JSON values masked.
  ProxieRequest maskRequest(ProxieRequest r) => r.copyWith(
    url: maskUrl(r.url),
    headers: _maskHeaders(r.headers),
    body: _maskBody(r.body),
  );

  /// A copy of [r] with sensitive headers, form fields and JSON values masked.
  ProxieResponse maskResponse(ProxieResponse r) =>
      r.copyWith(headers: _maskHeaders(r.headers), body: _maskBody(r.body));

  /// [url] with the values of sensitive query parameters replaced by
  /// [kMaskInUrl]; the same object when there are none.
  Uri maskUrl(Uri url) {
    if (!url.hasQuery) return url;
    final query = url.query;
    final masked = _maskPairs(query, kMaskInUrl);
    return identical(masked, query) ? url : url.replace(query: masked);
  }

  /// A copy of [e] with the sensitive query values of any URL in its message
  /// masked.
  ProxieError maskError(ProxieError e) =>
      ProxieError(type: e.type, message: _maskUrlsIn(e.message));

  Map<String, List<String>> _maskHeaders(Map<String, List<String>> input) {
    final names = _compiled.headerNames;
    return {
      for (final e in input.entries)
        e.key: names.contains(e.key.toLowerCase())
            ? [for (final _ in e.value) kMask]
            : _urlHeaders.contains(e.key.toLowerCase())
            ? [for (final v in e.value) _maskUrlHeader(v)]
            : List<String>.of(e.value),
    };
  }

  /// Headers whose value is a URL.
  static const _urlHeaders = {'location', 'content-location', 'referer'};

  /// The header value [url] with the values of its sensitive query parameters
  /// replaced by [kMask]. It holds a URL and nothing else, so its query is
  /// treated as [maskUrl] treats one.
  String _maskUrlHeader(String url) {
    final mark = url.indexOf('?');
    if (mark < 0) return url;
    final hash = url.indexOf('#');
    if (hash >= 0 && hash < mark) return url;
    final end = hash < 0 ? url.length : hash;
    final query = url.substring(mark + 1, end);
    final masked = _maskPairs(query, kMask);
    if (identical(masked, query)) return url;
    return '${url.substring(0, mark + 1)}$masked${url.substring(end)}';
  }

  static final _urlName = RegExp(r'[?&;]([^=&;?#\s]+)=');
  static final _urlValueEnd = RegExp(r'[&#\s]');

  /// [text], prose that may hold URLs, with the values of sensitive query
  /// parameters replaced by [kMask]. Such a value ends only at `&`, `#` or
  /// whitespace: anything else may be part of it, and hiding a little of the
  /// prose is harmless.
  String _maskUrlsIn(String text) {
    if (_compiled.keys.isEmpty) return text;
    StringBuffer? out;
    var copied = 0;
    for (final m in _urlName.allMatches(text)) {
      if (m.start < copied) continue; // Inside a value already masked.
      if (!_isSensitiveName(m[1]!)) continue;
      final stop = text.indexOf(_urlValueEnd, m.end);
      final end = stop < 0 ? text.length : stop;
      if (end == m.end) continue;
      (out ??= StringBuffer())
        ..write(text.substring(copied, m.end))
        ..write(kMask);
      copied = end;
    }
    if (out == null) return text;
    out.write(text.substring(copied));
    return out.toString();
  }

  static final _pair = RegExp('[^&;]+');

  /// The `name=value` pairs of [pairs] with the values of sensitive names
  /// replaced by [mask]; [pairs] itself when there are none. A name without a
  /// value is left alone. `;` and `&` both start a name, but a masked value
  /// runs to the next `&`: a value may hold a raw `;`, and hiding a pair too
  /// many is harmless.
  String _maskPairs(String pairs, String mask) {
    if (_compiled.keys.isEmpty) return pairs;
    StringBuffer? out;
    var copied = 0;
    for (final m in _pair.allMatches(pairs)) {
      if (m.start < copied) continue; // Inside a value already masked.
      final pair = m[0]!;
      final eqInPair = pair.indexOf('=');
      if (eqInPair < 0) continue;
      if (!_isSensitiveName(pair.substring(0, eqInPair))) continue;
      final eq = m.start + eqInPair;
      final next = pairs.indexOf('&', eq);
      final end = next < 0 ? pairs.length : next;
      if (end == eq + 1) continue;
      (out ??= StringBuffer())
        ..write(pairs.substring(copied, eq + 1))
        ..write(mask);
      copied = end;
    }
    if (out == null) return pairs;
    out.write(pairs.substring(copied));
    return out.toString();
  }

  static final _nameParts = RegExp(r'[\[\]]');

  /// Whether the encoded parameter name [raw] is sensitive, itself or as a
  /// part of a bracketed name such as `user[password]`.
  bool _isSensitiveName(String raw) {
    final keys = _compiled.keys;
    return _decodeLeniently(
      raw,
    ).toLowerCase().split(_nameParts).any(keys.contains);
  }

  ProxieBody _maskForm(ProxieBody body) {
    // One character per byte both ways, so other bytes stay as they are.
    final view = latin1.decode(body.bytes);
    final masked = _maskPairs(view, _maskView);
    if (identical(masked, view)) return body;
    return ProxieBody(
      bytes: Uint8List.fromList(latin1.encode(masked)),
      contentType: body.contentType,
      kind: body.kind,
      truncated: body.truncated,
      originalLength: body.originalLength,
    );
  }

  static final String _maskView = latin1.decode(utf8.encode(kMask));

  ProxieBody _maskBody(ProxieBody body) {
    final bytes = body.bytes;
    if (bytes.isEmpty || _compiled.keys.isEmpty) return body;
    if (isFormType(body.contentType)) {
      if (!_startsAsJson(bytes)) return _maskForm(body);
      if (!body.truncated && bytes.length <= defaultBodyCap) {
        try {
          return _maskSpans(body, _jsonSpans(bytes));
        } on FormatException {
          // Not JSON after all; the scans below decide.
        }
      }
      // It could be either, so it gets both.
      return _maskForm(_maskSpans(body, _textSpans(latin1.decode(bytes))));
    }
    final declared =
        body.kind == BodyKind.json ||
        (body.contentType?.toLowerCase().contains('json') ?? false);
    if (!declared && !_startsAsJson(bytes)) return body;
    final whole = !body.truncated && bytes.length <= defaultBodyCap;
    List<_Span>? spans;
    if (whole) {
      try {
        spans = _jsonSpans(bytes);
      } on FormatException {
        // Plain text that only starts like JSON stays as it is. A JSON type,
        // or bytes the parser does not read as UTF-8, go on to the text-level
        // scan (fail closed).
        if (!declared &&
            body.kind == BodyKind.text &&
            !isLatin1Text(body.contentType)) {
          return body;
        }
      }
    }
    return _maskSpans(body, spans ?? _textSpans(latin1.decode(bytes)));
  }

  /// [body] with each of [spans] replaced by the mask; [body] itself when there
  /// are none. The wire length is kept in originalLength, not recomputed.
  static ProxieBody _maskSpans(ProxieBody body, List<_Span> spans) {
    if (spans.isEmpty) return body;
    return ProxieBody(
      bytes: _splice(
        body.bytes,
        spans,
        // The mask text is not representable in Latin-1, so those bodies get
        // asterisks instead.
        isLatin1Text(body.contentType) ? _maskedLatin1 : _maskedUtf8,
      ),
      contentType: body.contentType,
      kind: body.kind,
      truncated: body.truncated,
      originalLength: body.originalLength,
    );
  }

  /// Whether the first character of [bytes] that is not whitespace or a BOM
  /// opens an object or an array.
  static bool _startsAsJson(Uint8List bytes) {
    var i = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB ? 3 : 0;
    while (i < bytes.length) {
      final c = bytes[i++];
      if (_isSpace(c)) continue;
      return c == 0x7b || c == 0x5b;
    }
    return false;
  }

  /// The source ranges of the values of sensitive keys in the JSON [bytes].
  /// Throws a [FormatException] when they are not valid JSON. Iterative, so
  /// nesting depth does not matter.
  List<_Span> _jsonSpans(Uint8List bytes) {
    final nodes = parseJson(bytes);
    final keys = _compiled.keys;
    final sensitive = [
      for (final k in nodes.keys) keys.contains(k.toLowerCase()),
    ];
    if (!sensitive.contains(true)) return const [];
    // One character per byte, so offsets carry over.
    final view = latin1.decode(bytes);
    final spans = <_Span>[];
    var end = 0;
    // Ids follow source order, a container before what it holds.
    for (var id = 1; id < nodes.length; id++) {
      if (nodes.kind(nodes.parent[id]) != JsonKind.object ||
          !sensitive[nodes.keyOrIndex[id]]) {
        continue;
      }
      final start = nodes.valueStart[id];
      if (start < end) continue; // Inside a value already masked.
      end = _valueEnd(view, start)!;
      spans.add((start, end));
    }
    return spans;
  }

  /// The ranges of the values of sensitive keys, found without parsing, for
  /// bodies that are truncated, oversized, or not valid JSON. [view] holds one
  /// character per byte of the body, so any encoding will do.
  List<_Span> _textSpans(String view) {
    final keyRe = _compiled.keyPattern;
    if (keyRe == null) return const [];
    final spans = <_Span>[];
    var end = 0;
    for (final m in keyRe.allMatches(view)) {
      if (m.start < end) continue; // Inside a value already masked.
      final valueEnd = _valueEnd(view, m.end);
      if (valueEnd == null) continue;
      spans.add((m.end, valueEnd));
      end = valueEnd;
    }
    return spans;
  }

  /// [bytes] with each of [spans] (in order, not overlapping) replaced.
  static Uint8List _splice(
    Uint8List bytes,
    List<_Span> spans,
    List<int> replacement,
  ) {
    var length = bytes.length;
    for (final (start, end) in spans) {
      length += replacement.length - (end - start);
    }
    final out = Uint8List(length);
    var from = 0;
    var to = 0;
    for (final (start, end) in spans) {
      out.setRange(to, to + start - from, bytes, from);
      to += start - from;
      out.setRange(to, to + replacement.length, replacement);
      to += replacement.length;
      from = end;
    }
    out.setRange(to, length, bytes, from);
    return out;
  }

  static final List<int> _maskedUtf8 = utf8.encode('"$kMask"');
  static final List<int> _maskedLatin1 = latin1.encode('"******"');

  /// End offset of the value starting at [start], or null if there is none.
  /// Containers and strings run to the end of [text] when they are not closed
  /// (truncated body). Anything else, and anything after a closed string, runs
  /// to the next `,`, `}` or `]`: a value that is not JSON is still a value
  /// (fail closed).
  static int? _valueEnd(String text, int start) {
    if (start >= text.length) return null;
    final c = text.codeUnitAt(start);
    if (c == 0x7b || c == 0x5b) {
      var depth = 0;
      var i = start;
      while (i < text.length) {
        final u = text.codeUnitAt(i);
        if (u == 0x22) {
          i = _stringEnd(text, i);
          continue;
        }
        if (u == 0x7b || u == 0x5b) depth++;
        if (u == 0x7d || u == 0x5d) {
          depth--;
          if (depth == 0) return i + 1;
        }
        i++;
      }
      return text.length;
    }
    final closed = c == 0x22 || c == 0x27 ? _stringEnd(text, start) : start;
    var end = closed;
    while (end < text.length) {
      final u = text.codeUnitAt(end);
      if (u == 0x2c || u == 0x7d || u == 0x5d) break;
      end++;
    }
    // Whitespace before the delimiter is not part of the value.
    while (end > closed && _isSpace(text.codeUnitAt(end - 1))) {
      end--;
    }
    return end == start ? null : end;
  }

  static bool _isSpace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

  /// End offset (exclusive) of the string whose opening quote is at [start],
  /// or the end of [text] when it is not closed.
  static int _stringEnd(String text, int start) {
    final quote = text.codeUnitAt(start);
    var i = start + 1;
    while (i < text.length) {
      final u = text.codeUnitAt(i);
      if (u == 0x5c) {
        i += 2;
        continue;
      }
      if (u == quote) return i + 1;
      i++;
    }
    return text.length;
  }
}

/// A range of a body: start offset, end offset (exclusive).
typedef _Span = (int, int);

class _Compiled {
  _Compiled(Set<String> headers, Set<String> jsonKeys)
    : headerNames = {for (final h in headers) h.toLowerCase()},
      keys = {for (final k in jsonKeys) k.toLowerCase()},
      keyPattern = jsonKeys.isEmpty ? null : _keyPattern(jsonKeys);

  final Set<String> headerNames;
  final Set<String> keys;

  /// Matches a sensitive key, its colon and following whitespace, in text
  /// holding one character per body byte: a key is looked for both as it is
  /// (Latin-1) and as its UTF-8 bytes.
  final RegExp? keyPattern;

  static RegExp _keyPattern(Set<String> keys) {
    final spellings = {
      for (final k in keys) ...[k, latin1.decode(utf8.encode(k))],
    };
    return RegExp(
      '"(?:${spellings.map(RegExp.escape).join('|')})"'
      r'\s*:\s*',
      caseSensitive: false,
    );
  }
}
