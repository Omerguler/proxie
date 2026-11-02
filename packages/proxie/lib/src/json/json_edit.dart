part of 'json_document.dart';

/// A structural change to a [JsonDocument], applied with
/// [JsonDocument.apply]. Edits are plain data, so they can be sent to the
/// worker isolate.
///
/// Values are JSON data: `null`, [bool], [String] (a JSON string), [num] or
/// [JsonNumber] (a JSON number), [List] and [Map] with [String] keys, nested
/// in any depth. `{}` and `[]` make empty containers.
///
/// An edit that does not apply (wrong kind of node, unknown or deleted node,
/// a value that is not JSON data) throws an [ArgumentError] and changes
/// nothing.
sealed class JsonEdit {
  const JsonEdit();
}

/// Replaces the value of [nodeId], which may change its kind; the root can
/// be replaced too. A container keeps its expansion state when it stays a
/// container, and its new children start collapsed.
class SetValue extends JsonEdit {
  const SetValue(this.nodeId, this.value);

  final int nodeId;
  final Object? value;
}

/// Renames the object member [nodeId]. Throws an [ArgumentError] when a
/// sibling already has [newKey].
class RenameKey extends JsonEdit {
  const RenameKey(this.nodeId, this.newKey);

  final int nodeId;
  final String newKey;
}

/// Removes [nodeId] and its subtree; anything but the root. Later items of
/// an array move up by one index.
class DeleteNode extends JsonEdit {
  const DeleteNode(this.nodeId);

  final int nodeId;
}

/// Appends member [key] to object [objectNodeId]. Throws an [ArgumentError]
/// when the object already has it.
class AddKey extends JsonEdit {
  const AddKey(this.objectNodeId, this.key, this.value);

  final int objectNodeId;
  final String key;
  final Object? value;
}

/// Inserts an item into array [arrayNodeId] at index [at] (0 to its length),
/// or appends it when [at] is null.
class AddItem extends JsonEdit {
  const AddItem(this.arrayNodeId, this.value, {this.at});

  final int arrayNodeId;
  final Object? value;
  final int? at;
}

/// Inserts a copy of array item [itemNodeId] right after it.
class DuplicateItem extends JsonEdit {
  const DuplicateItem(this.itemNodeId);

  final int itemNodeId;
}

/// Appends member [key], which other objects in the same array have, to
/// the object item [itemNodeId]. The value copies the first such sibling's
/// value when it is a scalar; a container becomes an empty one of its kind.
class AddMissingKey extends JsonEdit {
  const AddMissingKey(this.itemNodeId, this.key);

  final int itemNodeId;
  final String key;
}

/// Appends member [key] with [value] to every object item of array
/// [arrayNodeId] that lacks it; other items are left alone.
class AddKeyToAll extends JsonEdit {
  const AddKeyToAll(this.arrayNodeId, this.key, this.value);

  final int arrayNodeId;
  final String key;
  final Object? value;
}

/// Removes every member named [key] from the object items of array
/// [arrayNodeId].
class RemoveKeyFromAll extends JsonEdit {
  const RemoveKeyFromAll(this.arrayNodeId, this.key);

  final int arrayNodeId;
  final String key;
}

/// Appends an object with every field of the array's schema, each holding
/// the default for its first-seen kind: `""`, `0`, `false`, `null`, `{}` or
/// `[]`. Throws an [ArgumentError] when the array holds no objects.
class NewItemFromSchema extends JsonEdit {
  const NewItemFromSchema(this.arrayNodeId);

  final int arrayNodeId;
}

/// A JSON number given by its text, e.g. `JsonNumber('12345678901234567890')`
/// for a value a Dart [num] cannot hold exactly. Must match the RFC 8259
/// number grammar.
class JsonNumber {
  const JsonNumber(this.lexeme);

  final String lexeme;

  @override
  bool operator ==(Object other) =>
      other is JsonNumber && other.lexeme == lexeme;

  @override
  int get hashCode => lexeme.hashCode;

  @override
  String toString() => lexeme;
}

final _numberGrammar = RegExp(
  r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$',
);

/// The JSON text of a number value, or throws an [ArgumentError].
String _numberLexeme(Object value) {
  final String lexeme;
  if (value is JsonNumber) {
    lexeme = value.lexeme;
  } else if (value is int) {
    lexeme = value.toString();
  } else if (value is double && value.isFinite) {
    lexeme = value.toString();
  } else {
    throw ArgumentError.value(value, 'value', 'Not a finite JSON number');
  }
  if (!_numberGrammar.hasMatch(lexeme)) {
    throw ArgumentError.value(lexeme, 'value', 'Not a JSON number');
  }
  return lexeme;
}

