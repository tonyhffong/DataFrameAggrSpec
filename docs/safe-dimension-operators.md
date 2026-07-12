# Safe Dimension Operators

The operators available inside **untrusted dimension specs** — strings parsed
by `parsedim(s)` / `dim"..."` and typically typed by an end user in a TUI/GUI.
A dimension spec creates a **new column** whose values are computed from
*sibling rows* (rows sharing the same partition keys); existing data is never
modified.

> **Maintenance rule:** this document must list every dimension-relevant
> operator in the `SafeOps` registry (`src/safe.jl`). Whenever an operator is
> added to or removed from the shipped registry, update this file (or
> `safe-aggregation-operators.md`). The testset *"operator docs stay in sync"*
> in `test/safe.jl` fails otherwise.

## Grammar recap

- bare identifier = **column** (`District`, `sales`); `_` is **not** allowed
  (it is the aggregation-target placeholder)
- `:sym` = a Symbol option value (`boundedness = :boundedbelow`); literals:
  numbers, strings, `true`/`false`, `[ ... ]` arrays
- kwargs in either form: `f(x, k = v)` or `f(x; k = v)`
- no dots needed for arithmetic — operators broadcast

## Two evaluation kinds

- **window** (default): the spec sees the partition's row-level column vectors;
  a scalar result broadcasts to the partition, a partition-length vector maps
  row-to-row. Partition = the chain's left context (or `by` when built
  directly).
- **pivot**: groups are classified by their *aggregates* — group by `by` within
  each context partition, aggregate the referenced columns (per `AggrHints`),
  run the spec over those per-group vectors, broadcast each group's label to
  its member rows.

A top-level `topnames` call is inferred as pivot kind; everything else defaults
to window. Force the kind (and attach ordering or extra grouping keys) with
`dimspec(dim"..."; by = ..., order = ..., kind = :pivot)`.

## Classification verbs (pivot-kind workhorses)

| Operator | Meaning | Example |
|---|---|---|
| `topnames` | top-N labels `"1. name"`, ties via `dense`, rest bucketed as `others`; kwargs `absolute`, `ranksep`, `dense`, `tol`, `others`, `parens` | `dim"topnames(District, TestScr, 5)"` |
| `discretize` | bin numbers into ranked `CategoricalArray` labels; break form `discretize(x, [b1, b2]; ...)` with kwargs `boundedness` (`:unbounded`/`:boundedbelow`/`:boundedabove`/`:bounded`), `leftequal`, `absolute`, `rank`, `ranksep`, `label`, `compact`, `reverse` + number formatting (`prefix`, `suffix`, `scale`, `precision`, `commas`, ...); quantile form `discretize(x, quantiles = [...])` or `discretize(x, ngroups = 4)` | `dim"discretize(TestScr, quantiles=[.25,.5,.75])"`, `dim"discretize(x, [0, 10], boundedness = :boundedbelow)"` |
| `quantiles` | `quantiles(measure, [q1, q2, ...], [groupcol, ...])` — group by the 3rd-argument columns (auto-added to `by`, like `topnames`), aggregate `measure` per group (per `AggrHints`), then label each group by the quantile bucket its aggregate falls into. Boundaries are the INNER quantiles — 0 and 1 are implied, so `[.25,.5,.75]` yields `1. [0%, 25%)` … `4. [75%, 100%]`. An **empty** (or omitted) 3rd argument switches to window kind: rows are ranked individually within the partition (`dim"quantiles(TestScr, [.5], [])"`). Kwargs: `leftequal` (default `true`; `false` flips to `[0%, 25%]`, `(25%, 50%]`, …), `prefix` / `suffix` decorating the interval (`"1. <prefix> [0%, 25%) <suffix>"`) | `dim"quantiles(TestScr, [.25,.5,.75], [District])"` |

`discretize` used bare is **window**-kind (bins row values); wrap in
`dimspec(...; by = :District, kind = :pivot)` to bin *group aggregates*
(e.g. districts by their enrollment totals).

## Order-based operators (window kind, pair with `order`)

| Operator | Meaning | Example |
|---|---|---|
| `cumsum` | running total within the partition | `dimspec(dim"cumsum(sales)"; order = :date)` |
| `cumprod` | running product | `dimspec(dim"cumprod(growth)"; order = :date)` |
| `lag` | previous sibling's value; `lag(x, n)`, kwarg `default` | `dimspec(dim"lag(sales)"; order = :date)` |
| `lead` | next sibling's value; `lead(x, n)`, kwarg `default` | `dimspec(dim"lead(sales)"; order = :date)` |

Results are scattered back through the inverse sort permutation, so the new
column stays aligned with the original row order.

## Group-relative measures (window kind)

Reductions return a scalar per partition; arithmetic broadcasts it back across
the rows:

```julia
dim"sum(sales)"                              # group total on every member row
dim"sales / sum(sales)"                      # share of group
dim"(sales - mean(sales)) / std(sales)"      # z-score within group
dim"sales - lag(sales)"                      # change vs previous sibling
dim"sales > mean(sales)"                     # above-group-average flag
```

Available reductions (same functions as the aggregation side): `sum` `prod`
`mean` `median` `std` `var` `quantile` `minimum` `maximum` `extrema` `length`
`count` `first` `last` `skipmissing` `uniqvalue` `unionall`.

## Elementwise math, arithmetic, comparisons

- `abs` `log` `log2` `log10` `exp` `sqrt` `round` `floor` `ceil` `min` `max` —
  elementwise on columns: `dim"round(sales / sum(sales), digits = 2)"`,
  `dim"max(sales, 0)"`.
- `+` `-` `*` `/` `^` and `==` `!=` `<` `<=` `>` `>=` `≠` `≤` `≥` — broadcast
  semantics (dotted spellings `.+` `.<` ... are aliases). Comparison results are
  Bool columns, handy as pivot keys.

## Extending the whitelist

Extension is a trusted act done in host code, never via spec strings:

```julia
registerop!(:double, x -> 2 .* x)     # dim"double(sales)"

# a custom CLASSIFIER verb (pivot kind, like topnames): register the function,
# then declare which argument carries its grouping key(s)
registerop!(:tophalf, (name, measure) -> ...)   # labels one value per group
registerclassifier!(:tophalf, 1)                # argument 1 = the name column
# array-of-columns classifiers use many = true (quantiles is
# registerclassifier!(:quantiles, 3, many = true))
```

Host-registered operators are deliberately **not** listed here — this document
covers only the shipped defaults.

Verb style convention: **data positional, options keyword** (`strjoinuniq`'s
positional `sep`/`limit` predate the convention).
