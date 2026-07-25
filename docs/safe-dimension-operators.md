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
- Boolean conditions combine with `&&`, `||`, `!` — pure elementwise over
  columns (Kleene: `missing` propagates, both sides always evaluated — nothing
  short-circuits, there is no control flow here). `&&`/`||` bind **looser**
  than comparisons, so `a > 1 && b < 2` needs no parentheses. `&`/`|` are
  deliberately not operators (the error redirects); `&&`/`||` are grammar, not
  registry entries, so they do not appear in `listops()`.

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
| `topnames` | top-N labels `"1. name"`, ties via `dense`, rest bucketed as `others`.<br><br>Kwargs: `absolute`, `ranksep`, `dense`, `tol`, `others`, `parens`.<br><br>The name column may be any value type — values are stringified, so categorical columns (including another classifier's output) and integer ids rank; missing names land in `others`. | `dim"topnames(District, TestScr, 5)"` |
| `discretize` | bin numbers into ranked `CategoricalArray` labels.<br><br>**Break form** — `discretize(x, [b1, b2]; ...)`.<br>Kwargs: `boundedness` (`:unbounded`/`:boundedbelow`/`:boundedabove`/`:bounded`), `leftequal`, `absolute`, `rank`, `ranksep`, `label`, `compact`, `reverse`, plus number formatting (`prefix`, `suffix`, `scale`, `precision`, `commas`, ...).<br><br>**Quantile form** — `discretize(x, quantiles = [...])` or `discretize(x, ngroups = 4)`. | `dim"discretize(TestScr, quantiles=[.25,.5,.75])"`<br><br>`dim"discretize(x, [0, 10], boundedness = :boundedbelow)"` |
| `quantiles` | `quantiles(measure, [q1, q2, ...])` — label each value by the quantile bucket it falls into.<br><br>Bare use ranks rows individually (window kind); add `\|> groupby(keys...)` to aggregate `measure` per group first and label the groups.<br><br>Boundaries are the INNER quantiles — 0 and 1 are implied, so `[.25,.5,.75]` yields `1. [0%, 25%)` … `4. [75%, 100%]`.<br><br>`ngroups = n` is the boundary-free convenience (same kwarg as `discretize`): equal-width boundaries `1/n … (n-1)/n`, so `quantiles(x, ngroups = 4)` ≡ `quantiles(x, [.25,.5,.75])`. The boundary vector is optional — bare `quantiles(x)` defaults to quartiles — and giving both boundaries and `ngroups` is an error.<br><br>Kwargs: `ngroups`, `leftequal` (default `true`; `false` flips to `[0%, 25%]`, `(25%, 50%]`, …), `prefix` / `suffix` decorating the interval (`"1. <prefix> [0%, 25%) <suffix>"`). | `dim"quantiles(TestScr, [.5]) \|> groupby(District)"`<br><br>`dim"quantiles(TestScr, ngroups = 5)"` |
| `where` | flag by a Boolean condition — the labels default to **the condition text itself**: `dim"where(sales > 100)"` labels rows `"sales > 100"` / `"Not sales > 100"`.<br><br>Kwargs `true_label`, `false_label` customize (`false_label` defaults to `"Not " * true_label`, so `true_label = "big"` gives `"big"` / `"Not big"`); missing conditions label `missing`; the true label sorts first.<br><br>Bare use flags rows (window kind — a scalar condition like `where(sum(sales) > 100)` flags whole partitions); add `\|> groupby(keys...)` to flag groups by their aggregates. | `dim"where(sales > 100 && sales < 200)"`<br><br>`dim"where(TestScr > 35) \|> groupby(District)"` |
| `yyyy` | coarser calendar bucket, chronologically-sortable string label: `"2025"` | `dim"yyyy(t)"` |
| `yyyyq` | `"2025Q3"` | `dim"yyyyq(t)"` |
| `yyq` | `"25Q3"` | `dim"yyq(t)"` |
| `yyyymm` | `"202507"`.<br>Optional positional delimiter — `yyyymm(t, "/")` → `"2025/07"` | `dim"yyyymm(t)"` |
| `yymm` | `"2507"`; same optional delimiter | `dim"yymm(t, \"-\")"` |

`discretize` used bare is **window**-kind (bins row values); wrap in
`dimspec(...; by = :District, kind = :pivot)` to bin *group aggregates*
(e.g. districts by their enrollment totals).

The date buckets (`yyyy`/`yyyyq`/`yyq`/`yyyymm`/`yymm`) take a single
`Date`/`DateTime` column and apply elementwise (`missing` propagates); the
string output's lexical order is chronological order (year first,
zero-padded), making them ready-made pivot keys. Cycle accessors
(month-of-year, day-of-week) are deliberately *not* shipped — coarser buckets
are what pivot keys need; `registerop!` any `Dates` accessor if a host wants
seasonality.