/// Throws an [ArgumentError] unless [value] is JSON data (see [JsonEdit]).
/// Iterative, so any nesting depth is fine; cycles are rejected. Returns the
/// number of nodes [value] takes.
int _checkValue(Object? value) {
  final open = HashSet<Object>.identity();
  final stack = <Iterator<Object?>>[];
  final owners = <Object>[];
  var nodes = 0;

  void visit(Object? v) {
    nodes++;
    switch (v) {
      case null || bool() || String():
        return;
      case num() || JsonNumber():
        _numberLexeme(v);
      case Map():
        if (!open.add(v)) throw ArgumentError('Value contains a cycle');
        for (final k in v.keys) {
          if (k is! String) {
            throw ArgumentError.value(
              k,
              'value',
              'Member names must be strings',
            );
          }
        }
        owners.add(v);
        stack.add(v.values.iterator);
      case List():
        if (!open.add(v)) throw ArgumentError('Value contains a cycle');
        owners.add(v);
        stack.add(v.iterator);
      default:
        throw ArgumentError.value(v, 'value', 'Not JSON data');
    }
  }

  visit(value);
  while (stack.isNotEmpty) {
    final it = stack.last;
    if (it.moveNext()) {
      visit(it.current);
    } else {
      stack.removeLast();
      open.remove(owners.removeLast());
    }
  }
  return nodes;
}

/// The value [JsonEdit]s use for a missing field of [kind].
Object? _defaultValue(JsonKind kind) => switch (kind) {
  JsonKind.object => const <String, Object?>{},
  JsonKind.array => const <Object?>[],
  JsonKind.string => '',
  JsonKind.number => 0,
  JsonKind.boolean => false,
  JsonKind.nullValue => null,
};

/// The edit operations; see [JsonDocument.apply].
extension _Editing on JsonDocument {
  void _apply(JsonEdit edit) {
    switch (edit) {
      case SetValue(:final nodeId, :final value):
        _setValue(nodeId, value);
      case RenameKey(:final nodeId, :final newKey):
        _rename(nodeId, newKey);
      case DeleteNode(:final nodeId):
        _checkId(nodeId);
        if (nodeId == 0) {
          throw ArgumentError.value(nodeId, 'nodeId', 'The root stays');
        }
        final parent = _n.parent[nodeId];
        _remove(nodeId);
        _schemaChanged(parent);
      case AddKey(:final objectNodeId, :final key, :final value):
        _checkKind(objectNodeId, JsonKind.object);
        final keyId = _keyIdOf(key);
        if (keyId != null && _member(objectNodeId, keyId) != -1) {
          throw ArgumentError.value(key, 'key', 'Object already has it');
        }
        _reserve(_checkValue(value));
        _insert(objectNodeId, _create(objectNodeId, _internKey(key), value));
        _schemaChanged(objectNodeId);
      case AddItem(:final arrayNodeId, :final value, :final at):
        _checkKind(arrayNodeId, JsonKind.array);
        if (at != null) {
          RangeError.checkValueInInterval(
            at,
            0,
            _n.childCount[arrayNodeId],
            'at',
          );
        }
        _reserve(_checkValue(value));
        _insert(
          arrayNodeId,
          _create(arrayNodeId, 0, value),
          before: at == null ? -1 : _childAt(arrayNodeId, at),
        );
        _schemaChanged(arrayNodeId);
      case DuplicateItem(:final itemNodeId):
        final array = _itemParent(itemNodeId);
        _reserve(_subtreeSize(itemNodeId));
        _insert(
          array,
          _copy(itemNodeId, array),
          before: _n.nextSibling[itemNodeId],
        );
        _schemaChanged(array);
      case AddMissingKey(:final itemNodeId, :final key):
        _addMissingKey(itemNodeId, key);
      case AddKeyToAll(:final arrayNodeId, :final key, :final value):
        _checkKind(arrayNodeId, JsonKind.array);
        final size = _checkValue(value);
        var keyId = _keyIdOf(key);
        bool lacks(int item) =>
            _n.kind(item) == JsonKind.object &&
            (keyId == null || _member(item, keyId) == -1);
        var targets = 0;
        for (var item = _n.firstChild[arrayNodeId]; item != -1;) {
          if (lacks(item)) targets++;
          item = _n.nextSibling[item];
        }
        _reserve(size * targets);
        for (var item = _n.firstChild[arrayNodeId]; item != -1;) {
          if (lacks(item)) {
            final id = keyId ??= _internKey(key);
            _insert(item, _create(item, id, value));
          }
          item = _n.nextSibling[item];
        }
        _invalidateSchema(arrayNodeId);
      case RemoveKeyFromAll(:final arrayNodeId, :final key):
        _checkKind(arrayNodeId, JsonKind.array);
        final keyId = _keyIdOf(key);
        if (keyId == null) return;
        for (var item = _n.firstChild[arrayNodeId]; item != -1;) {
          if (_n.kind(item) == JsonKind.object) {
            for (var m = _n.firstChild[item]; m != -1;) {
              final next = _n.nextSibling[m];
              if (_n.keyOrIndex[m] == keyId) _remove(m);
              m = next;
            }
          }
          item = _n.nextSibling[item];
        }
        _invalidateSchema(arrayNodeId);
      case NewItemFromSchema(:final arrayNodeId):
        _checkKind(arrayNodeId, JsonKind.array);
        final schema = schemaOf(arrayNodeId);
        if (schema == null) {
          throw ArgumentError.value(
            arrayNodeId,
            'arrayNodeId',
            'Array holds no objects',
          );
        }
        final item = {
          for (final f in schema.fields) f.key: _defaultValue(f.kinds.first),
        };
        _reserve(1 + item.length);
        _insert(arrayNodeId, _create(arrayNodeId, 0, item));
        _invalidateSchema(arrayNodeId);
    }
  }

