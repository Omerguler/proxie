import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:proxie/adapter.dart';

/// Headers of a Dio request as Proxie stores them (one entry per value).
Map<String, List<String>> requestHeaders(Map<String, dynamic> headers) => {
  for (final e in headers.entries)
    if (e.value != null)
      e.key: e.value is Iterable
          ? [for (final v in e.value as Iterable) '$v']
          : ['${e.value}'],
};

/// The request body as Dio will send it, capped at [cap].
///
/// Data Dio encodes itself is encoded the same way here: a [Uint8List] is
/// sent as is, anything else (maps, lists, strings) goes through
/// [transformer] and `requestEncoder` (UTF-8 by default). Bodies that cannot
/// be read without consuming them get a text placeholder marked truncated,
/// so they are never replayed: [FormData] (`multipart/form-data: N fields,
/// M files`) and streams (`streamed body`).
Future<ProxieBody> captureRequestBody(
  RequestOptions options,
  Transformer transformer, {
  required int cap,
}) async {
  final Object? data = options.data;
  try {
    if (data == null) return ProxieBody.empty();
    if (data is Stream) {
      final length = int.tryParse(
        '${options.headers[Headers.contentLengthHeader] ?? ''}',
      );
      return _placeholder('streamed body', length ?? 0);
    }
    if (data is FormData) {
      return _placeholder(
        'multipart/form-data: ${data.fields.length} fields, '
        '${data.files.length} files',
        data.length,
      );
    }
    final Uint8List bytes;
    if (data is Uint8List) {
      bytes = data;
    } else {
      final transformed = _bypassesTransformer(data, options, transformer)
          ? '$data'
          : await transformer.transformRequest(options);
      final encoder = options.requestEncoder;
      if (encoder == null) {
        bytes = utf8.encode(transformed);
      } else {
        final encoded = await encoder(transformed, options);
        bytes = encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
      }
    }
    return ProxieBody.from(bytes, options.contentType, cap: cap);
  } on Object catch (e) {
    // Dio reports the same failure when it encodes the body itself.
    return _placeholder('body not captured: $e', 0);
  }
}

/// Whether [data] is a map Dio's built-in transformers only stringify (with
/// a warning): then the same text is produced here without logging that
/// warning a second time.
bool _bypassesTransformer(
  Object data,
  RequestOptions options,
  Transformer transformer,
) =>
    (transformer is SyncTransformer || transformer is FusedTransformer) &&
    data is Map &&
    data is! Map<String, dynamic> &&
    !Transformer.isJsonMimeType(options.contentType);

ProxieBody _placeholder(String text, int originalLength) => ProxieBody(
  bytes: Uint8List.fromList(utf8.encode(text)),
  contentType: 'text/plain; charset=utf-8',
  kind: BodyKind.text,
  truncated: true,
  originalLength: originalLength,
);

/// The bytes behind a decoded Dio response [data] (not a stream).
///
/// Maps and lists (decoded JSON) are encoded back to JSON, strings to UTF-8;
/// with [ResponseType.bytes] the data is the body itself.
Uint8List encodeResponseData(Object? data, ResponseType type) {
  if (data == null) return Uint8List(0);
  if (data is Uint8List) return data;
  if (data is String) return utf8.encode(data);
  if (type == ResponseType.bytes && data is List<int>) {
    return Uint8List.fromList(data);
  }
  if (data is Map || data is List || data is num || data is bool) {
    try {
      return utf8.encode(jsonEncode(data));
      // jsonEncode reports an unencodable object only with this Error, so it
      // is caught to fall back to the toString() form below.
      // ignore: avoid_catching_errors
    } on JsonUnsupportedObjectError {
      // A custom responseDecoder may produce objects JSON cannot hold.
    }
  }
  return utf8.encode('$data');
}

/// The stored body for a [ResponseType.stream] response: not read, so empty
/// and marked truncated, with the declared length if any.
ProxieBody streamedResponseBody(ResponseBody body, String? contentType) {
  final declared = body.headers[Headers.contentLengthHeader]?.first;
  final length = int.tryParse(declared ?? '');
  return ProxieBody(
    bytes: Uint8List(0),
    contentType: contentType,
    kind: BodyKind.empty,
    truncated: true,
    originalLength: length != null && length > 0 ? length : 0,
  );
}

/// [bytes] decoded the way Dio decodes a response body for [options]
/// (`responseType`, `responseDecoder`, JSON content types) with
/// [transformer].
///
/// Bytes that are not valid JSON under a JSON content type (edited at a
/// breakpoint or mocked) are handed over as UTF-8 text instead of failing
/// the call. Failures of an app-supplied `responseDecoder`, and anything
/// other than a [FormatException], propagate as they would in Dio.
Future<Object?> decodeResponseData(
  RequestOptions options,
  Transformer transformer,
  Uint8List bytes,
  int statusCode,
  Map<String, List<String>> headers,
) async {
  final decode = transformer.transformResponse(
    options,
    ResponseBody.fromBytes(
      bytes,
      statusCode,
      headers: {for (final e in headers.entries) e.key: List.of(e.value)},
    ),
  );
  if (options.responseDecoder != null) return await decode;
  try {
    return await decode;
  } on FormatException {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Whether two header maps hold the same names and values.
bool sameHeaders(Map<String, List<String>> a, Map<String, List<String>> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null || o.length != e.value.length) return false;
    for (var i = 0; i < o.length; i++) {
      if (o[i] != e.value[i]) return false;
    }
  }
  return true;
}

/// Whether [a] and [b] hold the same bytes.
bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
