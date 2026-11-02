/// The reason phrase `dart:io`'s server sends for [statusCode].
String reasonPhraseFor(int statusCode) =>
    _phrases[statusCode] ?? 'Status $statusCode';

const _phrases = <int, String>{
  100: 'Continue',
  101: 'Switching Protocols',
  200: 'OK',
  201: 'Created',
  202: 'Accepted',
  203: 'Non-Authoritative Information',
  204: 'No Content',
  205: 'Reset Content',
  206: 'Partial Content',
  300: 'Multiple Choices',
  301: 'Moved Permanently',
  302: 'Found',
  303: 'See Other',
  304: 'Not Modified',
  305: 'Use Proxy',
  307: 'Temporary Redirect',
  400: 'Bad Request',
  401: 'Unauthorized',
  402: 'Payment Required',
  403: 'Forbidden',
  404: 'Not Found',
  405: 'Method Not Allowed',
  406: 'Not Acceptable',
  407: 'Proxy Authentication Required',
  408: 'Request Time-out',
  409: 'Conflict',
  410: 'Gone',
  411: 'Length Required',
  412: 'Precondition Failed',
  413: 'Request Entity Too Large',
  414: 'Request-URI Too Long',
  415: 'Unsupported Media Type',
  416: 'Requested range not satisfiable',
  417: 'Expectation Failed',
  500: 'Internal Server Error',
  501: 'Not Implemented',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
  504: 'Gateway Time-out',
  505: 'Http Version not supported',
};

/// Whether a [statusCode] answer to [method] is a redirect, as `dart:io`'s
/// `HttpClientResponse.isRedirect` decides.
bool isRedirectStatus(String method, int statusCode) {
  final upper = method.toUpperCase();
  if (upper == 'GET' || upper == 'HEAD') {
    return const {301, 302, 303, 307, 308}.contains(statusCode);
  }
  if (upper == 'POST') return statusCode == 303;
  return false;
}
