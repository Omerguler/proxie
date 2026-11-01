import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'json_row.dart';
import 'json_schema.dart';

/// Longest [JsonRow.preview].
const int _previewLimit = 120;

final Converter<List<int>, Object?> _decoder = const Utf8Decoder().fuse(
  const JsonDecoder(),
);

/// A parsed JSON body flattened into parallel lists, with a windowed view of
/// its visible rows for a virtualized tree.
///
/// Node 0 is the root. It is not a row itself and is always expanded, so its
/// children are the initial rows; a scalar root is shown as a single row.
/// Every node's id is larger than its parent's.
///
/// Each container keeps the number of rows its subtree would show when
/// expanded; a toggle updates that count along the ancestor chain, and each
/// container caches prefix sums of its children's visible sizes (rebuilt
/// lazily once invalidated), so [rows] is O(count + depth · log(children)).
class JsonDocument {
  JsonDocument._(this.parseError);

  /// Parses UTF-8 JSON [bytes]. Never throws: invalid input yields a
  /// document with [parseError] set and no rows.
  static JsonDocument tryParse(Uint8List bytes) {
    try {
      final doc = JsonDocument._(null);
      doc._build(_decoder.convert(bytes));
      return doc;
    } on FormatException catch (e) {
      final at = e.offset == null ? '' : ' (at offset ${e.offset})';
      return JsonDocument._('Invalid JSON: ${e.message}$at');
    } catch (e) {
      return JsonDocument._('Could not parse JSON: $e');
    }
  }

  /// Why the body could not be parsed; null for a valid document.
  final String? parseError;

  // Per-node parallel lists, indexed by node id; -1 means "none".
  final List<int> _parent = [];
  final List<int> _firstChild = [];
  final List<int> _nextSibling = [];
  final List<JsonKind> _kind = [];
  final List<String?> _key = [];
  final List<int?> _index = [];

  /// Scalar values; null for containers.
  final List<Object?> _value = [];
  final List<int> _childCount = [];

  /// Distance from the root (root = 0).
  final List<int> _depth = [];
  final List<bool> _expanded = [];

  /// Rows the node's subtree shows below it while it is expanded, kept
  /// current whether or not it is expanded.
  final List<int> _inner = [];

  /// Child ids and prefix sums of their visible sizes, per container.
  final Map<int, _Children> _children = {};

  /// Inferred schemas per array node; a null value means "no objects".
  final Map<int, ArraySchema?> _schemas = {};

  int get _nodeCount => _parent.length;

  bool _isContainer(int id) =>
      _kind[id] == JsonKind.object || _kind[id] == JsonKind.array;

  bool get _scalarRoot => _nodeCount > 0 && !_isContainer(0);

  /// Number of rows currently shown.
  int get visibleCount {
    if (_nodeCount == 0) return 0;
    return _scalarRoot ? 1 : _inner[0];
  }

