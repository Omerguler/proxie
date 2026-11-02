import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;
import 'package:proxie/src/json/json_nodes.dart';
import 'package:proxie/src/json/json_parser.dart';
import 'package:proxie/src/json/json_row.dart';
import 'package:proxie/src/json/json_schema.dart';

part 'json_edit.dart';
part 'json_search.dart';

/// Longest [JsonRow.preview].
const int _previewLimit = 120;

/// Deepest container nesting [JsonDocument.encode] indents.
const int _prettyMaxDepth = 512;

/// A parsed JSON body in typed parallel arrays, with a windowed view of its
/// visible rows for a virtualized tree.
///
/// Scalars are not converted: parsed ones point into the retained source
/// bytes, so previews and [encode] keep numbers exactly as written (no int64
/// or double rounding) and duplicate member names stay separate members.
/// Scalars set by [apply] have no source text; their values (string text,
/// number lexeme or bool) live in a side table keyed by node id.
///
/// Node 0 is the root. It is not a row itself and is always expanded, so its
/// children are the initial rows; a scalar root is shown as a single row.
/// Every node's id is larger than its parent's.
///
/// Each container keeps the number of rows its subtree would show when
/// expanded; a toggle updates that count along the ancestor chain, and each
/// container caches prefix sums of its children's visible sizes (rebuilt
/// lazily once invalidated), so [rows] is O(count + depth · log(children)).
///
/// [apply] edits the tree in place. Node ids stay stable: new nodes are
/// appended with new ids and deleted ones are unlinked and retired, never
/// reused or compacted away.
class JsonDocument {
  JsonDocument._(this.parseError, this._source, this._n);

  /// Parses UTF-8 JSON [bytes], which are retained and must not be modified
  /// afterwards. Never throws: invalid input yields a document with
  /// [parseError] set and no rows.
  factory JsonDocument.tryParse(Uint8List bytes) {
    try {
      return JsonDocument._(null, bytes, parseJson(bytes));
    } on FormatException catch (e) {
      final at = e.offset == null ? '' : ' (at offset ${e.offset})';
      return JsonDocument._('Invalid JSON: ${e.message}$at', null, JsonNodes());
    } on Object catch (e, st) {
      // Only a bug (or running out of memory) gets here; surface it in debug.
      assert(false, 'JsonDocument.tryParse failed: $e\n$st');
      return JsonDocument._(
        'Could not parse JSON (${e.runtimeType}): $e',
        null,
        JsonNodes(),
      );
    }
  }

  /// Why the body could not be parsed; null for a valid document.
  final String? parseError;

  final Uint8List? _source;
  final JsonNodes _n;

  /// Child ids and prefix sums of their visible sizes, per container.
  final Map<int, _Children> _children = {};

  /// Inferred schemas per array node; a null value means "no objects".
  final Map<int, ArraySchema?> _schemas = {};

  /// Quoted UTF-8 member names, per key id, built on first [encode].
  List<Uint8List>? _encodedKeys;

  /// Key id per member name, built on the first edit that needs it.
  Map<String, int>? _keyIds;

  /// Values of scalars set by edits (marked [editedFlag]): the text of a
  /// string, the lexeme of a number, or a [bool].
  final Map<int, Object> _values = {};

  /// Nodes retired by edits; they keep their storage.
  int _deleted = 0;

  /// Last child per container, as of the last append; a hint that is used
  /// only while it is still a live last child of that container.
  final Map<int, int> _lastChild = {};

  /// Most node slots an edit may grow storage to; an edit that would need
  /// more capacity throws a [StateError] and changes nothing. Null for no
  /// limit. A document parsed above the limit can still take edits that fit
  /// in its current capacity.
  int? maxCapacity;

  bool _dirty = false;

  /// Whether an edit has changed the document.
  bool get dirty => _dirty;

  /// Number of values in the document (0 when it did not parse); nodes
  /// removed by edits are not counted.
  int get nodeCount => _n.length - _deleted;

