import 'json_row.dart';

/// One member seen in the objects of an array.
class InferredField {
  InferredField({
    required this.key,
    required Set<JsonKind> kinds,
    required this.presentIn,
    required this.total,
  }) : kinds = Set.unmodifiable(kinds);

  final String key;

  /// Kinds of its values, in first-seen order; unmodifiable.
  final Set<JsonKind> kinds;

  /// Objects that have this member.
  final int presentIn;

  /// Objects in the array.
  final int total;

  /// Whether some objects lack this member.
  bool get optional => presentIn < total;
}

/// The shape of the objects in an array; other items are ignored.
class ArraySchema {
  ArraySchema(List<InferredField> fields) : fields = List.unmodifiable(fields);

  /// In first-seen order across the objects; unmodifiable.
  final List<InferredField> fields;

  /// e.g. `{id: number, name: string|null, avatar?: string}`.
  String describe() {
    final parts = [
      for (final f in fields)
        '${f.key}${f.optional ? '?' : ''}: '
            '${[for (final k in f.kinds) _kindName(k)].join('|')}',
    ];
    return '{${parts.join(', ')}}';
  }

  @override
  String toString() => describe();
}

String _kindName(JsonKind kind) =>
    kind == JsonKind.nullValue ? 'null' : kind.name;

/// Accumulates an [ArraySchema] from an array's objects, member by member.
class ArraySchemaBuilder {
  final Map<String, _Field> _fields = {};
  int _objects = 0;

  /// Starts the next object.
  void addObject() => _objects++;

  /// A member of the current object.
  void addMember(String key, JsonKind kind) {
    final f = _fields[key] ??= _Field();
    f.kinds.add(kind);
    f.presentIn++;
  }

  /// Null when no objects were added.
  ArraySchema? build() {
    if (_objects == 0) return null;
    return ArraySchema([
      for (final MapEntry(:key, :value) in _fields.entries)
        InferredField(
          key: key,
          kinds: value.kinds,
          presentIn: value.presentIn,
          total: _objects,
        ),
    ]);
  }
}

class _Field {
  final Set<JsonKind> kinds = {};
  int presentIn = 0;
}