  void _build(Object? root) {
    _add(-1, root, null, null, 0);
    final ids = <int>[0];
    final values = <Object?>[root];
    while (ids.isNotEmpty) {
      final id = ids.removeLast();
      final value = values.removeLast();
      final depth = _depth[id] + 1;
      var prev = -1;
      void link(int child, Object? childValue) {
        if (prev == -1) {
          _firstChild[id] = child;
        } else {
          _nextSibling[prev] = child;
        }
        prev = child;
        if (_childCount[child] > 0) {
          ids.add(child);
          values.add(childValue);
        }
      }

      if (value is Map) {
        for (final e in value.entries) {
          link(_add(id, e.value, e.key as String, null, depth), e.value);
        }
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) {
          link(_add(id, value[i], null, i, depth), value[i]);
        }
      }
    }
    _expanded[0] = _isContainer(0);
  }

  int _add(int parent, Object? value, String? key, int? index, int depth) {
    final id = _nodeCount;
    final JsonKind kind;
    var count = 0;
    switch (value) {
      case Map():
        kind = JsonKind.object;
        count = value.length;
      case List():
        kind = JsonKind.array;
        count = value.length;
      case String():
        kind = JsonKind.string;
      case num():
        kind = JsonKind.number;
      case bool():
        kind = JsonKind.boolean;
      default:
        kind = JsonKind.nullValue;
    }
    _parent.add(parent);
    _firstChild.add(-1);
    _nextSibling.add(-1);
    _kind.add(kind);
    _key.add(key);
    _index.add(index);
    _value.add(kind.index > JsonKind.array.index ? value : null);
    _childCount.add(count);
    _depth.add(depth);
    _expanded.add(false);
    // Children start collapsed: one row each.
    _inner.add(count);
    return id;
  }

  /// Up to [count] visible rows starting at row [start]; fewer at the end.
  List<JsonRow> rows(int start, int count) {
    RangeError.checkNotNegative(start, 'start');
    RangeError.checkNotNegative(count, 'count');
    final total = visibleCount;
    if (start >= total || count == 0) return const [];
    if (_scalarRoot) return [_row(0)];
    final end = math.min(total, start + count);
    final out = <JsonRow>[];
    var id = _locate(start);
    for (var i = start; i < end; i++) {
      out.add(_row(id));
      id = _next(id);
    }
    return out;
  }

  /// The node shown at visible row [row] of a container root.
  int _locate(int row) {
    var parent = 0;
    var r = row;
    while (true) {
      final c = _childrenOf(parent);
      final prefix = c.prefix;
      // Largest i with prefix[i] <= r.
      var lo = 0;
      var hi = c.ids.length - 1;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (prefix[mid] <= r) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      final child = c.ids[lo];
      final offset = r - prefix[lo];
      if (offset == 0) return child;
      r = offset - 1;
      parent = child;
    }
  }

  /// The visible row after [id] in preorder, or -1.
  int _next(int id) {
    if (_expanded[id] && _firstChild[id] != -1) return _firstChild[id];
    var n = id;
    while (n > 0) {
      final s = _nextSibling[n];
      if (s != -1) return s;
      n = _parent[n];
    }
    return -1;
  }

  _Children _childrenOf(int id) => _children[id] ??= _buildChildren(id);

  _Children _buildChildren(int id) {
    final ids = Int32List(_childCount[id]);
    final prefix = Int32List(ids.length + 1);
    var c = _firstChild[id];
    for (var i = 0; i < ids.length; i++) {
      ids[i] = c;
      prefix[i + 1] = prefix[i] + 1 + (_expanded[c] ? _inner[c] : 0);
      c = _nextSibling[c];
    }
    return _Children(ids, prefix);
  }

  JsonRow _row(int id) => JsonRow(
    nodeId: id,
    depth: id == 0 ? 0 : _depth[id] - 1,
    key: _key[id],
    index: _index[id],
    kind: _kind[id],
    preview: _preview(id),
    childCount: _childCount[id],
    expanded: id != 0 && _expanded[id],
    missingKeys: _missingKeys(id),
  );

  /// The shape of the objects in array [arrayNodeId]; null when it is not an
  /// array or holds no objects. Cached until [invalidateSchema].
  ArraySchema? schemaOf(int arrayNodeId) {
    _checkId(arrayNodeId);
    if (_kind[arrayNodeId] != JsonKind.array) return null;
    if (_schemas.containsKey(arrayNodeId)) return _schemas[arrayNodeId];
    final builder = ArraySchemaBuilder();
    for (var item = _firstChild[arrayNodeId]; item != -1;) {
      if (_kind[item] == JsonKind.object) {
        builder.addObject();
        for (var m = _firstChild[item]; m != -1; m = _nextSibling[m]) {
          builder.addMember(_key[m]!, _kind[m]);
        }
      }
      item = _nextSibling[item];
    }
    return _schemas[arrayNodeId] = builder.build();
  }

  /// Drops the cached schema of [arrayNodeId]. Internal: for edits that
  /// change the array's items.
  void invalidateSchema(int arrayNodeId) => _schemas.remove(arrayNodeId);

  /// Optional schema fields that object [id] lacks, in schema order.
  List<String> _missingKeys(int id) {
    final parent = _parent[id];
    if (_kind[id] != JsonKind.object ||
        parent == -1 ||
        _kind[parent] != JsonKind.array) {
      return const [];
    }
    final optional = schemaOf(parent)!.fields.where((f) => f.optional);
    if (optional.isEmpty) return const [];
    final keys = {
      for (var m = _firstChild[id]; m != -1; m = _nextSibling[m]) _key[m],
    };
    return List.unmodifiable([
      for (final f in optional)
        if (!keys.contains(f.key)) f.key,
    ]);
  }

  /// Expands or collapses container [nodeId]; scalars and the root are left
  /// as they are. Nodes under a collapsed ancestor keep their new state for
  /// when the ancestor opens.
  void toggle(int nodeId) {
    _checkId(nodeId);
    if (nodeId == 0 || !_isContainer(nodeId)) return;
    final wasExpanded = _expanded[nodeId];
    _expanded[nodeId] = !wasExpanded;
    final delta = wasExpanded ? -_inner[nodeId] : _inner[nodeId];
    if (delta == 0) return;
    var a = _parent[nodeId];
    while (a != -1) {
      _inner[a] += delta;
      _children.remove(a);
      // A collapsed ancestor's own size is unchanged, so the rest is too.
      if (!_expanded[a]) break;
      a = _parent[a];
    }
  }

  /// Sets every container row at depth below [maxDepth] expanded and every
  /// deeper one collapsed (`maxDepth: 1` opens just the top-level rows).
  void expandAll({int maxDepth = 1 << 30}) {
    for (var id = 1; id < _nodeCount; id++) {
      _expanded[id] = _isContainer(id) && _depth[id] - 1 < maxDepth;
    }
    _recount();
  }

  /// Collapses every row; the root stays expanded.
  void collapseAll() {
    for (var id = 1; id < _nodeCount; id++) {
      _expanded[id] = false;
    }
    _recount();
  }

  /// Recomputes [_inner] bottom-up; relies on children having larger ids.
  void _recount() {
    _inner.fillRange(0, _nodeCount, 0);
    for (var id = _nodeCount - 1; id > 0; id--) {
      _inner[_parent[id]] += 1 + (_expanded[id] ? _inner[id] : 0);
    }
    _children.clear();
  }

  /// Member names and array indices from the root to [nodeId].
  List<Object> pathOf(int nodeId) {
    _checkId(nodeId);
    final path = <Object>[];
    for (var id = nodeId; id > 0; id = _parent[id]) {
      path.add(_key[id] ?? _index[id]!);
    }
    return path.reversed.toList();
  }

  /// The document as UTF-8 JSON, compact or indented by two spaces (the
  /// same output as [JsonEncoder]). Throws a [StateError] when there is a
  /// [parseError].
  ///
  /// Written iteratively from the flat model: [JsonEncoder] recurses and
  /// overflows the stack on deeply nested documents that parse fine.
  Uint8List encode({bool pretty = false}) {
    if (parseError != null) {
      throw StateError('Document has no JSON: $parseError');
    }
    final out = StringBuffer();
    final open = <int>[]; // containers being written
    final cursor = <int>[]; // next child to write in each of them

    void indent(int depth) {
      out.write('\n');
      for (var i = 0; i < depth; i++) {
        out.write('  ');
      }
    }

    void write(int id) {
      final kind = _kind[id];
      if (kind != JsonKind.object && kind != JsonKind.array) {
        _writeScalar(out, id);
      } else if (_childCount[id] == 0) {
        out.write(kind == JsonKind.object ? '{}' : '[]');
      } else {
        out.write(kind == JsonKind.object ? '{' : '[');
        open.add(id);
        cursor.add(_firstChild[id]);
      }
    }

    write(0);
    while (open.isNotEmpty) {
      final parent = open.last;
      final child = cursor.last;
      if (child == -1) {
        open.removeLast();
        cursor.removeLast();
        if (pretty) indent(open.length);
        out.write(_kind[parent] == JsonKind.object ? '}' : ']');
        continue;
      }
      if (child != _firstChild[parent]) out.write(',');
      if (pretty) indent(open.length);
      final key = _key[child];
      if (key != null) {
        _writeQuoted(out, key);
        out.write(pretty ? ': ' : ':');
      }
      cursor[cursor.length - 1] = _nextSibling[child];
      write(child);
    }
    return utf8.encode(out.toString());
  }

  void _writeScalar(StringBuffer out, int id) {
    final v = _value[id];
    if (v is String) {
      _writeQuoted(out, v);
    } else if (v is double) {
      out.write(_doubleText(v));
    } else {
      out.write(v); // num, bool or null print as JSON
    }
  }

  String _preview(int id) {
    switch (_kind[id]) {
      case JsonKind.object:
        final n = _childCount[id];
        return '{$n ${n == 1 ? 'key' : 'keys'}}';
      case JsonKind.array:
        final n = _childCount[id];
        return '[$n ${n == 1 ? 'item' : 'items'}]';
      case JsonKind.string:
        return _quotedPreview(_value[id] as String);
      case JsonKind.number:
        final v = _value[id];
        return v is double ? _doubleText(v) : '$v';
      case JsonKind.boolean:
      case JsonKind.nullValue:
        return '${_value[id]}';
    }
  }

  void _checkId(int nodeId) =>
      RangeError.checkValueInInterval(nodeId, 0, _nodeCount - 1, 'nodeId');
}

