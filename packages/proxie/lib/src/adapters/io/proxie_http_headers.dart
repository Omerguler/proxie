import 'dart:io';

import 'package:proxie/src/adapters/io/http_tokens.dart';

/// An HTTP/1.1 [HttpHeaders] for requests and responses Proxie builds itself
/// (`dart:io` offers no public constructor).
///
/// Mirrors `dart:io`'s behavior: names are case-insensitive (stored
/// lowercase, `preserveHeaderCase` keeps the given spelling for output),
/// names and values are validated, and `content-length`, `transfer-encoding`,
/// `host`, `connection`, `content-type` and the date headers keep their typed
/// properties in sync.
class ProxieHttpHeaders implements HttpHeaders {
  /// Empty headers; [defaultPort] is the scheme's port, omitted from `host`.
  ProxieHttpHeaders({int defaultPort = HttpClient.defaultHttpPort})
    : _defaultPort = defaultPort,
      _received = false;

  /// Immutable response headers holding every value of [values] separately,
  /// checked the way `dart:io` checks headers it receives.
  ///
  /// Values may hold any character except CR, LF and NUL (received headers
  /// can carry raw non-ASCII bytes, which `dart:io` reads as Latin-1).
  /// Single-value headers (`content-type`, `date`, `expires`,
  /// `if-modified-since`) keep every value; their typed getters read the
  /// first.
  ProxieHttpHeaders.received(
    Map<String, List<String>> values, {
    int defaultPort = HttpClient.defaultHttpPort,
  }) : _defaultPort = defaultPort,
       _received = true {
    for (final e in values.entries) {
      for (final v in e.value) {
        add(e.key, v);
      }
    }
    _mutable = false;
  }

  final int _defaultPort;
  final bool _received;
  final _headers = <String, List<String>>{};
  final _originalNames = <String, String>{};
  final _noFolding = <String>{};
  bool _mutable = true;
  int _contentLength = -1;
  bool _persistentConnection = true;
  bool _chunked = false;
  String? _host;
  int? _port;

  /// Makes these headers immutable, like `dart:io` does once they are sent.
  void freeze() => _mutable = false;

  /// The spelling to send [lowercaseName] with.
  String originalName(String lowercaseName) =>
      _originalNames[lowercaseName] ?? lowercaseName;

  /// Whether [name] was marked with [noFolding].
  bool isNoFolding(String name) => _noFolding.contains(name.toLowerCase());

  /// A copy of all values, keyed by lowercase name.
  Map<String, List<String>> toMap() => {
    for (final e in _headers.entries) e.key: List.of(e.value),
  };

  @override
  List<String>? operator [](String name) => _headers[validateHeaderName(name)];

  @override
  String? value(String name) {
    name = validateHeaderName(name);
    final values = _headers[name];
    if (values == null) return null;
    if (values.length > 1) {
      throw HttpException('More than one value for header $name');
    }
    return values.single;
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _checkMutable();
    final lower = validateHeaderName(name);
    if (preserveHeaderCase && name != lower) {
      _originalNames[lower] = name;
    } else {
      _originalNames.remove(lower);
    }
    _addAll(lower, value);
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _checkMutable();
    final lower = validateHeaderName(name);
    _headers.remove(lower);
    _originalNames.remove(lower);
    if (lower == HttpHeaders.contentLengthHeader) _contentLength = -1;
    if (lower == HttpHeaders.transferEncodingHeader) _chunked = false;
    if (preserveHeaderCase && name != lower) _originalNames[lower] = name;
    _addAll(lower, value);
  }

  @override
  void remove(String name, Object value) {
    _checkMutable();
    name = validateHeaderName(name);
    value = validateHeaderValue(value);
    final values = _headers[name];
    if (values != null) {
      values.remove(_valueToString(value));
      if (values.isEmpty) {
        _headers.remove(name);
        _originalNames.remove(name);
      }
    }
    if (name == HttpHeaders.transferEncodingHeader && value == 'chunked') {
      _chunked = false;
    }
  }

