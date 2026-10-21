/// RGA-style character-sequence CRDT for collaborative plain text.
///
/// Each character is a node with:
/// - a unique [CharId] `(siteId, counter)` — the counter is per-site,
///   advanced Lamport-style: a site's next counter is greater than every
///   counter it has ever observed (its own or merged). Locally created
///   nodes therefore always outrank the existing siblings of their
///   parent, so an insert lands exactly at the requested local index,
///   while concurrent inserts from different sites still order
///   deterministically by ID;
/// - a `parent` pointer: the node it was inserted after (`null` = head
///   of the document);
/// - a tombstone flag: deletes never remove a node, they mark it, so
///   concurrent inserts anchored to it still converge.
///
/// Ordering rule (deterministic, documented):
/// The sequence is a depth-first walk of the parent tree starting at the
/// root. The children of any node are visited in **descending [CharId]
/// order**, where IDs compare first by `counter`, then by `siteId`
/// (lexicographic). A node's whole subtree is contiguous and immediately
/// follows the node. Tombstoned nodes keep their structural position but
/// contribute no character to [CrdtText.text].
///
/// Consequences:
/// - A locally typed run forms a parent chain, so it always reads in
///   typing order regardless of sibling tie-breaks.
/// - Concurrent inserts after the same parent interleave by ID order —
///   the same on every replica, which is what makes [merge] commutative.
/// - [merge] is idempotent: re-applying any operation is a no-op.
///   Operations whose parent/target is not yet known are buffered and
///   retried whenever new operations land, so delivery order between
///   causally related operations does not matter either.
library;

/// Unique character identifier: `(siteId, counter)`.
class CharId implements Comparable<CharId> {
  const CharId(this.siteId, this.counter);

  final String siteId;
  final int counter;

  /// Orders by counter first, then by siteId (lexicographic).
  @override
  int compareTo(CharId other) {
    final byCounter = counter.compareTo(other.counter);
    return byCounter != 0 ? byCounter : siteId.compareTo(other.siteId);
  }

  @override
  bool operator ==(Object other) =>
      other is CharId && other.siteId == siteId && other.counter == counter;

  @override
  int get hashCode => Object.hash(siteId, counter);

  @override
  String toString() => '$siteId:$counter';
}

/// A CRDT operation. Operations are the only thing replicas exchange.
sealed class CrdtOp {
  const CrdtOp();
}

/// Inserts one character ([rune], a Unicode code point) after [parent],
/// or at the head of the document when [parent] is null.
class InsertOp extends CrdtOp {
  const InsertOp({required this.id, required this.parent, required this.rune});

  final CharId id;
  final CharId? parent;
  final int rune;

  @override
  bool operator ==(Object other) =>
      other is InsertOp &&
      other.id == id &&
      other.parent == parent &&
      other.rune == rune;

  @override
  int get hashCode => Object.hash(id, parent, rune);

  @override
  String toString() => 'Insert($id after $parent, ${String.fromCharCode(rune)})';
}

/// Deletes the character with ID [target] (tombstones it).
class DeleteOp extends CrdtOp {
  const DeleteOp({required this.target});

  final CharId target;

  @override
  bool operator ==(Object other) => other is DeleteOp && other.target == target;

  @override
  int get hashCode => target.hashCode;

  @override
  String toString() => 'Delete($target)';
}

class _Node {
  _Node({required this.id, required this.parent, required this.rune});

  final CharId id;
  final CharId? parent;
  final int rune;
  bool tombstone = false;
}

/// A replica of one CRDT text document, owned by [siteId].
class CrdtText {
  CrdtText(this.siteId);

  /// Builds a replica whose content is [initial], as if [siteId] had
  /// typed it left to right. Deterministic: counters are 1..n in order.
  factory CrdtText.withText(String siteId, String initial) {
    final text = CrdtText(siteId);
    text.insertTextAt(0, initial);
    return text;
  }

  final String siteId;

  int _counter = 0;
  final Map<CharId, _Node> _nodes = <CharId, _Node>{};
  final List<CrdtOp> _opLog = <CrdtOp>[];
  final List<CrdtOp> _pending = <CrdtOp>[];

  /// Every operation ever applied by this replica, in an order that is
  /// valid to replay into a fresh replica (parents precede children).
  List<CrdtOp> get allOps => List<CrdtOp>.unmodifiable(_opLog);

  /// Operations buffered because their parent/target is unknown yet.
  int get pendingCount => _pending.length;

