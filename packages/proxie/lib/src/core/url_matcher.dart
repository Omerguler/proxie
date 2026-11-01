/// Matches request URLs against a wildcard or regular-expression pattern.
class UrlMatcher {
  UrlMatcher(this.pattern, {this.isRegex = false});

  factory UrlMatcher.fromMap(Map<dynamic, dynamic> map) => UrlMatcher(
    map['pattern'] as String,
    isRegex: map['isRegex'] as bool? ?? false,
  );

  final String pattern;
  final bool isRegex;

  RegExp? _compiled;
  bool _compileFailed = false;

  RegExp? get _regex {
    if (_compiled != null || _compileFailed) return _compiled;
    try {
      _compiled = isRegex
          ? RegExp(pattern)
          : RegExp(_wildcardToRegex(pattern), caseSensitive: false);
    } on FormatException {
      _compileFailed = true;
    }
    return _compiled;
  }

  /// Whether [url] matches. An invalid regular expression never matches.
  ///
  /// Wildcard patterns are case-insensitive. Those without `://` are matched against the URL with its
  /// scheme removed (`host/path?query`) as well as the full URL.
  bool matches(Uri url) {
    final regex = _regex;
    if (regex == null) return false;
    final full = url.toString();
    if (regex.hasMatch(full)) return true;
    if (isRegex || pattern.contains('://')) return false;
    final i = full.indexOf('://');
    return i >= 0 && regex.hasMatch(full.substring(i + 3));
  }

  @override
  bool operator ==(Object other) =>
      other is UrlMatcher &&
      other.pattern == pattern &&
      other.isRegex == isRegex;

  @override
  int get hashCode => Object.hash(pattern, isRegex);

  Map<String, Object?> toMap() => {'pattern': pattern, 'isRegex': isRegex};

  static String _wildcardToRegex(String pattern) {
    final b = StringBuffer('^');
    for (final rune in pattern.runes) {
      final c = String.fromCharCode(rune);
      b.write(c == '*' ? '.*' : RegExp.escape(c));
    }
    b.write(r'$');
    return b.toString();
  }
}
