import 'dart:convert';
import 'dart:typed_data';

import '../model/body.dart';
import '../model/request.dart';
import '../model/response.dart';

/// Replacement for masked values.
const kMask = '••••••';

/// Masks sensitive headers and JSON keys on stored/displayed copies.
class ProxieMasking {
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

  static const defaults = ProxieMasking();

  /// Header names to mask (case-insensitive).
  final Set<String> headers;

  /// JSON object keys to mask at any depth (case-insensitive).
  final Set<String> jsonKeys;

  // Lowercased name sets and the fallback key matcher, computed once per
  // instance. Kept outside the instance so the class stays const-constructible.
  static final Expando<_Compiled> _cache = Expando<_Compiled>();

  _Compiled get _compiled => _cache[this] ??= _Compiled(headers, jsonKeys);

  ProxieRequest maskRequest(ProxieRequest r) =>
      r.copyWith(headers: _maskHeaders(r.headers), body: _maskBody(r.body));

  ProxieResponse maskResponse(ProxieResponse r) =>
      r.copyWith(headers: _maskHeaders(r.headers), body: _maskBody(r.body));

  Map<String, List<String>> _maskHeaders(Map<String, List<String>> input) {
    final names = _compiled.headerNames;
    return {
      for (final e in input.entries)
        e.key: names.contains(e.key.toLowerCase())
            ? [for (final _ in e.value) kMask]
            : List<String>.of(e.value),
    };
  }

  ProxieBody _maskBody(ProxieBody body) {
    final isJson =
        body.kind == BodyKind.json ||
        (body.contentType?.toLowerCase().contains('json') ?? false);
    if (!isJson || body.bytes.isEmpty) return body;
    final text = body.text;
    if (text == null) return body;
    String? masked;
    if (!body.truncated && body.bytes.length <= defaultBodyCap) {
      try {
        final tree = _walk(jsonDecode(text), _compiled.keys);
        masked = text.contains('\n')
            ? const JsonEncoder.withIndent('  ').convert(tree)
            : jsonEncode(tree);
      } on FormatException {
        // Fall through to the text-level fallback (fail closed).
      }
    }
    masked ??= _maskText(text);
    if (masked == text) return body;
    return ProxieBody(
      bytes: Uint8List.fromList(utf8.encode(masked)),
      contentType: body.contentType,
      kind: body.kind,
      truncated: body.truncated,
      originalLength: body.originalLength,
    );
  }

  /// Replaces values of sensitive keys without parsing, for bodies that are
  /// truncated, oversized, or not valid JSON.
  String _maskText(String text) {
    final keyRe = _compiled.keyPattern;
    if (keyRe == null) return text;
    final out = StringBuffer();
    var copied = 0;
    for (final m in keyRe.allMatches(text)) {
      if (m.start < copied) continue; // inside an already masked value
      final valueStart = m.end;
      final valueEnd = _valueEnd(text, valueStart);
      if (valueEnd == null) continue;
      out
        ..write(text.substring(copied, valueStart))
        ..write('"$kMask"');
      copied = valueEnd;
    }
    if (copied == 0) return text;
    out.write(text.substring(copied));
    return out.toString();
  }

  static final _scalar = RegExp(r'-?\d[\d.eE+-]*|true|false|null');

  /// End offset of the JSON value starting at [start], or null if there is no
  /// recognisable value. Containers and strings run to the end of [text] when
  /// they are not closed (truncated body).
  static int? _valueEnd(String text, int start) {
    if (start >= text.length) return null;
    final c = text.codeUnitAt(start);
    if (c == 0x22) return _stringEnd(text, start);
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
    return _scalar.matchAsPrefix(text, start)?.end;
  }

  /// End offset (exclusive) of the string whose opening quote is at [start].
  static int _stringEnd(String text, int start) {
    var i = start + 1;
    while (i < text.length) {
      final u = text.codeUnitAt(i);
      if (u == 0x5c) {
        i += 2;
        continue;
      }
      if (u == 0x22) return i + 1;
      i++;
    }
    return text.length;
  }

  Object? _walk(Object? node, Set<String> keys) {
    if (node is Map) {
      return {
        for (final e in node.entries)
          e.key as String: keys.contains((e.key as String).toLowerCase())
              ? kMask
              : _walk(e.value, keys),
      };
    }
    if (node is List) return [for (final v in node) _walk(v, keys)];
    return node;
  }
}

class _Compiled {
  _Compiled(Set<String> headers, Set<String> jsonKeys)
    : headerNames = {for (final h in headers) h.toLowerCase()},
      keys = {for (final k in jsonKeys) k.toLowerCase()},
      keyPattern = jsonKeys.isEmpty
          ? null
          : RegExp(
              '"(?:${jsonKeys.map(RegExp.escape).join('|')})"'
              r'\s*:\s*',
              caseSensitive: false,
            );

  final Set<String> headerNames;
  final Set<String> keys;

  /// Matches a sensitive key, its colon and following whitespace.
  final RegExp? keyPattern;
}
