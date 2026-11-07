/// Web stand-in: `dart:io` does not exist there, and the button is hidden.
Future<String> httpClientGet(Uri url) =>
    throw UnsupportedError('HttpClient is not available on the web');