  void _setValue(int nodeId, Object? value) {
    _checkId(nodeId);
    _reserve(_checkValue(value) - 1);
    final before = _below(nodeId);
    for (var c = _n.firstChild[nodeId]; c != -1; c = _n.nextSibling[c]) {
      _drop(c);
    }
    _n.firstChild[nodeId] = -1;
    _n.childCount[nodeId] = 0;
    _n.inner[nodeId] = 0;
    _children.remove(nodeId);
    _invalidateSchema(nodeId);
    _fill(nodeId, value);
    final parent = _n.parent[nodeId];
    if (parent != -1) _resized(parent, _below(nodeId) - before);
    _schemaChanged(parent);
    _dirty = true;
  }

  void _rename(int nodeId, String newKey) {
    _checkId(nodeId);
    final parent = _n.parent[nodeId];
    if (parent == -1 || _n.kind(parent) != JsonKind.object) {
      throw ArgumentError.value(nodeId, 'nodeId', 'Not an object member');
    }
    final keyId = _keyIdOf(newKey);
    if (keyId == _n.keyOrIndex[nodeId]) return;
    if (keyId != null && _member(parent, keyId) != -1) {
      throw ArgumentError.value(newKey, 'newKey', 'A sibling already has it');
    }
    _n.keyOrIndex[nodeId] = _internKey(newKey);
    _schemaChanged(parent);
    _dirty = true;
  }

  void _addMissingKey(int itemNodeId, String key) {
    final array = _itemParent(itemNodeId);
    _checkKind(itemNodeId, JsonKind.object);
    final keyId = _keyIdOf(key);
    if (keyId != null && _member(itemNodeId, keyId) != -1) {
      throw ArgumentError.value(key, 'key', 'Object already has it');
    }
    var source = -1;
    for (var item = _n.firstChild[array]; keyId != null && item != -1;) {
      if (_n.kind(item) == JsonKind.object) {
        source = _member(item, keyId);
        if (source != -1) break;
      }
      item = _n.nextSibling[item];
    }
    if (source == -1) {
      throw ArgumentError.value(key, 'key', 'No other item has it');
    }
    _reserve(1);
    final int id;
    if (_n.isContainer(source)) {
      id = _create(itemNodeId, keyId!, _defaultValue(_n.kind(source)));
    } else {
      id = _copy(source, itemNodeId);
    }
    _insert(itemNodeId, id);
    _schemaChanged(itemNodeId);
  }

  void _checkKind(int nodeId, JsonKind kind) {
    _checkId(nodeId);
    if (_n.kind(nodeId) != kind) {
      throw ArgumentError.value(nodeId, 'nodeId', 'Not an ${kind.name}');
    }
  }

  /// The array holding item [nodeId]; throws when it is not an array item.
  int _itemParent(int nodeId) {
    _checkId(nodeId);
    final parent = _n.parent[nodeId];
    if (parent == -1 || _n.kind(parent) != JsonKind.array) {
      throw ArgumentError.value(nodeId, 'nodeId', 'Not an array item');
    }
    return parent;
  }

