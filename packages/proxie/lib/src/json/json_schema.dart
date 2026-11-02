import 'package:proxie/src/json/json_row.dart';

/// One member seen in the objects of an array.
class InferredField {
  /// Creates a field seen in [presentIn] of [total] objects.
  InferredField({
    required this.key,
    required Set<JsonKind> kinds,
    required this.presentIn,
    required this.total,
  }) : kinds = Set.unmodifiable(kinds);

  /// The member name.
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
  /// Creates a schema with [fields], copied into an unmodifiable list.
  ArraySchema(List<InferredField> fields) : fields = List.unmodifiable(fields);

  /// In first-seen order across the objects; unmodifiable.
  final List<InferredField> fields;

  /// e.g. `{id: number, name: string|null, avatar?: string}`.
  String describe() {
    final parts = [
      for (final f in fields)
        '${f.key}${f.optional ? '?' : ''}: ${f.kinds.map(_kindName).join('|')}',
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
  /// `keyNames` maps the key ids given to [addMember] to member names.
  ArraySchemaBuilder(this._keyNames);

  final List<String> _keyNames;
  final Map<int, _Field> _fields = {};
  int _objects = 0;

  /// Starts the next object.
  void addObject() => _objects++;

  /// A member of the current object. A name repeated within one object
  /// counts once towards [InferredField.presentIn].
  void addMember(int keyId, JsonKind kind) {
    final f = _fields[keyId] ??= _Field();
    f.kinds.add(kind);
    if (f.lastObject != _objects) {
      f.lastObject = _objects;
      f.presentIn++;
    }
  }

  /// Null when no objects were added.
  ArraySchema? build() {
    if (_objects == 0) return null;
    return ArraySchema([
      for (final MapEntry(:key, :value) in _fields.entries)
        InferredField(
          key: _keyNames[key],
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

  /// The object (1-based count) that last contributed to [presentIn].
  int lastObject = 0;
}
