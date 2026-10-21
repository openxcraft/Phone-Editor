import 'a1.dart';
import 'evaluator.dart';
import 'formula.dart';
import 'model.dart';

/// Owns a [Sheet] plus its computed values, dependency graph, and
/// recalculation scheduler.
///
/// Mutations should go through [setCell] (or mutate [sheet] directly and
/// then call [recalculateAll]); computed values are then always current.
/// On each edit only the edited cell and its transitive dependents are
/// recalculated, in topological (dependencies-first) order.
///
/// Cycle handling: cells in a dependency cycle evaluate to `#CYCLE!`.
/// Cells that merely depend on a cycle receive that error through normal
/// error propagation.
class SheetEngine implements ValueProvider {
  SheetEngine(this.sheet, {DateTime Function()? today}) : _today = today {
    _evaluator = Evaluator(values: this, today: _today);
    _rebuildGraph();
    _recalculate(sheet.entries.map((e) => e.key).toSet());
  }

  final Sheet sheet;
  final DateTime Function()? _today;
  late final Evaluator _evaluator;

  final Map<CellRef, CellValue> _values = <CellRef, CellValue>{};

  /// Formula cell → the cells it reads.
  final Map<CellRef, Set<CellRef>> _deps = <CellRef, Set<CellRef>>{};

  /// Any cell → the formula cells that read it.
  final Map<CellRef, Set<CellRef>> _dependents = <CellRef, Set<CellRef>>{};

  final Map<String, AstNode> _astCache = <String, AstNode>{};
  final Map<String, String> _parseErrorCache = <String, String>{};

  /// The current computed value of [ref]; [EmptyValue] for unset cells.
  @override
  CellValue valueAt(CellRef ref) => _values[ref] ?? const EmptyValue();

  /// Computes-or-returns the value, for API consumers used to `getValue`.
  CellValue computedValue(CellRef ref) => valueAt(ref);