  /// First member of [object] named by [keyId], or -1.
  int _member(int object, int keyId) {
    for (var m = _n.firstChild[object]; m != -1; m = _n.nextSibling[m]) {
      if (_n.keyOrIndex[m] == keyId) return m;
    }
    return -1;
  }

  /// Child [index] of [container], or -1 when it has [index] children.
  int _childAt(int container, int index) {
    var c = _n.firstChild[container];
    for (var i = 0; i < index; i++) {
      c = _n.nextSibling[c];
    }
    return c;
  }

  Map<String, int> get _keyIndex =>
      _keyIds ??= {for (var i = 0; i < _n.keys.length; i++) _n.keys[i]: i};

  int? _keyIdOf(String key) => _keyIndex[key];

  int _internKey(String key) => _keyIndex.putIfAbsent(key, () {
    _n.keys.add(key);
    return _n.keys.length - 1;
  });

  /// Rows [id] shows below itself; the root always shows its children.
  int _below(int id) => id == 0 || _n.expanded(id) ? _n.inner[id] : 0;

  /// [container]'s children changed, adding [delta] rows below it: updates
  /// the counts and prefix caches of it and its open ancestors.
  void _resized(int container, int delta) {
    _children.remove(container);
    if (delta == 0) return;
    var a = container;
    while (a != -1) {
      _n.inner[a] += delta;
      _children.remove(a);
      if (a == 0 || !_n.expanded(a)) break;
      a = _n.parent[a];
    }
  }

  /// Drops the schemas that depend on the children of [container]: its
  /// own, or its parent array's when it is an object item.
  void _schemaChanged(int container) {
    if (container == -1) return;
    if (_n.kind(container) == JsonKind.array) {
      _invalidateSchema(container);
    } else {
      final parent = _n.parent[container];
      if (parent != -1 && _n.kind(parent) == JsonKind.array) {
        _invalidateSchema(parent);
      }
    }
  }

  /// Links the unlinked node [id] into [parent] before child [before], or
  /// last when it is -1.
  void _insert(int parent, int id, {int before = -1}) {
    var prev = -1;
    final hint = _lastChild[parent];
    if (before == -1 &&
        hint != null &&
        !_n.deleted(hint) &&
        _n.parent[hint] == parent &&
        _n.nextSibling[hint] == -1) {
      prev = hint; // an append: no walk
    } else {
      for (var c = _n.firstChild[parent]; c != before; c = _n.nextSibling[c]) {
        prev = c;
      }
    }
    if (before == -1) _lastChild[parent] = id;
    _n.nextSibling[id] = before;
    if (prev == -1) {
      _n.firstChild[parent] = id;
    } else {
      _n.nextSibling[prev] = id;
    }
    _n.childCount[parent]++;
    if (_n.kind(parent) == JsonKind.array) {
      _renumber(id, prev == -1 ? 0 : _n.keyOrIndex[prev] + 1);
    }
    _resized(parent, 1 + _below(id));
    _dirty = true;
  }

  /// Unlinks [id] from its parent and deletes its subtree.
  void _remove(int id) {
    final parent = _n.parent[id];
    var prev = -1;
    for (var c = _n.firstChild[parent]; c != id; c = _n.nextSibling[c]) {
      prev = c;
    }
    final next = _n.nextSibling[id];
    if (prev == -1) {
      _n.firstChild[parent] = next;
    } else {
      _n.nextSibling[prev] = next;
    }
    _n.childCount[parent]--;
    if (_n.kind(parent) == JsonKind.array) _renumber(next, _n.keyOrIndex[id]);
    _resized(parent, -1 - _below(id));
    _drop(id);
    _dirty = true;
  }

  /// Throws a [StateError] when appending [added] nodes would grow storage
  /// beyond [JsonDocument.maxCapacity]. Mirrors the growth of
  /// [JsonNodes.add].
  void _reserve(int added) {
    final limit = maxCapacity;
    if (limit == null) return;
    final need = _n.length + added;
    var capacity = _n.capacity;
    while (capacity < need) {
      capacity += (capacity >> 1) + 16;
    }
    if (capacity != _n.capacity && capacity > limit) {
      throw StateError('Document too large to edit further');
    }
  }

  /// Nodes in the subtree of [root], itself included.
  int _subtreeSize(int root) {
    var size = 0;
    var id = root;
    while (true) {
      size++;
      if (_n.firstChild[id] != -1) {
        id = _n.firstChild[id];
        continue;
      }
      while (id != root && _n.nextSibling[id] == -1) {
        id = _n.parent[id];
      }
      if (id == root) return size;
      id = _n.nextSibling[id];
    }
  }