  @override
  void removeAll(String name) {
    _checkMutable();
    name = validateHeaderName(name);
    _headers.remove(name);
    _originalNames.remove(name);
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _headers.forEach((name, values) => action(originalName(name), values));
  }

  @override
  void noFolding(String name) => _noFolding.add(validateHeaderName(name));

  @override
  void clear() {
    _checkMutable();
    _headers.clear();
    _originalNames.clear();
    _contentLength = -1;
    _persistentConnection = true;
    _chunked = false;
    _host = null;
    _port = null;
  }

  @override
  bool get persistentConnection => _persistentConnection;

  @override
  set persistentConnection(bool value) {
    _checkMutable();
    if (value == _persistentConnection) return;
    if (value) {
      remove(HttpHeaders.connectionHeader, 'close');
    } else {
      add(
        originalName(HttpHeaders.connectionHeader),
        'close',
        preserveHeaderCase: true,
      );
    }
    _persistentConnection = value;
  }

  @override
  int get contentLength => _contentLength;

  @override
  set contentLength(int value) {
    _checkMutable();
    if (_contentLength == value) return;
    _contentLength = value;
    if (value >= 0) {
      if (_chunked) chunkedTransferEncoding = false;
      _set(HttpHeaders.contentLengthHeader, '$value');
    } else {
      _headers.remove(HttpHeaders.contentLengthHeader);
      chunkedTransferEncoding = true;
    }
  }

  @override
  bool get chunkedTransferEncoding => _chunked;

  @override
  set chunkedTransferEncoding(bool value) {
    _checkMutable();
    if (value == _chunked) return;
    if (value) {
      final values = _headers[HttpHeaders.transferEncodingHeader];
      if (values == null || !values.contains('chunked')) {
        _addValue(HttpHeaders.transferEncodingHeader, 'chunked');
      }
      _chunked = true;
      contentLength = -1;
    } else {
      remove(HttpHeaders.transferEncodingHeader, 'chunked');
      _chunked = false;
    }
  }

  @override
  String? get host => _host;

  @override
  set host(String? value) {
    _checkMutable();
    _host = value;
    _updateHost();
  }

  @override
  int? get port => _port;

  @override
  set port(int? value) {
    _checkMutable();
    _port = value;
    _updateHost();
  }

  @override
  DateTime? get date => _date(HttpHeaders.dateHeader);

  @override
  set date(DateTime? value) => _setDate(HttpHeaders.dateHeader, value);

  @override
  DateTime? get expires => _date(HttpHeaders.expiresHeader);

  @override
  set expires(DateTime? value) => _setDate(HttpHeaders.expiresHeader, value);

  @override
  DateTime? get ifModifiedSince => _date(HttpHeaders.ifModifiedSinceHeader);

  @override
  set ifModifiedSince(DateTime? value) =>
      _setDate(HttpHeaders.ifModifiedSinceHeader, value);

  @override
  ContentType? get contentType {
    final values = _headers[HttpHeaders.contentTypeHeader];
    return values == null ? null : ContentType.parse(values.first);
  }

  @override
  set contentType(ContentType? value) {
    _checkMutable();
    if (value == null) {
      _headers.remove(HttpHeaders.contentTypeHeader);
    } else {
      _set(HttpHeaders.contentTypeHeader, value.toString());
    }
  }

  @override
  String toString() {
    final sb = StringBuffer();
    _headers.forEach((name, values) {
      final shown = originalName(name);
      final fold = name != HttpHeaders.setCookieHeader && !isNoFolding(name);
      sb.write('$shown: ');
      for (var i = 0; i < values.length; i++) {
        if (i > 0) sb.write(fold ? ', ' : '\n$shown: ');
        sb.write(values[i]);
      }
      sb.write('\n');
    });
    return sb.toString();
  }