class _Children {
  _Children(this.ids, this.prefix);

  final Int32List ids;

  /// `prefix[i]` = rows shown by children before `ids[i]` (each child counts
  /// itself plus its visible descendants); length `ids.length + 1`.
  final Int32List prefix;
}

/// [s] JSON-quoted, cut to [_previewLimit] characters with a trailing '…'
/// (and no closing quote) when longer. Cuts never split an escape sequence
/// or a surrogate pair.
String _quotedPreview(String s) {
  // Room for the opening quote and the closing quote or the ellipsis.
  const room = _previewLimit - 2;
  final out = StringBuffer('"');
  var length = 0;
  var i = 0;
  while (i < s.length) {
    final cu = s.codeUnitAt(i);
    String unit;
    var consumed = 1;
    if (_isHighSurrogate(cu) &&
        i + 1 < s.length &&
        _isLowSurrogate(s.codeUnitAt(i + 1))) {
      unit = s.substring(i, i + 2);
      consumed = 2;
    } else {
      unit = _needsEscape(cu) ? _escape(cu) : String.fromCharCode(cu);
    }
    if (length + unit.length > room) {
      out.write('…');
      return out.toString();
    }
    out.write(unit);
    length += unit.length;
    i += consumed;
  }
  out.write('"');
  return out.toString();
}

