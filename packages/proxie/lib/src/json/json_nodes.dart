import 'dart:typed_data';

import 'json_row.dart';

/// Approximate storage per node: seven 32-bit fields and one flags byte.
const int jsonBytesPerNode = 7 * 4 + 1;

/// [JsonNodes.flags]: low three bits hold the [JsonKind] index.
const int kindMask = 0x07;

/// [JsonNodes.flags]: a string value whose source contains escapes.
const int escapedFlag = 0x08;

/// [JsonNodes.flags]: an expanded container.
const int expandedFlag = 0x10;

/// [JsonNodes.flags]: a node removed by an edit. It stays allocated but is
/// unlinked from its parent and must not be used.
const int deletedFlag = 0x20;

/// [JsonNodes.flags]: a scalar set by an edit; its value is held outside
/// the source bytes and [JsonNodes.valueStart] is meaningless.
const int editedFlag = 0x40;

/// Typed parallel arrays describing every node of a JSON document; -1
/// means "none". Children are linked through [firstChild] / [nextSibling]
/// and every node's id is larger than its parent's.
class JsonNodes {
  JsonNodes([int capacity = 16]) {
    _allocate(capacity < 1 ? 1 : capacity);
  }

  int length = 0;

  late Int32List parent;
  late Int32List firstChild;
  late Int32List nextSibling;
  late Int32List childCount;

  /// Rows the subtree shows below the node while it is expanded, kept
  /// current whether or not it is expanded.
  late Int32List inner;

  /// Index into [keys] for object members; array index for array items;
  /// -1 for the root.
  late Int32List keyOrIndex;

  /// Byte offset of a scalar's source text (a string's opening quote).
  late Int32List valueStart;

  late Uint8List flags;

  /// Distinct member names, interned while parsing.
  final List<String> keys = [];

  int get capacity => parent.length;

  JsonKind kind(int id) => JsonKind.values[flags[id] & kindMask];

  bool isContainer(int id) => (flags[id] & kindMask) <= JsonKind.array.index;

  bool expanded(int id) => flags[id] & expandedFlag != 0;

  bool deleted(int id) => flags[id] & deletedFlag != 0;

  void setExpanded(int id, bool value) =>
      flags[id] = value ? flags[id] | expandedFlag : flags[id] & ~expandedFlag;

  /// Appends an unlinked node and returns its id.
  int add(int parentId, int flagBits, int keyOrIndexValue, int start) {
    if (length == capacity) _grow(capacity + (capacity >> 1) + 16);
    final id = length++;
    parent[id] = parentId;
    firstChild[id] = -1;
    nextSibling[id] = -1;
    childCount[id] = 0;
    inner[id] = 0;
    keyOrIndex[id] = keyOrIndexValue;
    valueStart[id] = start;
    flags[id] = flagBits;
    return id;
  }

  /// Releases unused capacity.
  void trim() {
    if (capacity != length) _grow(length < 1 ? 1 : length);
  }

  void _allocate(int n) {
    parent = Int32List(n);
    firstChild = Int32List(n);
    nextSibling = Int32List(n);
    childCount = Int32List(n);
    inner = Int32List(n);
    keyOrIndex = Int32List(n);
    valueStart = Int32List(n);
    flags = Uint8List(n);
  }

  void _grow(int n) {
    Int32List copy32(Int32List old) => Int32List(n)..setRange(0, length, old);
    parent = copy32(parent);
    firstChild = copy32(firstChild);
    nextSibling = copy32(nextSibling);
    childCount = copy32(childCount);
    inner = copy32(inner);
    keyOrIndex = copy32(keyOrIndex);
    valueStart = copy32(valueStart);
    flags = Uint8List(n)..setRange(0, length, flags);
  }
}
