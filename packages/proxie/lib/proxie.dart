/// Proxie: in-app HTTP inspector for Flutter.
library;

export 'src/core/body_classifier.dart' show classifyBody;
export 'src/model/body.dart';
export 'src/model/call.dart';
export 'src/model/request.dart' hide normalizeHeaders;
export 'src/model/response.dart';

/// Current package version.
const kProxieVersion = '0.1.0';
