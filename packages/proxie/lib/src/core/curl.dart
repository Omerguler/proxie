import 'package:proxie/src/model/request.dart';

String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";

final _plainMethod = RegExp(r'^[A-Z0-9_-]+$');

/// Renders [request] as a copy-pasteable cURL command.
String toCurl(ProxieRequest request) {
  final body = request.body;
  final method = request.method;
  final parts = <String>['curl'];
  // curl sends POST for a body unless the method is stated explicitly.
  if (method.toUpperCase() != 'GET' || body.bytes.isNotEmpty) {
    parts.addAll([
      '-X',
      if (_plainMethod.hasMatch(method)) method else _q(method),
    ]);
  }
  parts.add(_q(request.url.toString()));
  for (final e in request.headers.entries) {
    if (e.key == 'content-length') continue;
    for (final v in e.value) {
      parts.addAll(['-H', _q('${e.key}: $v')]);
    }
  }
  if (body.bytes.isEmpty) return parts.join(' ');
  final notes = <String>[];
  final text = body.text;
  if (text != null) {
    parts.addAll(['--data-raw', _q(text)]);
  } else {
    parts.addAll(['--data-binary', '@body.bin']);
    notes.add('# binary body (${body.bytes.length} bytes) omitted');
  }
  if (body.truncated) {
    notes.add(
      '# body truncated: ${body.bytes.length} of ${body.originalLength} bytes',
    );
  }
  return [parts.join(' '), ...notes].join('\n');
}