```julia
agg(df, [:ym => dim"yyyymm(t)"]; hints, allbut = [:t])
# one row per CALENDAR month -- year boundaries handled correctly, unlike a
# month-of-year accessor, which would conflate 2025-12 with 2026-12
```

## Order-based operators (window kind, pair with `order`)

| Operator | Meaning | Example |
|---|---|---|
| `cumsum` | running total within the partition | `dimspec(dim"cumsum(sales)"; order = :date)` |
| `cumprod` | running product | `dimspec(dim"cumprod(growth)"; order = :date)` |
| `lag` | previous sibling's value; `lag(x, n)`, kwarg `default` | `dimspec(dim"lag(sales)"; order = :date)` |
| `lead` | next sibling's value; `lead(x, n)`, kwarg `default` | `dimspec(dim"lead(sales)"; order = :date)` |

Results are scattered back through the inverse sort permutation, so the new
column stays aligned with the original row order.

## Ranking (window kind)

Four ways to number a partition's rows, differing only in how they treat
**ties**. All take the kwarg `rev` (default `false`) and behave exactly as their
StatsBase namesakes.

| Operator | `10, 20, 20, 30` → | Ties | SQL / prior art |
|---|---|---|---|
| `rank` | `1, 2, 2, 4` | share a rank, then **skip** the slots consumed | `RANK()`, dplyr `min_rank`, StatsBase `competerank` |
| `denserank` | `1, 2, 2, 3` | share a rank, **no gaps** — the largest rank is the number of *distinct* values | `DENSE_RANK()`, StatsBase `denserank` |
| `ordinalrank` | `1, 2, 3, 4` | **no ties** — broken by row position | `ROW_NUMBER()`, StatsBase `ordinalrank` |
| `tiedrank` | `1, 2.5, 2.5, 4` | share the tie group's **average** rank (`Float64`) | fractional rank, StatsBase `tiedrank` |

Rank 1 is the **smallest** value by default, as in SQL, dplyr and StatsBase;
`rev = true` flips it, which is the "biggest is #1" reading:

```julia
dim(df, [:County, :salesrank => dim"rank(sales, rev = true)"])
# within each county: 1 = best-selling district
```

`rev` does **not** reverse the tie-break: the first-occurring member of a tie
still takes the lower ordinal rank in both directions. `missing` ranks
`missing` and consumes no rank slot; the result column is `Int` (`Float64` for
`tiedrank`) unless the input column can hold `missing`.

### `ordinalrank` is the one that needs an `order`

`rank`, `denserank` and `tiedrank` rank **values**, so — unlike
`cumsum`/`lag`/`lead` — they need no `order`. The answer is the same however
the partition happens to be sorted, and an `order` added for a *sibling*
dimension cannot disturb them.

`ordinalrank` is the exception: it has to break ties somehow, and it breaks them
by **row position**. That makes it position-based like `lag`/`lead`, so pair it
with an `order` to get a defined answer:

```julia
dim(df, [:County, :n => dim"ordinalrank(sales) |> orderby(date)"])
# 1 = the county's earliest row, counting up -- ties in `sales` resolved by date
```

Without one it numbers by whatever order the rows happen to sit in the frame,
which is the analogue of SQL's `ROW_NUMBER()` with no `ORDER BY`. That is
permitted here (exactly as bare `dim"lag(sales)"` is) rather than an error, but
it is rarely what you mean.

