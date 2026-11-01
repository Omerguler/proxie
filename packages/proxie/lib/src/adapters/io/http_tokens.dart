import 'dart:convert';
import 'dart:io';

const _separators = '()<>@,;:\\"/[]?={} \t';

/// Whether every character of [s] is an HTTP token character (RFC 2616:
/// visible US-ASCII except separators), as `dart:io` checks methods and
/// header names.
bool isHttpToken(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c <= 31 || c >= 127 || _separators.contains(s[i])) return false;
  }
  return true;
}

/// [name] lowercased; throws a [FormatException] if it is not a token.
String validateHeaderName(String name) {
  if (!isHttpToken(name)) {
    throw FormatException(
      'Invalid HTTP header field name: ${json.encode(name)}',
      name,
    );
  }
  return name.toLowerCase();
}

/// [value] unchanged; throws a [FormatException] for a string holding
/// anything but visible US-ASCII, space or tab (so no line breaks).
Object validateHeaderValue(Object value) {
  if (value is String) {
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      if (!((c > 31 && c < 127) || c == 9)) {
        throw FormatException(
          'Invalid HTTP header field value: ${json.encode(value)}',
          value,
          i,
        );
      }
    }
  }
  return value;
}

/// Every value of [headers], separately, keyed by lowercase name.
Map<String, List<String>> headersToMap(HttpHeaders headers) {
  final map = <String, List<String>>{};
  headers.forEach((name, values) {
    (map[name.toLowerCase()] ??= []).addAll(values);
  });
  return map;
}