  /// Array items from [id] on get indices from [index] up.
  void _renumber(int id, int index) {
    for (var c = id; c != -1; c = _n.nextSibling[c]) {
      _n.keyOrIndex[c] = index++;
    }
  }

  /// Marks the (already unlinked) subtree of [root] deleted.
  void _drop(int root) {
    var id = root;
    while (true) {
      _n.flags[id] |= deletedFlag;
      _values.remove(id);
      _children.remove(id);
      _invalidateSchema(id);
      _lastChild.remove(id);
      _deleted++;
      if (_n.firstChild[id] != -1) {
        id = _n.firstChild[id];
        continue;
      }
      while (id != root && _n.nextSibling[id] == -1) {
        id = _n.parent[id];
      }
      if (id == root) return;
      id = _n.nextSibling[id];
    }
  }

  /// A new unlinked node under [parent] holding the checked [value].
  int _create(int parent, int keyOrIndex, Object? value) {
    final id = _n.add(parent, JsonKind.nullValue.index, keyOrIndex, -1);
    _fill(id, value);
    return id;
  }

  /// Gives the childless node [id] the checked [value], building any
  /// subtree without recursion. New containers start collapsed; [id]
  /// keeps its expansion state while it stays a container.
  void _fill(int id, Object? value) {
    final open = <int>[]; // containers being filled
    final items = <Iterator<Object?>>[]; // their items or member entries
    final last = <int>[]; // the last child linked into each

    void set(int node, Object? v) {
      final expanded = _n.flags[node] & expandedFlag;
      _values.remove(node);
      switch (v) {
        case Map():
          _n.flags[node] = JsonKind.object.index | expanded;
          if (v.isNotEmpty) {
            open.add(node);
            items.add(v.entries.iterator);
            last.add(-1);
          }
        case List():
          _n.flags[node] = JsonKind.array.index | expanded;
          if (v.isNotEmpty) {
            open.add(node);
            items.add(v.iterator);
            last.add(-1);
          }
        case String():
          _n.flags[node] = JsonKind.string.index | editedFlag;
          _values[node] = v;
        case bool():
          _n.flags[node] = JsonKind.boolean.index | editedFlag;
          _values[node] = v;
        case null:
          _n.flags[node] = JsonKind.nullValue.index;
        default:
          _n.flags[node] = JsonKind.number.index | editedFlag;
          _values[node] = _numberLexeme(v);
      }
    }

    set(id, value);
    while (open.isNotEmpty) {
      final top = open.length - 1;
      if (!items[top].moveNext()) {
        open.removeLast();
        items.removeLast();
        last.removeLast();
        continue;
      }
      final parent = open[top];
      final item = items[top].current;
      final int key;
      final Object? v;
      if (_n.kind(parent) == JsonKind.object) {
        final entry = item! as MapEntry<Object?, Object?>;
        key = _internKey(entry.key! as String);
        v = entry.value;
      } else {
        key = _n.childCount[parent];
        v = item;
      }
      final child = _n.add(parent, JsonKind.nullValue.index, key, -1);
      if (last[top] == -1) {
        _n.firstChild[parent] = child;
      } else {
        _n.nextSibling[last[top]] = child;
      }
      last[top] = child;
      _n.childCount[parent]++;
      _n.inner[parent]++;
      set(child, v);
    }
  }

  /// A collapsed, unlinked copy of the subtree of [source] under [parent].
  int _copy(int source, int parent) {
    int clone(int s, int p) {
      final id = _n.add(
        p,
        _n.flags[s] & (kindMask | escapedFlag | editedFlag),
        _n.keyOrIndex[s],
        _n.valueStart[s],
      );
      final v = _values[s];
      if (v != null) _values[id] = v;
      return id;
    }

    final root = clone(source, parent);
    final next = <int>[_n.firstChild[source]]; // next source child to copy
    final copies = <int>[root];
    final last = <int>[-1];
    while (copies.isNotEmpty) {
      final top = copies.length - 1;
      final s = next[top];
      if (s == -1) {
        next.removeLast();
        copies.removeLast();
        last.removeLast();
        continue;
      }
      next[top] = _n.nextSibling[s];
      final p = copies[top];
      final id = clone(s, p);
      if (last[top] == -1) {
        _n.firstChild[p] = id;
      } else {
        _n.nextSibling[last[top]] = id;
      }
      last[top] = id;
      _n.childCount[p]++;
      _n.inner[p]++;
      if (_n.firstChild[s] != -1) {
        next.add(_n.firstChild[s]);
        copies.add(id);
        last.add(-1);
      }
    }
    return root;
  }
}
