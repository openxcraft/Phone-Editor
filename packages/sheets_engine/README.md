# sheets_engine

Pure-Dart spreadsheet engine for the mobile workspace (Phase 5 of
`../../PLAN.md`). No Flutter imports, no runtime dependencies, no wall
clock anywhere: `TODAY()` resolves through a date provider injected into
`SheetEngine`/`Evaluator`, and returns `#VALUE!` when none is injected.

## Contents

| File | Contents |
|---|---|
| `lib/src/a1.dart` | `CellRef` / `CellRange` — A1 parsing & formatting, `$A$1` accepted |
| `lib/src/model.dart` | `CellValue` (empty/number/text/bool/error), stored `Cell`, sparse `Sheet`, deterministic JSON |
| `lib/src/formula.dart` | Tokenizer, AST, recursive-descent parser (grammar in the file header) |
| `lib/src/evaluator.dart` | Operator semantics, coercion, function library, date serials |
| `lib/src/engine.dart` | `SheetEngine` — dependency graph, topological recalc scheduler, cycle detection |
| `lib/src/charts.dart` | `ChartData` extraction for bar/line/pie (data only, no rendering) |
| `lib/src/pivot.dart` | `pivotSummary` — group-by with sum/count/average |
| `lib/src/io.dart` | `CsvCodec` — RFC 4180 parse/encode, CSV import (kind inference) and computed-value export |

## Behaviour

- **Sparse grid** — cells keyed by `(row, col)`; storing an empty cell
  removes it. `Sheet.toJsonString()` is the formula-preserving form:
  cells sorted by (row, col), formulas stored normalized with a leading
  `=`. Same sheet → same JSON string.
- **Recalc** — `SheetEngine.setCell` recalculates only the edited cell
  and its transitive dependents, dependencies first (deterministic
  (row, col) tie-breaking). `recalculateAll()` is the recovery path after
  mutating the `Sheet` directly. Dependencies include every cell of every
  referenced range, so editing a previously empty cell inside a range —
  or rewiring a formula — is picked up.
- **Cycles** — members of a dependency cycle evaluate to `#CYCLE!`;
  dependents receive it through ordinary error propagation; non-cycle
  cells are unaffected. Breaking the cycle restores normal values.
- **Errors are values**: `#DIV/0!`, `#VALUE!`, `#REF!`, `#NAME?`,
  `#CYCLE!`, and `#N/A` (lookup misses). Syntax errors map to `#REF!`
  (malformed reference) or `#VALUE!` (other), unknown names to `#NAME?`.
- **Coercion** (Excel-like): empty → 0 / FALSE / ""; booleans → 1/0 in
  arithmetic; numeric text parses in arithmetic and scalar aggregate
  arguments; non-numeric text in arithmetic → `#VALUE!`. Text comparison
  is case-insensitive.

## Function set (exact)

- Aggregates/statistical: `SUM`, `AVERAGE`, `MIN`, `MAX`, `COUNT`
  (numbers & numeric scalar text), `COUNTA` (all non-empty incl. errors),
  `STDEV` (sample, n−1; <2 values → `#DIV/0!`), `MEDIAN`, `SUMIF`
  (criteria: number, text, or text with a leading `>=` `<=` `<>` `>` `<`
  `=` operator).
- Logic: `IF` (lazy — the untaken branch is not evaluated), `AND`, `OR`,
  `NOT`.
- Math: `ABS`, `ROUND` (half away from zero, negative digits allowed),
  `SQRT` (negative → `#VALUE!`), `POWER`.
- Text: `CONCAT`, `LEFT`, `RIGHT`, `LEN`, `UPPER`, `LOWER` — string
  lengths and slices are rune-based.
- Dates: `DATE`, `YEAR`, `MONTH`, `DAY`, `TODAY` (injected). Serials are
  days since 1899-12-30 — uniformly one more than the legacy 1900-system
  serial (which contains a fictitious 1900-02-29, not reproduced);
  DATE/YEAR/MONTH/DAY round-trip exactly.
- Lookup: `VLOOKUP` (exact match when the 4th argument is FALSE; the
  approximate form — last key ≤ value — is the default, as usual),
  `INDEX` (2-D ranges, single row/column ranges, scalar), `MATCH`
  (types 0 exact, 1 largest ≤, −1 smallest ≥; 1-based result; miss →
  `#N/A`).

## Operators

`+ - * / ^ %`(postfix percent) `&` (concat) `= <> < <= > >=`, unary
`+`/`-`, parentheses. Precedence: comparison < `&` < `+ -` < `* /` <
`^` (left-associative) < unary < `%` < primary. Ranges (`A1:B2`) are
valid as function arguments; using one as a scalar is `#VALUE!`.

## Charts & pivot

`buildChart(engine, kind, categories, data, …)` reads computed values:
columns (or rows) of `data` become series, an optional header row names
them, non-numeric cells become null gaps. Pie uses the first series and
drops gaps/non-positive slices with their categories.

`pivotSummary(engine, range, keyColumn, valueColumn, aggregation)`
groups rows by the key column's computed value (empty/error keys
skipped), aggregating the value column with sum/count/average; ordering
is numeric keys ascending, then text keys.

## CSV

RFC 4180: CRLF rows on export, quoted fields with `""` escapes, quoted
newlines supported on import. Export writes **computed values** over the
used rectangle. Import infers kinds: leading `=` → formula, `TRUE`/`FALSE`
→ bool, a known error code → error cell, numeric literal → number, else
text.

## Deliberate simplifications

- Single sheet per engine instance; no cross-sheet references, named
  ranges, array formulas, or structured references.
- Ranges expand to per-cell dependencies (a dependency edge per cell in
  the range): simple and exact, but a formula over a huge range (say
  `SUM(A1:A1000000)`) costs proportional memory in the graph.
- `findReplace`-style text semantics: string literals in formulas use
  `""` escaping only (no backslash escapes).
- Aggregate functions over ranges propagate the first range error
  (except `COUNT`/`COUNTA`, which classify cells instead) — matching
  common spreadsheet behaviour for `SUM`/`AVERAGE` etc.
- XLSX export is not in this package; it belongs to the Phase 5 export
  work in the export engine (see `../../EXPORT.md`).

## Verification

```
dart pub get && dart analyze   # No issues found
dart test                      # 50 tests, all passing
```

including a 5,000-cell dependency chain recalc (plus full ripple from
the head) and a 1,000-cell `SUM` range, both asserted for correct tail
values under a generous time bound.