`tiedrank`'s defining property is that the ranks always sum to `n(n+1)/2`
however the ties fall — it is the rank transform Spearman correlation is
defined on, which is why it is the shape most Julia users expect from a
"rank" that has to average.

### Names and exports

The four are **not exported** into `Main` — the lone exception to this
package's export-every-verb rule. `rank` would collide with
`LinearAlgebra.rank` (matrix rank) and the other three with their
`StatsBase` namesakes, so exporting would turn a host's working bare
`denserank(x)` into an ambiguity error. String specs are unaffected (they
resolve against the registry, not `Main`); a *trusted* `Expr` spec should
qualify: `:( DataFrameAggrSpec.tiedrank(:sales) )`.

Three of the four use StatsBase's spelling exactly. `rank` is the deliberate
deviation — StatsBase calls it `competerank`, but SQL's `RANK()` is the far
commoner name for the commonest member of the family, and `rank` is not a
StatsBase-only concept the way the other three are.

### Ranking is not classification

The output is a number, not a label, and the spec stays window kind. To rank
*groups* rather than rows, aggregate them first with the `groupby` modifier:

```julia
dim(df, [:County, :r => dim"rank(EnrlTot) |> groupby(District)"])
# ranks districts by their total enrollment, broadcasting each district's rank
# back to its member rows
```

For a top-N *label* with an "others" bucket, reach for `topnames` instead.

### Modifiers

Engine options attach to a spec with postfix **modifiers** — intent first,
option after (`∘` is a synonym for `|>`). Modifiers are metadata, never
function calls, and their names (`orderby`, `groupby`) are reserved —
`registerop!` will refuse them. One of each per spec; the Julia-side
equivalent is `dimspec(spec; order = ..., by = ..., kind = ...)` — specifying
the same option both ways is an error.

`orderby` (not `groupby`) is also legal at the top level of an **aggregation**
spec — `aggr"first(_) |> orderby(date)"` — where it sorts the group's rows
before the reduction runs. See "Ordering (`orderby`)" in
[safe-aggregation-operators.md](safe-aggregation-operators.md).

**`orderby(cols...)`** — window ordering:

```julia
dim"cumsum(sales) |> orderby(date)"            # ascending
dim"lag(sales) |> orderby(date => :desc)"      # direction
dim"cumsum(sales) |> orderby(region, date)"    # multi-key
```

On a **window** dimension the partition's *rows* are sorted, the operator runs
over the sorted vectors, and results scatter back to the original rows.

On a **pivot** dimension (one with `groupby`, or a classifier verb) `orderby`
sorts the *groups*: the group-level vectors — keys, or measures aggregated per
`AggrHints` — are ordered before the verb runs. This is the Pareto idiom:

```julia
dim"cumsum(sales) |> groupby(region) |> orderby(sales => :desc)"
# every row: the running total over regions, largest region first.
# `sales` inside orderby names the group-level aggregate -- the only sales
# that exists at that stage (see design/compound-modifiers.md)
```

Modifier textual order is **not** semantic: `groupby(g) |> orderby(m)` and
`orderby(m) |> groupby(g)` are the same spec. Modifiers are options, like
keyword arguments; the engine plan is fixed — group, order the groups, verb.

**`groupby(keys...)`** — pivot grouping, the universal "right-group-by":

```julia
dim"discretize(EnrlTot, [35, 60]) |> groupby(District)"   # bin district totals
dim"quantiles(TestScr, [.5]) |> groupby(District)"        # quantile-rank districts
dim"hilo(TestScr) |> groupby(District)"                   # any host verb, zero registration
```

