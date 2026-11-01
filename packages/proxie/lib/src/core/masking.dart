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

  ProxieRequest maskRequest(ProxieRequest r) =>
      r.copyWith(headers: _maskHeaders(r.headers), body: _maskBody(r.body));

  ProxieResponse maskResponse(ProxieResponse r) =>
      r.copyWith(headers: _maskHeaders(r.headers), body: _maskBody(r.body));

  Map<String, List<String>> _maskHeaders(Map<String, List<String>> input) {
    final names = {for (final h in headers) h.toLowerCase()};
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
    final keys = {for (final k in jsonKeys) k.toLowerCase()};
    if (!body.truncated && body.bytes.length <= defaultBodyCap) {
      try {
        final masked = _walk(jsonDecode(text), keys);
        return ProxieBody.from(
          Uint8List.fromList(utf8.encode(jsonEncode(masked))),
          body.contentType,
        );
      } on FormatException {
        // Fall through to the text-level fallback (fail closed).
      }
    }
    final masked = _maskText(text);
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
    if (jsonKeys.isEmpty) return text;
    final alt = jsonKeys.map(RegExp.escape).join('|');
    final re = RegExp(
      '("(?:$alt)"\\s*:\\s*)'
      r'("(?:[^"\\]|\\.)*\\?"?|-?\d[\d.eE+-]*|true|false|null)',
      caseSensitive: false,
    );
    return text.replaceAllMapped(re, (m) => '${m[1]}"$kMask"');
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
