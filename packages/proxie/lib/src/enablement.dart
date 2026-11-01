import 'package:flutter/foundation.dart';

/// Whether Proxie is compiled in: always in debug builds, and in profile or
/// release builds only with `--dart-define=PROXIE=true`.
///
/// Every public entry point checks this constant first, so release builds
/// without the define tree-shake Proxie out. The runtime `enabled` flag of
/// `Proxie.init` can only disable it further.
const bool kProxieEnabled = kDebugMode || bool.fromEnvironment('PROXIE');
