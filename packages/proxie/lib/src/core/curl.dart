import '../model/request.dart';

String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Renders [request] as a copy-pasteable cURL command.
String toCurl(ProxieRequest request) {
  final parts = <String>['curl'];
  if (request.method.toUpperCase() != 'GET') {
    parts.addAll(['-X', request.method]);
  }
  parts.add(_q(request.url.toString()));
  for (final e in request.headers.entries) {
    if (e.key == 'content-length') continue;
    for (final v in e.value) {
      parts.addAll(['-H', _q('${e.key}: $v')]);
    }
  }
  final body = request.body;
  if (body.bytes.isEmpty) return parts.join(' ');
  final text = body.text;
  if (text != null) {
    parts.addAll(['--data-raw', _q(text)]);
    return parts.join(' ');
  }
  parts.addAll(['--data-binary', '@body.bin']);
  return '${parts.join(' ')}\n# binary body (${body.bytes.length} bytes) omitted';
}