The measure is **aggregated at this granularity first** (per `AggrHints`,
within each context partition) and the verb classifies the groups — the table
is never reduced; each group's label broadcasts back to its member rows.
Presence of `groupby` is what makes a spec pivot-kind. Verbs whose grouping
column is data in the spec (`topnames`' 1st argument) imply their grouping and
reject an additional `groupby`.

Keys may be **computed**, not just bare columns — `groupby(yyyymm(date))`
buckets by a calendar bucket instead of an existing column, exactly like the
nested composite-aggregation `groupby` below:

```julia
dim"cumsum(sales) |> groupby(yyyymm(date))"                     # bucket by calendar month
dim"cumsum(sales) |> groupby(region, yyyymm(date))"              # mixed bare + computed keys
```

The `[col, ...]` array spelling stays plain-column-only — mix a computed
key into it (`groupby([region, yyyymm(date)])`) and it errors with a
redirect to the varargs form instead.

A `|> groupby(...)` **nested inside** a spec argument is a different thing:
a *computational* grouped reduction — evaluate the inner spec once per key
combination and collect the results into a key-sorted vector (see "Composite
aggregation" in
[safe-aggregation-operators.md](safe-aggregation-operators.md)). Top-level =
engine metadata (aggregate per `AggrHints`, classify the groups, broadcast
labels); nested = inline math over explicitly-spelled subgroup reductions,
and the spec stays window kind:

```julia
dim"mean(sum(pop) |> groupby(year))"   # the average yearly total, on every
                                       # member row of the partition
```

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
`nrow` `count` `any` `all` `first` `last` `skipmissing` `uniqvalue` `countuniq`
`unionall` `wmeanfallback`
(e.g. `dim"countuniq(District)"` — the distinct-District count on every
member row of the partition).

## Elementwise math, arithmetic, comparisons

- `abs` `log` `log2` `log10` `exp` `sqrt` `round` `floor` `ceil` `min` `max` —
  elementwise on columns: `dim"round(sales / sum(sales), digits = 2)"`,
  `dim"max(sales, 0)"`.
- `ismissing` and `coalesce` — elementwise missing-value handling.
  `dim"ismissing(comment)"` is a Bool pivot key
  (`dim"where(ismissing(comment))"` labels it);
  `dim"coalesce(phone_mobile, phone_home, 0)"` is a fallback cascade (first
  non-missing wins; the default must be a literal — bare `missing` is a
  column name). Under the Kleene `||`, `dim"ismissing(x) || x > 3"` is
  correct on missing rows: `ismissing` rescues the branch that would
  otherwise stay `missing`.
- `+` `-` `*` `/` `^` and `==` `!=` `<` `<=` `>` `>=` `≠` `≤` `≥` and `!`
  (elementwise negation: `dim"!(a > b)"`, `dim"!flag"`) — broadcast semantics
  (dotted spellings `.+` `.<` ... are aliases). Comparison results are Bool
  columns, handy as pivot keys — a bare condition is a legal spec
  (`dim"sales > 10 && sales < 20"`), and `where` turns one into readable
  labels.
- `in` — membership test, `dim"district in [\"d1\", \"d2\", \"d5\"]"`. The
  item (left side) broadcasts elementwise; the collection (right side, a
  literal `[ ... ]` array or a column) is compared as a WHOLE, not zipped
  element-by-element against the item — the bug a naive broadcast of `in`
  would have. This is the whitelisted replacement for a chain of `||`
  equality checks: `dim"where(x in [1, 2, 5])"` labels rows
  `"x in [1, 2, 5]"` / `"Not x in [1, 2, 5]"`, where the unwieldy alternative
  is `dim"where(x == 1 || x == 2 || x == 5)"`.
  **`∈`** is the Unicode spelling of `in` (`x ∈ [1, 2, 5]`, same closure);
  **`∉`** is its negation (`x ∉ [1, 2, 5]` ≡ `!(x in [1, 2, 5])`).

## Extending the whitelist

Extension is a trusted act done in host code, never via spec strings:

```julia
registerop!(:double, x -> 2 .* x)     # dim"double(sales)"

# pivot verbs need NO registration -- users write `|> groupby(keys...)`:
registerop!(:hilo, measure -> ...)              # dim"hilo(x) |> groupby(District)"

# register a CLASSIFIER only when the grouping column is DATA in the spec
# (like topnames, whose 1st argument is the label source):
registerop!(:tophalf, (name, measure) -> ...)   # labels one value per group
registerclassifier!(:tophalf, 1)                # argument 1 = the name column
```

Host-registered operators are deliberately **not** listed here — this document
covers only the shipped defaults.

Verb style convention: **data positional, options keyword** (`strjoinuniq`'s
positional `sep`/`limit` predate the convention; the date buckets' positional
delimiter is a deliberate exception for typeability — `yyyymm(t, "/")`).
