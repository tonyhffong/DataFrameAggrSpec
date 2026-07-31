# Prior art: what else occupies this design space

*Survey, 2026-07. Question posed: "are there existing packages like this out
there in other languages?" Recorded so that positioning claims in the README
are grounded, and so a future "why don't we just do what X does" proposal
starts from an accurate picture of what X actually does.*

## Verdict

No single package occupies this whole space, but **every individual axis has
strong prior art** — and the closest relatives are not DataFrame libraries.
They are BI tools (Tableau, Power BI/DAX) and search/document aggregation
DSLs (Elasticsearch, MongoDB, Druid). The DataFrame-library neighbours
(Polars, PySpark, Ibis, pandas) match the *runtime-expression* axis but none
of the others.

This package's contribution is the **combination**, plus one genuinely
distinctive spelling (the flat left-context chain, §6).

## 1. Safe runtime expression evaluation — crowded

The most populated axis; `safe.jl`'s approach is conventional here, which is
a good sign rather than a bad one.

| Ecosystem | Package | Relation |
|---|---|---|
| Python | `simpleeval`, `asteval` | AST-walking whitelist interpreters that deliberately avoid `eval` — structurally the same technique as `compile_node` |
| Cross-language | Google **CEL** (Common Expression Language) | Closest in *posture*: non-Turing-complete by construction, default-deny, explicitly for untrusted input (Kubernetes admission control, Envoy) |
| Java | JEXL, SpEL, MVEL | "let users type expressions" languages, long-established |
| JavaScript | `filtrex`, `expr-eval`, `jsep` | `filtrex` is explicitly a tiny language for user-supplied filters in a UI |
| Rust | `evalexpr`, `rhai` | sandboxed scripting/expression evaluation |

**What none of them have: DataFrame awareness.** They evaluate scalar
expressions against a variable-bindings map. The pieces with no off-the-shelf
equivalent are "bare identifier = column", operators broadcasting over
vectors without dots, and `_` as the aggregation target.

**Implication:** do not treat the whitelist-interpreter design as novel or
precious — it is the standard solution. The novelty belongs to the
grammar over columns, not to the sandbox.

## 2. Aggregation specs as runtime data — the strongest structural matches

**Elasticsearch aggregations DSL** is the closest semantic model. Its split
between *bucket* aggregations (partition the documents) and *metric*
aggregations (reduce them) maps almost exactly onto this package's
dimensioning/aggregation pillars, and the verb vocabularies line up
verb-for-verb:

| Elasticsearch | here |
|---|---|
| `terms` (with `size: n`) | `topnames` |
| `range` | `discretize` |
| `percentiles` | `quantiles` |
| `date_histogram` | `yyyy` / `yyyyq` / `yyyymm` / … |
| sub-aggregations (unlimited nesting) | composite aggregation (`inner \|> groupby(k)`) |

**MongoDB `$setWindowFields`** is the closest match to `WindowDim`
specifically: `partitionBy` / `sortBy` / `output` is exactly `by` / `order` /
spec, and the MongoDB docs describe it as computing running totals and ranks
*"without collapsing the document set"* — this package's non-destructive
`dim` contract (composition-rules.md R3) stated in someone else's words.

**Apache Druid** native queries go further and use the same vocabulary
outright: `dimensions`, `aggregations`, `granularity`.

**The difference:** all three are client/server query languages over a
datastore. This package is in-process over an in-memory table, with no
backend, index, or cube to build first.

## 3. Dimension-as-derived-pivot-key — BI-tool territory, not library territory

The idea that a *computed* column can itself become a pivot key is well
established, but almost exclusively inside BI products rather than
programming libraries:

- **Tableau LOD expressions** — `{FIXED [Region] : SUM([Sales])}` is
  `WindowDim` with an explicit `by`: compute an aggregate at a stated
  granularity, broadcast it back to row level. Tableau also classifies every
  calculated field as either a dimension or a measure.
