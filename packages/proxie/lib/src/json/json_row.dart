/// The JSON type of a node.
enum JsonKind {
  /// A `{...}` object.
  object,

  /// A `[...]` array.
  array,

  /// A string.
  string,

  /// A number.
  number,

  /// `true` or `false`.
  boolean,

  /// `null`.
  nullValue,
}

/// One visible line of a JSON tree view.
class JsonRow {
  /// Creates a row for node [nodeId].
  const JsonRow({
    required this.nodeId,
    required this.depth,
    required this.kind,
    required this.preview,
    required this.childCount,
    required this.expanded,
    this.key,
    this.index,
    this.missingKeys = const [],
  });

  /// Stable id of the node within its document.
  final int nodeId;

  /// Indentation level; the root's children are at 0.
  final int depth;

  /// Member name when the parent is an object.
  final String? key;

  /// Position when the parent is an array.
  final int? index;

  /// The JSON kind of the node's value.
  final JsonKind kind;

  /// Single-line summary of the value, at most 120 characters.
  final String preview;

  /// Members or items of an object or array; 0 for scalars.
  final int childCount;

  /// Whether an object or array row is expanded; false for scalars.
  final bool expanded;

  /// Keys that other objects in the same array have and this one lacks, in
  /// the array schema's field order. Empty for rows outside such arrays.
  final List<String> missingKeys;

  @override
  String toString() =>
      'JsonRow($nodeId, depth: $depth, ${key ?? '[$index]'}: $preview)';
}
