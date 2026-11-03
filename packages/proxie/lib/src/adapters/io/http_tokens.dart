import 'dart:convert';
import 'dart:io';

import 'package:proxie/src/core/http_rules.dart';

export 'package:proxie/src/core/http_rules.dart' show isHttpToken;

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
/// anything but US-ASCII from space up (DEL included, as in `dart:io`) or
/// tab, so no line breaks.
Object validateHeaderValue(Object value) {
  if (value is String) {
    final i = unsendableHeaderChar(value);
    if (i >= 0) {
      throw FormatException(
        'Invalid HTTP header field value: ${json.encode(value)}',
        value,
        i,
      );
    }
  }
  return value;
}

/// [value] unchanged; throws a [FormatException] for a string holding CR,
/// LF or NUL, the only characters a header `dart:io` receives cannot hold.
Object validateReceivedHeaderValue(Object value) {
  if (value is String) {
    final i = unreceivableHeaderChar(value);
    if (i >= 0) {
      throw FormatException(
        'Invalid HTTP header field value: ${json.encode(value)}',
        value,
        i,
      );
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