  /// Sets a cell and recalculates exactly the affected subgraph: the cell
  /// plus its transitive dependents.
  void setCell(CellRef ref, Cell cell) {
    sheet.setCell(ref, cell);
    _updateGraphFor(ref);
    final dirty = <CellRef>{ref};
    final stack = <CellRef>[ref];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      for (final dependent in _dependents[current] ?? const <CellRef>{}) {
        if (dirty.add(dependent)) stack.add(dependent);
      }
    }
    _recalculate(dirty);
  }

  /// Full recalculation (also the recovery path after direct sheet edits).
  void recalculateAll() {
    _rebuildGraph();
    _values.clear();
    final all = sheet.entries.map((e) => e.key).toSet();
    // Start from every stored cell; formula deps on empty cells resolve
    // through valueAt's EmptyValue default.
    _recalculate(all);
  }

  // --- Graph maintenance -----------------------------------------------------

  void _rebuildGraph() {
    _deps.clear();
    _dependents.clear();
    for (final entry in sheet.entries) {
      _registerDeps(entry.key, entry.value);
    }
  }

  void _updateGraphFor(CellRef ref) {
    final old = _deps.remove(ref);
    if (old != null) {
      for (final dep in old) {
        _dependents[dep]?.remove(ref);
      }
    }
    final cell = sheet.cellAt(ref);
    if (cell != null) _registerDeps(ref, cell);
  }

  void _registerDeps(CellRef ref, Cell cell) {
    if (cell.kind != CellKind.formula) return;
    final source = cell.formulaSource!;
    final ast = _parseCached(source);
    if (ast == null) {
      _deps[ref] = <CellRef>{};
      return;
    }
    final deps = astDependencies(ast).toSet();
    _deps[ref] = deps;
    for (final dep in deps) {
      (_dependents[dep] ??= <CellRef>{}).add(ref);
    }
  }

  AstNode? _parseCached(String source) {
    final cached = _astCache[source];
    if (cached != null) return cached;
    if (_parseErrorCache.containsKey(source)) return null;
    try {
      final ast = parseFormula(source);
      _astCache[source] = ast;
      return ast;
    } on FormulaSyntaxException catch (e) {
      _parseErrorCache[source] = e.errorCode;
      return null;
    }
  }

  String? _parseErrorFor(String source) {
    _parseCached(source);
    return _parseErrorCache[source];
  }

  // --- Recalculation -----------------------------------------------------------

  static List<CellRef> _sorted(Set<CellRef> refs) {
    final list = refs.toList();
    list.sort((a, b) {
      final byRow = a.row.compareTo(b.row);
      return byRow != 0 ? byRow : a.col.compareTo(b.col);
    });
    return list;
  }

  void _recalculate(Set<CellRef> dirtySet) {
    if (dirtySet.isEmpty) return;
    final dirty = _sorted(dirtySet).toSet();

    // Cells deleted from the sheet lose their computed value immediately;
    // their dependents (also dirty) will see EmptyValue.
    for (final ref in dirty) {
      if (sheet.cellAt(ref) == null) _values.remove(ref);
    }

    final order = _topologicalOrder(dirty);
    for (final ref in order) {
      _values[ref] = _computeCell(ref);
    }
  }

  /// Deterministic topological order over the subgraph induced by
  /// [dirty]. Cycle members resolve first with `#CYCLE!` so dependents
  /// evaluate (to the propagated error) instead of hanging.
  List<CellRef> _topologicalOrder(Set<CellRef> dirty) {
    final resolved = <CellRef>{};
    final order = <CellRef>[];

    void kahn(Set<CellRef> nodes) {
      final indegree = <CellRef, int>{};
      for (final ref in nodes) {
        var count = 0;
        for (final dep in _deps[ref] ?? const <CellRef>{}) {
          if (nodes.contains(dep) && !resolved.contains(dep)) count++;
        }
        indegree[ref] = count;
      }
      final ready = _sorted(nodes.where((r) => indegree[r] == 0).toSet());
      while (ready.isNotEmpty) {
        final ref = ready.removeAt(0);
        if (!resolved.add(ref)) continue;
        order.add(ref);
        final dependents =
            _sorted((_dependents[ref] ?? const <CellRef>{})
                .where((d) => nodes.contains(d) && !resolved.contains(d))
                .toSet());
        for (final dependent in dependents) {
          final next = (indegree[dependent] ?? 1) - 1;
          indegree[dependent] = next;
          if (next == 0) {
            // Insert keeping (row, col) order for determinism.
            var at = ready.indexWhere((r) =>
                r.row > dependent.row ||
                (r.row == dependent.row && r.col > dependent.col));
            if (at < 0) at = ready.length;
            ready.insert(at, dependent);
          }
        }
      }
    }

    kahn(dirty);
    final remaining = dirty.difference(resolved);
    if (remaining.isNotEmpty) {
      // Remaining nodes are cycle members plus their downstream. Peel
      // iteratively from the dependent-free leaves: what cannot be
      // peeled is exactly the set of cycle members.
      final cycleMembers = Set<CellRef>.of(remaining);
      var changed = true;
      while (changed) {
        changed = false;
        for (final ref in _sorted(cycleMembers)) {
          final hasDependentInSet = (_dependents[ref] ?? const <CellRef>{})
              .any((d) => d != ref && cycleMembers.contains(d));
          final selfLoop = (_deps[ref] ?? const <CellRef>{}).contains(ref);
          if (!hasDependentInSet && !selfLoop) {
            cycleMembers.remove(ref);
            changed = true;
          }
        }
      }
      for (final ref in _sorted(cycleMembers)) {
        resolved.add(ref);
        order.add(ref);
        _values[ref] = const ErrorValue(ErrorCodes.cycle);
      }
      // The rest are downstream of a cycle: evaluate them in topo order
      // with the cycle error present in _values.
      kahn(remaining.difference(cycleMembers));
    }
    return order;
  }

  CellValue _computeCell(CellRef ref) {
    final cell = sheet.cellAt(ref);
    if (cell == null) return const EmptyValue();
    if (cell.kind != CellKind.formula) return cell.literalValue;
    final source = cell.formulaSource!;
    final error = _parseErrorFor(source);
    if (error != null) return ErrorValue(error);
    final ast = _astCache[source]!;
    return _evaluator.evaluateScalar(ast);
  }
}