  /// Node slots allocated in storage, used or not, including those of
  /// removed nodes; what the document's memory grows with.
  int get storedCapacity => _n.capacity;

  /// Applies [edit] and returns the new [visibleCount]. Throws a
  /// [StateError] when there is a [parseError] or when the edit would grow
  /// storage beyond [maxCapacity], and an [ArgumentError] when the edit does
  /// not apply (see [JsonEdit]); either way the document is unchanged.
  int apply(JsonEdit edit) {
    if (parseError != null) {
      throw StateError('Document has no JSON: $parseError');
    }
    _apply(edit);
    return visibleCount;
  }

  bool get _scalarRoot => _n.length > 0 && !_n.isContainer(0);

  /// Number of rows currently shown.
  int get visibleCount {
    if (_n.length == 0) return 0;
    return _scalarRoot ? 1 : _n.inner[0];
  }

  /// Up to [count] visible rows starting at row [start]; fewer at the end.
  List<JsonRow> rows(int start, int count) {
    RangeError.checkNotNegative(start, 'start');
    RangeError.checkNotNegative(count, 'count');
    final total = visibleCount;
    if (start >= total || count == 0) return const [];
    if (_scalarRoot) return [_row(0, 0)];
    final end = math.min(total, start + count);
    final out = <JsonRow>[];
    var id = _locate(start);
    var depth = -1;
    for (var a = id; a > 0; a = _n.parent[a]) {
      depth++;
    }
    for (var i = start; i < end; i++) {
      out.add(_row(id, depth));
      // Next row in preorder.
      if (_n.expanded(id) && _n.firstChild[id] != -1) {
        id = _n.firstChild[id];
        depth++;
        continue;
      }
      while (id > 0 && _n.nextSibling[id] == -1) {
        id = _n.parent[id];
        depth--;
      }
      if (id <= 0) break;
      id = _n.nextSibling[id];
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

  _Children _childrenOf(int id) => _children[id] ??= _buildChildren(id);

  _Children _buildChildren(int id) {
    final ids = Int32List(_n.childCount[id]);
    final prefix = Int32List(ids.length + 1);
    var c = _n.firstChild[id];
    for (var i = 0; i < ids.length; i++) {
      ids[i] = c;
      prefix[i + 1] = prefix[i] + 1 + (_n.expanded(c) ? _n.inner[c] : 0);
      c = _n.nextSibling[c];
    }
    return _Children(ids, prefix);
  }

  bool _inObject(int id) {
    final p = _n.parent[id];
    return p != -1 && _n.kind(p) == JsonKind.object;
  }

  JsonRow _row(int id, int depth) {
    final inObject = _inObject(id);
    final hasParent = _n.parent[id] != -1;
    return JsonRow(
      nodeId: id,
      depth: depth,
      key: inObject ? _n.keys[_n.keyOrIndex[id]] : null,
      index: hasParent && !inObject ? _n.keyOrIndex[id] : null,
      kind: _n.kind(id),
      preview: _preview(id),
      childCount: _n.childCount[id],
      expanded: id != 0 && _n.expanded(id),
      missingKeys: _missingKeys(id),
    );
  }

  /// The shape of the objects in array [arrayNodeId]; null when it is not an
  /// array or holds no objects. Cached until an edit changes the array's
  /// items or their members.
  ArraySchema? schemaOf(int arrayNodeId) {
    _checkId(arrayNodeId);
    if (_n.kind(arrayNodeId) != JsonKind.array) return null;
    if (_schemas.containsKey(arrayNodeId)) return _schemas[arrayNodeId];
    final builder = ArraySchemaBuilder(_n.keys);
    for (var item = _n.firstChild[arrayNodeId]; item != -1;) {
      if (_n.kind(item) == JsonKind.object) {
        builder.addObject();
        for (var m = _n.firstChild[item]; m != -1; m = _n.nextSibling[m]) {
          builder.addMember(_n.keyOrIndex[m], _n.kind(m));
        }
      }
      item = _n.nextSibling[item];
    }
    return _schemas[arrayNodeId] = builder.build();
  }

  /// Drops the cached schema of [arrayNodeId]; every edit that changes an
  /// array's items or their members goes through here.
  void _invalidateSchema(int arrayNodeId) => _schemas.remove(arrayNodeId);

  /// Optional schema fields that object [id] lacks, in schema order.
  List<String> _missingKeys(int id) {
    final parent = _n.parent[id];
    if (_n.kind(id) != JsonKind.object ||
        parent == -1 ||
        _n.kind(parent) != JsonKind.array) {
      return const [];
    }
    final optional = schemaOf(parent)!.fields.where((f) => f.optional);
    if (optional.isEmpty) return const [];
    final keys = {
      for (var m = _n.firstChild[id]; m != -1; m = _n.nextSibling[m])
        _n.keys[_n.keyOrIndex[m]],
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
    if (nodeId == 0 || !_n.isContainer(nodeId)) return;
    final wasExpanded = _n.expanded(nodeId);
    _n.setExpanded(nodeId, expanded: !wasExpanded);
    final delta = wasExpanded ? -_n.inner[nodeId] : _n.inner[nodeId];
    if (delta == 0) return;
    var a = _n.parent[nodeId];
    while (a != -1) {
      _n.inner[a] += delta;
      _children.remove(a);
      // A collapsed ancestor's own size is unchanged, so the rest is too.
      if (!_n.expanded(a)) break;
      a = _n.parent[a];
    }
  }

  /// Sets every container row at depth below [maxDepth] expanded and every
  /// deeper one collapsed (`maxDepth: 1` opens just the top-level rows).
  void expandAll({int maxDepth = 1 << 30}) {
    // Row depth of each node, filled in id order (parents come first).
    final depth = Int32List(_n.length);
    for (var id = 1; id < _n.length; id++) {
      if (_n.deleted(id)) continue;
      final p = _n.parent[id];
      depth[id] = p == 0 ? 0 : depth[p] + 1;
      _n.setExpanded(id, expanded: _n.isContainer(id) && depth[id] < maxDepth);
    }
    _recount();
  }

  /// Collapses every row; the root stays expanded.
  void collapseAll() {
    for (var id = 1; id < _n.length; id++) {
      _n.setExpanded(id, expanded: false);
    }
    _recount();
  }

  /// Recomputes [JsonNodes.inner] bottom-up; relies on children having
  /// larger ids.
  void _recount() {
    final inner = _n.inner..fillRange(0, _n.length, 0);
    for (var id = _n.length - 1; id > 0; id--) {
      if (_n.deleted(id)) continue;
      inner[_n.parent[id]] += 1 + (_n.expanded(id) ? inner[id] : 0);
    }
    _children.clear();
  }

  /// Member names and array indices from the root to [nodeId].
  List<Object> pathOf(int nodeId) {
    _checkId(nodeId);
    final path = <Object>[];
    for (var id = nodeId; id > 0; id = _n.parent[id]) {
      final k = _n.keyOrIndex[id];
      path.add(_inObject(id) ? _n.keys[k] : k);
    }
    return path.reversed.toList();
  }

  /// Ids of up to [limit] nodes whose member name or scalar value contains
  /// [query], ignoring case, in document order. Strings and names are
  /// matched decoded, numbers by their lexeme, and `true` / `false` / `null`
  /// by name. Containers match by name only. An empty [query], or a
  /// document that did not parse, finds nothing.
  List<int> search(String query, {int limit = 500}) => _search(query, limit);

  /// The whole value of scalar [nodeId] as text, unlike the shortened
  /// [JsonRow.preview]: a string's decoded text, a number's lexeme, or
  /// `true`, `false` or `null`. Throws an [ArgumentError] for a container.
  String scalarText(int nodeId) {
    _checkId(nodeId);
    final start = _n.valueStart[nodeId];
    return switch (_n.kind(nodeId)) {
      JsonKind.object || JsonKind.array => throw ArgumentError.value(
        nodeId,
        'nodeId',
        'Not a scalar',
      ),
      JsonKind.string ||
      JsonKind.number when _edited(nodeId) => _values[nodeId]! as String,
      JsonKind.string => decodeJsonString(
        _source!,
        start,
        escaped: _n.flags[nodeId] & escapedFlag != 0,
      ),
      JsonKind.number => String.fromCharCodes(
        _source!,
        start,
        jsonNumberEnd(_source, start),
      ),
      JsonKind.boolean => _boolean(nodeId) ? 'true' : 'false',
      JsonKind.nullValue => 'null',
    };
  }

  /// Expands every ancestor of [nodeId] and returns the row that shows it.
  /// Throws an [ArgumentError] for a container root, which has no row.
  int reveal(int nodeId) => _reveal(nodeId);

  /// The document as UTF-8 JSON, compact or indented by two spaces like
  /// `JsonEncoder.withIndent('  ')`. Scalars are copied from the source as
  /// written; member names are re-encoded from their decoded text. Throws a
  /// [StateError] when there is a [parseError].
  ///
  /// Indentation grows with depth, so pretty output of a document nested
  /// more than 512 containers deep would grow with depth squared; such a
  /// document is encoded compactly instead.
  Uint8List encode({bool pretty = false}) {
    if (parseError != null || _source == null) {
      throw StateError('Document has no JSON: $parseError');
    }
    return (pretty ? _encode(true) : null) ?? _encode(false)!;
  }

  /// [encode]; null when [pretty] output would nest too deep.
  Uint8List? _encode(bool pretty) {
    final source = _source!;
    final keys = _encodedKeys ??= [];
    for (var k = keys.length; k < _n.keys.length; k++) {
      keys.add(_quotedUtf8(_n.keys[k]));
    }
    final out = _ByteSink(source.length + 16);
    final open = <int>[]; // containers being written
    final cursor = <int>[]; // next child to write in each of them
    var tooDeep = false;

    void indent(int depth) {
      out.addByte(0x0A);
      for (var i = 0; i < depth; i++) {
        out
          ..addByte(0x20)
          ..addByte(0x20);
      }
    }

    void write(int id) {
      final kind = _n.kind(id);
      final start = _n.valueStart[id];
      switch (kind) {
        case JsonKind.object || JsonKind.array:
          final isObject = kind == JsonKind.object;
          if (pretty && open.length >= _prettyMaxDepth) {
            tooDeep = true;
          } else if (_n.childCount[id] == 0) {
            out.addAscii(isObject ? '{}' : '[]');
          } else {
            out.addByte(isObject ? 0x7B : 0x5B);
            open.add(id);
            cursor.add(_n.firstChild[id]);
          }
        case JsonKind.string when _edited(id):
          final s = _quotedUtf8(_values[id]! as String);
          out.addRange(s, 0, s.length);
        case JsonKind.string:
          out.addRange(source, start, jsonStringEnd(source, start));
        case JsonKind.number when _edited(id):
          out.addAscii(_values[id]! as String);
        case JsonKind.number:
          out.addRange(source, start, jsonNumberEnd(source, start));
        case JsonKind.boolean:
          out.addAscii(_boolean(id) ? 'true' : 'false');
        case JsonKind.nullValue:
          out.addAscii('null');
      }
    }

    write(0);
    while (open.isNotEmpty) {
      final parent = open.last;
      final child = cursor.last;
      final isObject = _n.kind(parent) == JsonKind.object;
      if (child == -1) {
        open.removeLast();
        cursor.removeLast();
        if (pretty) indent(open.length);
        out.addByte(isObject ? 0x7D : 0x5D);
        continue;
      }
      if (child != _n.firstChild[parent]) out.addByte(0x2C);
      if (pretty) indent(open.length);
      if (isObject) {
        final k = keys[_n.keyOrIndex[child]];
        out
          ..addRange(k, 0, k.length)
          ..addByte(0x3A);
        if (pretty) out.addByte(0x20);
      }
      cursor[cursor.length - 1] = _n.nextSibling[child];
      write(child);
      if (tooDeep) return null;
    }
    return out.takeBytes();
  }

  String _preview(int id) {
    final start = _n.valueStart[id];
    switch (_n.kind(id)) {
      case JsonKind.object:
        final n = _n.childCount[id];
        return '{$n ${n == 1 ? 'key' : 'keys'}}';
      case JsonKind.array:
        final n = _n.childCount[id];
        return '[$n ${n == 1 ? 'item' : 'items'}]';
      case JsonKind.string:
        return _quotedPreview(
          _edited(id)
              ? _values[id]! as String
              : decodeJsonString(
                  _source!,
                  start,
                  maxUnits: _previewLimit,
                  escaped: _n.flags[id] & escapedFlag != 0,
                ),
        );
      case JsonKind.number:
        if (_edited(id)) {
          final lexeme = _values[id]! as String;
          return lexeme.length <= _previewLimit
              ? lexeme
              : '${lexeme.substring(0, _previewLimit - 1)}…';
        }
        final source = _source!;
        final end = jsonNumberEnd(source, start);
        if (end - start <= _previewLimit) {
          return String.fromCharCodes(source, start, end);
        }
        final cut = String.fromCharCodes(
          source,
          start,
          start + _previewLimit - 1,
        );
        return '$cut…';
      case JsonKind.boolean:
        return _boolean(id) ? 'true' : 'false';
      case JsonKind.nullValue:
        return 'null';
    }
  }

  /// Throws an [ArgumentError] ([RangeError] when out of range) unless
  /// [nodeId] names a live node.
  void _checkId(int nodeId) {
    RangeError.checkValueInInterval(nodeId, 0, _n.length - 1, 'nodeId');
    if (_n.deleted(nodeId)) {
      throw ArgumentError.value(nodeId, 'nodeId', 'Node was deleted');
    }
  }

  bool _edited(int id) => _n.flags[id] & editedFlag != 0;

  bool _boolean(int id) =>
      _edited(id) ? _values[id]! as bool : _source![_n.valueStart[id]] == 0x74;
}

class _Children {
  _Children(this.ids, this.prefix);

  final Int32List ids;

  /// `prefix[i]` = rows shown by children before `ids[i]` (each child counts
  /// itself plus its visible descendants); length `ids.length + 1`.
  final Int32List prefix;

  /// Position of each child in [ids], built on first [positionOf].
  Map<int, int>? _positions;

  /// The index of child [id] in [ids].
  int positionOf(int id) =>
      (_positions ??= {for (var i = 0; i < ids.length; i++) ids[i]: i})[id]!;
}

/// A growable byte buffer.
class _ByteSink {
  _ByteSink(int capacity) : _buf = Uint8List(capacity);

  Uint8List _buf;
  int _length = 0;

  void _reserve(int n) {
    if (_length + n <= _buf.length) return;
    var size = _buf.length * 2;
    while (size < _length + n) {
      size *= 2;
    }
    _buf = Uint8List(size)..setRange(0, _length, _buf);
  }

  void addByte(int b) {
    _reserve(1);
    _buf[_length++] = b;
  }

  void addRange(Uint8List src, int start, int end) {
    _reserve(end - start);
    _buf.setRange(_length, _length + end - start, src, start);
    _length += end - start;
  }

  void addAscii(String s) {
    _reserve(s.length);
    for (var i = 0; i < s.length; i++) {
      _buf[_length++] = s.codeUnitAt(i);
    }
  }

  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _length);
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

/// [s] as a UTF-8 JSON string literal, escaped like `JsonEncoder`.
Uint8List _quotedUtf8(String s) {
  final out = StringBuffer('"');
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
  return utf8.encode(out.toString());
}

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