  void _addAll(String name, Object value) {
    if (value is Iterable) {
      for (final v in value) {
        _add(name, _checkValue(v as Object));
      }
    } else {
      _add(name, _checkValue(value));
    }
  }

  Object _checkValue(Object value) => _received
      ? validateReceivedHeaderValue(value)
      : validateHeaderValue(value);

  void _add(String name, Object value) {
    switch (name) {
      case HttpHeaders.contentLengthHeader:
        _addContentLength(value);
      case HttpHeaders.transferEncodingHeader:
        if (value == 'chunked') {
          chunkedTransferEncoding = true;
        } else {
          _addValue(name, value);
        }
      case HttpHeaders.dateHeader ||
          HttpHeaders.expiresHeader ||
          HttpHeaders.ifModifiedSinceHeader:
        if (value is DateTime) {
          _setDate(name, value);
        } else if (value is String) {
          _received ? _addValue(name, value) : _set(name, value);
        } else {
          throw HttpException('Unexpected type for header named $name');
        }
      case HttpHeaders.hostHeader:
        _addHost(_checkString(name, value));
      case HttpHeaders.connectionHeader:
        final v = _checkString(name, value).toLowerCase();
        if (v == 'close') _persistentConnection = false;
        if (v == 'keep-alive') _persistentConnection = true;
        _addValue(name, value);
      case HttpHeaders.contentTypeHeader:
        final v = _checkString(name, value);
        _received ? _addValue(name, v) : _set(name, v);
      default:
        _addValue(name, value);
    }
  }

  void _addContentLength(Object value) {
    if (value is int) {
      if (value < 0) {
        throw const HttpException('Content-Length must contain only digits');
      }
      contentLength = value;
      return;
    }
    if (value is String && value.isNotEmpty) {
      if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
        throw const HttpException('Content-Length must contain only digits');
      }
      final digits = value.replaceFirst(RegExp('^0+'), '');
      if (digits.length >= 16) {
        throw const HttpException('Content-Length too large');
      }
      contentLength = digits.isEmpty ? 0 : int.parse(digits);
      return;
    }
    throw const HttpException(
      'Unexpected type for header named ${HttpHeaders.contentLengthHeader}',
    );
  }

  void _addHost(String value) {
    final pos = value.lastIndexOf(':');
    if (pos < 0 || value.startsWith('[') && value.endsWith(']')) {
      _host = value;
      _port = HttpClient.defaultHttpPort;
    } else {
      _host = pos > 0 ? value.substring(0, pos) : null;
      _port = pos + 1 == value.length
          ? HttpClient.defaultHttpPort
          : int.tryParse(value.substring(pos + 1));
    }
    _set(HttpHeaders.hostHeader, value);
  }

  void _updateHost() {
    final host = _host;
    if (host == null) return;
    final defaultPort = _port == null || _port == _defaultPort;
    _set(HttpHeaders.hostHeader, defaultPort ? host : '$host:$_port');
  }

  DateTime? _date(String name) {
    final values = _headers[name];
    if (values == null) return null;
    try {
      return HttpDate.parse(values.first);
    } on Exception {
      return null;
    }
  }

  void _setDate(String name, DateTime? value) {
    _checkMutable();
    if (value == null) {
      _headers.remove(name);
    } else {
      _set(name, HttpDate.format(value.toUtc()));
    }
  }

  void _addValue(String name, Object value) =>
      (_headers[name] ??= <String>[]).add(_valueToString(value));

  void _set(String name, String value) => _headers[name] = [value];

  void _checkMutable() {
    if (!_mutable) throw const HttpException('HTTP headers are not mutable');
  }

  static String _checkString(String name, Object value) {
    if (value is String) return value;
    throw HttpException('Unexpected type for header named $name');
  }

  static String _valueToString(Object value) {
    if (value is DateTime) return HttpDate.format(value);
    if (value is String) return value;
    return validateHeaderValue(value.toString()) as String;
  }
}
