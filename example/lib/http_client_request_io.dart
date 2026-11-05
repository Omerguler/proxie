import 'dart:io';

/// GETs [url] with a plain `dart:io` [HttpClient], which
/// `ProxieHttpOverridesAdapter` captures.
Future<String> httpClientGet(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    final length = await response.fold<int>(0, (n, c) => n + c.length);
    return '${response.statusCode} ($length bytes)';
  } finally {
    client.close();
  }
}
