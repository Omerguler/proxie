import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// Whether [a] and [b] hold the same names and values, in the same order
/// per name. The models keep names lowercase, so names compare exactly.
bool sameHeaders(Map<String, List<String>> a, Map<String, List<String>> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null || !_sameList(o, e.value)) return false;
  }
  return true;
}

/// Whether [a] and [b] would send the same: method (editors uppercase it,
/// so case is ignored), URL, headers and body bytes.
bool sameRequest(ProxieRequest a, ProxieRequest b) =>
    a.method.toUpperCase() == b.method.toUpperCase() &&
    a.url == b.url &&
    sameHeaders(a.headers, b.headers) &&
    _sameList(a.body.bytes, b.body.bytes);

/// Whether [a] and [b] hold the same status, reason, headers and body bytes.
bool sameResponse(ProxieResponse a, ProxieResponse b) =>
    a.statusCode == b.statusCode &&
    a.reasonPhrase == b.reasonPhrase &&
    sameHeaders(a.headers, b.headers) &&
    _sameList(a.body.bytes, b.body.bytes);

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
