import 'dart:async';

/// Zone key marking code that a higher-level Proxie adapter already captures.
///
/// The `HttpOverrides` adapter skips requests made inside such a zone, so a
/// call is not recorded twice.
const Symbol kProxieCapturedZoneKey = #proxie.captured;

/// Runs [body] in a zone marked with [kProxieCapturedZoneKey].
R runMarkedCaptured<R>(R Function() body) =>
    runZoned(body, zoneValues: {kProxieCapturedZoneKey: true});

/// Whether the current zone is marked by [runMarkedCaptured].
bool isProxieCaptured() => Zone.current[kProxieCapturedZoneKey] == true;
