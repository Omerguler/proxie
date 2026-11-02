import 'dart:convert';
import 'dart:typed_data';

import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/response.dart';

/// A one-tap Map Local response template.
class ResponsePreset {
  const ResponsePreset({
    required this.id,
    required this.label,
    required this.build,
  });

  final String id;
  final String label;

  /// Builds the action; [captured] is the call's real response, if any.
  final MapLocalAction Function(ProxieResponse? captured) build;
}

const _reasons = <int, String>{
  200: 'OK',
  201: 'Created',
  204: 'No Content',
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  422: 'Unprocessable Entity',
  429: 'Too Many Requests',
  500: 'Internal Server Error',
  503: 'Service Unavailable',
};

ProxieResponse _json(
  int status,
  String body, {
  Map<String, List<String>> headers = const {},
}) => ProxieResponse(
  statusCode: status,
  reasonPhrase: _reasons[status],
  headers: {
    'content-type': ['application/json'],
    ...headers,
  },
  body: ProxieBody.from(
    Uint8List.fromList(utf8.encode(body)),
    'application/json',
  ),
);

ResponsePreset _fixed(String id, String label, ProxieResponse response) =>
    ResponsePreset(
      id: id,
      label: label,
      build: (_) => MapLocalAction(response: response),
    );

ResponsePreset _error(
  String id,
  String label,
  int status, {
  Map<String, List<String>> headers = const {},
}) => _fixed(
  id,
  label,
  _json(
    status,
    '{"error":{"code":$status,"message":"${_reasons[status] ?? 'Unknown'}"}}',
    headers: headers,
  ),
);

ProxieResponse _capturedOrEmpty(ProxieResponse? captured) =>
    captured ??
    ProxieResponse(
      statusCode: 200,
      reasonPhrase: _reasons[200],
      headers: const {},
      body: ProxieBody.empty(),
    );

/// The presets shipped with Proxie.
final List<ResponsePreset> builtInPresets = List.unmodifiable([
  ResponsePreset(
    id: 'ok_captured',
    label: '200 OK (captured body)',
    build: (captured) => MapLocalAction(response: _capturedOrEmpty(captured)),
  ),
  _fixed('ok_empty_list', '200 OK (empty list)', _json(200, '[]')),
  _fixed('created', '201 Created', _json(201, '{}')),
  _fixed(
    'no_content',
    '204 No Content',
    ProxieResponse(
      statusCode: 204,
      reasonPhrase: _reasons[204],
      headers: const {},
      body: ProxieBody.empty(),
    ),
  ),
  _error('bad_request', '400 Bad Request', 400),
  _error('unauthorized', '401 Unauthorized', 401),
  _error('forbidden', '403 Forbidden', 403),
  _error('not_found', '404 Not Found', 404),
  _fixed(
    'unprocessable',
    '422 Unprocessable Entity',
    _json(422, '{"errors":{"field":["is invalid"]}}'),
  ),
  _error(
    'too_many',
    '429 Too Many Requests',
    429,
    headers: {
      'retry-after': ['30'],
    },
  ),
  _error('server_error', '500 Server Error', 500),
  _error('unavailable', '503 Service Unavailable', 503),
  ResponsePreset(
    id: 'timeout',
    label: 'Timeout',
    build: (_) => const MapLocalAction(failure: SimulatedFailure.timeout),
  ),
  ResponsePreset(
    id: 'no_connection',
    label: 'No connection',
    build: (_) => const MapLocalAction(failure: SimulatedFailure.noConnection),
  ),
  ResponsePreset(
    id: 'slow',
    label: 'Slow (3 s delay)',
    build: (captured) => MapLocalAction(
      response: _capturedOrEmpty(captured),
      delay: const Duration(seconds: 3),
    ),
  ),
]);