- **Power BI / DAX** — draws the line most sharply of all: a *calculated
  column* is materialized row-by-row and **can** be used as a slicer or pivot
  axis; a *measure* is evaluated in filter context and **cannot**. That is
  precisely the `dim`/`agg` split, including the "dimensions become pivot
  keys" consequence.
- **MDX calculated members** — the OLAP ancestor of both.

**Implication:** when explaining the `dim`/`agg` distinction to a
data-analyst audience, "calculated column vs measure" is a ready-made
intuition to borrow, and lands faster than anything invented here.

## 4. Expressions as first-class runtime values in DataFrames — matched, minus safety

- **Polars** — `pl.col("x").sum().over("region")`; expressions are runtime
  objects that can be built, stored, and passed around. `.over()` is the
  window partition.
- **PySpark** — `F.expr("...")` parses a SQL string into a column expression
  *at runtime*; `Window.partitionBy().orderBy()` alongside.
- **Ibis** — deferred, backend-agnostic expression objects.
- **pandas** — `df.eval()` / `df.query()`, with a restricted parser.

These match the **runtime, not compile-time** axis — the axis the README
uses to contrast with DataFramesMeta. **None is a sandbox**: `F.expr()` runs
arbitrary SQL, and `pandas.eval` was never a trust boundary. So they are
prior art for *late binding*, not for *accepting a stranger's string*.

Within Julia, the honest comparison remains DataFramesMeta: same conceptual
space, compile-time macros, which is exactly why it cannot accept a spec from
a text field.

## 5. Nearest sibling in spirit

**VisiData** (terminal data explorer): type an expression to create a derived
column, set per-column aggregators, pivot via frequency tables. Closest thing
to what TermWin + DataFrameAggrSpec is *together*. Its expression language is
unsandboxed Python — precisely the gap the safe grammar fills.

## 6. What actually looks distinctive

In rough order of how unusual it is:

1. **The flat chain with left context.** Elasticsearch and Malloy express the
   same nesting semantics through *literal nesting* (`nest:` blocks, nested
   `aggs` objects). This package flattens it: position in a vector *implies*
   the grouping context. This is a real design contribution, not a cosmetic
   one, because it is what makes the README's core promise true — reordering
   pivot levels in a nested DSL means restructuring braces, whereas in a flat
   chain it is swapping two elements. **The "move a link up and down the
   chain, that's it" claim is only cheap *because* the nesting is implicit.**
   Do not "clarify" chains by introducing explicit nesting; that trade is the
   whole point.
2. **Safe-by-default with a trusted escape hatch in one API.** Nearly every
   other system picks a side — CEL sandboxes everything, `pandas.eval` trusts
   everything. Per-entry trust resolution, letting host-authored `Expr` dims
   and user-typed `dim"..."` dims interleave in one chain
   (composition-rules.md R5), is uncommon.
3. **`dim`/`agg` as a non-destructive/destructive pair driven by the same
   chain object.** Elasticsearch returns buckets with their metrics in one
   shot; asking it for "the pre-aggregation rows with the bucket labels
   attached" is awkward. That `agg` decomposes exactly into `dim` plus a
   reduction (composition-rules.md R3) falls out of sharing one chain, and
   has no obvious equivalent elsewhere.

## Positioning guidance

If the README ever needs to situate the package against a named system,
prefer **Elasticsearch aggregations** for the semantic model (bucket/metric ≡
dimension/aggregation) and **DAX calculated columns vs measures** for the
`dim`/`agg` intuition. Both are widely known and land the idea in one
sentence. Avoid claiming novelty for the safe-evaluator machinery (§1) — the
defensible claims are the flat left-context chain and the trust-interleaving,
not the sandbox.

*Caveat: this is a conceptual mapping from general knowledge plus spot-checks
of the MongoDB, Elasticsearch, and Malloy documentation — not an exhaustive
survey. Treat the per-system details as directionally accurate rather than
citable.*