  /// Number of characters ever inserted (including tombstoned).
  int get nodeCount => _nodes.length;

  // --- Local editing -------------------------------------------------------

  /// Inserts a single character (one rune) at visible [index]
  /// (0..length) and returns the operation to broadcast.
  InsertOp insertAt(int index, String char) {
    final runes = char.runes.toList();
    if (runes.length != 1) {
      throw ArgumentError.value(char, 'char', 'insertAt takes exactly one rune');
    }
    return insertRunesAt(index, runes).single;
  }

  /// Inserts [text] at visible [index]; returns one op per rune, in
  /// order. Each rune is anchored to the previous one, so the run reads
  /// in order on every replica.
  List<InsertOp> insertTextAt(int index, String text) =>
      insertRunesAt(index, text.runes.toList());

  List<InsertOp> insertRunesAt(int index, List<int> runes) {
    final visible = _visibleNodes();
    if (index < 0 || index > visible.length) {
      throw RangeError.range(index, 0, visible.length, 'index');
    }
    CharId? parent = index == 0 ? null : visible[index - 1].id;
    final ops = <InsertOp>[];
    for (final rune in runes) {
      final op = InsertOp(
        id: CharId(siteId, ++_counter),
        parent: parent,
        rune: rune,
      );
      _applyInsert(op);
      _opLog.add(op);
      ops.add(op);
      parent = op.id;
    }
    return ops;
  }

  /// Deletes the visible character at [index] and returns the operation
  /// to broadcast.
  DeleteOp deleteAt(int index) {
    final visible = _visibleNodes();
    if (index < 0 || index >= visible.length) {
      throw RangeError.range(index, 0, visible.length - 1, 'index');
    }
    final op = DeleteOp(target: visible[index].id);
    _applyDelete(op);
    _opLog.add(op);
    return op;
  }

  // --- Merge -----------------------------------------------------------------

  /// Merges remote [ops] into this replica. Idempotent and commutative:
  /// applying the same set of operations in any order, any number of
  /// times, converges to the same [text]. Returns the number of
  /// operations that changed this replica (new inserts + new tombstones).
  int merge(Iterable<CrdtOp> ops) {
    final queue = <CrdtOp>[..._pending, ...ops];
    _pending.clear();
    var applied = 0;
    var progressed = true;
    while (progressed) {
      progressed = false;
      queue.removeWhere((op) {
        switch (op) {
          case InsertOp():
            if (_nodes.containsKey(op.id)) {
              return true; // duplicate: consumed, no change
            }
            if (op.parent != null && !_nodes.containsKey(op.parent)) {
              return false; // parent not here yet: stay queued
            }
            _applyInsert(op);
            _opLog.add(op);
            applied++;
            progressed = true;
            return true;
          case DeleteOp():
            final node = _nodes[op.target];
            if (node == null) {
              return false; // target not here yet: stay queued
            }
            if (!node.tombstone) {
              node.tombstone = true;
              _opLog.add(op);
              applied++;
            }
            progressed = true;
            return true;
        }
      });
    }
    _pending.addAll(queue);
    return applied;
  }

  void _applyInsert(InsertOp op) {
    _nodes[op.id] = _Node(id: op.id, parent: op.parent, rune: op.rune);
    // Lamport advance: never reuse a counter at or below one already seen.
    if (op.id.counter > _counter) _counter = op.id.counter;
  }

  void _applyDelete(DeleteOp op) {
    _nodes[op.target]?.tombstone = true;
  }

  // --- Reading -----------------------------------------------------------------

  /// All nodes in CRDT sequence order (see the ordering rule above),
  /// including tombstones.
  List<_Node> _orderedNodes() {
    final children = <CharId?, List<_Node>>{};
    for (final node in _nodes.values) {
      (children[node.parent] ??= <_Node>[]).add(node);
    }
    for (final siblings in children.values) {
      // Descending CharId order: higher counter first, then higher siteId.
      siblings.sort((a, b) => b.id.compareTo(a.id));
    }
    final out = <_Node>[];
    void visit(CharId? parent) {
      for (final node in children[parent] ?? const <_Node>[]) {
        out.add(node);
        visit(node.id);
      }
    }

    visit(null);
    return out;
  }

  List<_Node> _visibleNodes() =>
      _orderedNodes().where((n) => !n.tombstone).toList();

  /// The current visible text.
  String get text =>
      String.fromCharCodes(_visibleNodes().map((n) => n.rune));

  /// Number of visible characters (runes).
  int get length => _visibleNodes().length;
}
