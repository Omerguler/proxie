part of 'json_document.dart';

/// [JsonDocument.search] and [JsonDocument.reveal].
extension _Searching on JsonDocument {
  List<int> _search(String query, int limit) {
    RangeError.checkNotNegative(limit, 'limit');
    if (query.isEmpty || limit == 0 || _n.length == 0) return const [];
    final q = query.toLowerCase();
    // An ASCII query is matched on the bytes of ASCII-only source text,
    // which lowercases to ASCII; such text cannot hold any other query.
    final ascii = q.codeUnits.every((c) => c < 0x80) ? q.codeUnits : null;
    final names = [for (final k in _n.keys) k.toLowerCase().contains(q)];
    final source = _source!;
    final hits = <int>[];

    bool matches(int id) {
      final p = _n.parent[id];
      if (p != -1 &&
          _n.kind(p) == JsonKind.object &&
          names[_n.keyOrIndex[id]]) {
        return true;
      }
      final start = _n.valueStart[id];
      switch (_n.kind(id)) {
        case JsonKind.object || JsonKind.array:
          return false;
        case JsonKind.string || JsonKind.number when _edited(id):
          return (_values[id]! as String).toLowerCase().contains(q);
        case JsonKind.string when _n.flags[id] & escapedFlag != 0:
          return decodeJsonString(source, start).toLowerCase().contains(q);
        case JsonKind.string:
          var end = start + 1;
          var nonAscii = false;
          for (int c; (c = source[end]) != 0x22; end++) {
            if (c >= 0x80) nonAscii = true;
          }
          if (nonAscii) {
            return utf8
                .decode(Uint8List.sublistView(source, start + 1, end))
                .toLowerCase()
                .contains(q);
          }
          return ascii != null && _containsAscii(source, start + 1, end, ascii);
        case JsonKind.number:
          return ascii != null &&
              _containsAscii(
                source,
                start,
                jsonNumberEnd(source, start),
                ascii,
              );
        case JsonKind.boolean:
          return (_boolean(id) ? 'true' : 'false').contains(q);
        case JsonKind.nullValue:
          return 'null'.contains(q);
      }
    }

    // Preorder over the linked tree: document order, edits included.
    var id = 0;
    while (true) {
      if (matches(id)) {
        hits.add(id);
        if (hits.length == limit) break;
      }
      if (_n.firstChild[id] != -1) {
        id = _n.firstChild[id];
        continue;
      }
      while (id > 0 && _n.nextSibling[id] == -1) {
        id = _n.parent[id];
      }
      if (id <= 0) break;
      id = _n.nextSibling[id];
    }
    return hits;
  }

  int _reveal(int nodeId) {
    _checkId(nodeId);
    if (_scalarRoot) return 0;
    if (nodeId == 0) {
      throw ArgumentError.value(nodeId, 'nodeId', 'The root is not a row');
    }
    final path = <int>[];
    for (var a = nodeId; a > 0; a = _n.parent[a]) {
      path.add(a);
      if (a != nodeId && !_n.expanded(a)) toggle(a);
    }
    var row = 0;
    for (var i = path.length - 1; i >= 0; i--) {
      final child = path[i];
      final parent = _n.parent[child];
      final c = _childrenOf(parent);
      // Array items know their index; object members are looked up in the
      // cached children.
      final at = _n.kind(parent) == JsonKind.array
          ? _n.keyOrIndex[child]
          : c.positionOf(child);
      // Rows of earlier siblings, then the row of each ancestor itself.
      row += c.prefix[at] + (i > 0 ? 1 : 0);
    }
    return row;
  }
}

/// Whether ASCII bytes `b[start, end)`, lowercased, contain [query]
/// (lowercase ASCII code units).
bool _containsAscii(Uint8List b, int start, int end, List<int> query) {
  final n = query.length;
  final first = query[0];
  for (var i = start; i <= end - n; i++) {
    if (_lowerAscii(b[i]) != first) continue;
    var j = 1;
    while (j < n && _lowerAscii(b[i + j]) == query[j]) {
      j++;
    }
    if (j == n) return true;
  }
  return false;
}

int _lowerAscii(int c) => c >= 0x41 && c <= 0x5A ? c | 0x20 : c;