/// Writes [s] as a JSON string literal, escaped exactly like [JsonEncoder].
void _writeQuoted(StringBuffer out, String s) {
  out.write('"');
  var runStart = 0;
  for (var i = 0; i < s.length; i++) {
    final cu = s.codeUnitAt(i);
    if (!_needsEscape(cu)) continue;
    if (_isHighSurrogate(cu) &&
        i + 1 < s.length &&
        _isLowSurrogate(s.codeUnitAt(i + 1))) {
      i++; // a valid pair is written as is
      continue;
    }
    if (runStart < i) out.write(s.substring(runStart, i));
    out.write(_escape(cu));
    runStart = i + 1;
  }
  if (runStart < s.length) {
    out.write(runStart == 0 ? s : s.substring(runStart));
  }
  out.write('"');
}

/// [v] as a JSON number. Literals too large for a double (e.g. `1e400`)
/// decode to infinity, which JSON cannot spell; `1e999` decodes back to it.
String _doubleText(double v) =>
    v.isFinite ? '$v' : (v.isNegative ? '-1e999' : '1e999');

bool _isHighSurrogate(int cu) => cu >= 0xD800 && cu <= 0xDBFF;

bool _isLowSurrogate(int cu) => cu >= 0xDC00 && cu <= 0xDFFF;

/// Control characters, quote, backslash and surrogates (escaped unless they
/// form a valid pair).
bool _needsEscape(int cu) =>
    cu < 0x20 || cu == 0x22 || cu == 0x5C || (cu >= 0xD800 && cu <= 0xDFFF);

String _escape(int cu) => switch (cu) {
  0x08 => r'\b',
  0x09 => r'\t',
  0x0A => r'\n',
  0x0C => r'\f',
  0x0D => r'\r',
  0x22 => r'\"',
  0x5C => r'\\',
  _ => '\\u${cu.toRadixString(16).padLeft(4, '0')}',
};
