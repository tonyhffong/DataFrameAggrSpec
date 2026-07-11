# DataFrameAggrSpec.jl

A UI-free **runtime** DSL for DataFrame *aggregation* and *dimensioning*.
Specifications — supplied as `Symbol`s, `String`s, `Expr`s, spec objects, or
lambdas at runtime — are compiled into functions over a `DataFrame`. Unlike
[DataFramesMeta.jl](https://github.com/JuliaData/DataFramesMeta.jl), whose macros
run at compile time, these specs can arrive from a GUI, a config file, or a
database and be turned into working transforms on the fly.

Extracted from [TermWin.jl](../TermWin), which uses it to power its interactive
DataFrame tree/pivot viewer.

Two pillars, one composition rule:

- **Aggregation** — reduce a group of rows to one value per column
  (`liftAggrSpecToFunc`, `AggrHints`, `aggregate`).
- **Dimensioning** — add NEW columns (existing data is never modified) whose
  values are computed from *sibling rows*: rows sharing the same partition-key
  values (`WindowDim`, `PivotDim`, `dim`).
- **Composition** — *chains* declare dimensions inline in a pivot list,
  partitioned by their **left context**; a declared dimension is immediately a
  pivot key for what follows (`pivottable`).

## Aggregation specs

```julia
using DataFrameAggrSpec, DataFrames, StatsBase

df = DataFrame(TestScr = [1.0, 2, 3, 4], EnrlTot = [10.0, 20, 30, 40])

# `:_` is the on-the-fly *target* column; `:EnrlTot` is a named column reference.
# One spec can be reused across many target columns (shared weight, per-column mean).
f = liftAggrSpecToFunc(:TestScr, :( StatsBase.mean(:_, StatsBase.Weights(:EnrlTot)) ))
Base.invokelatest(f, df)          # weighted mean of TestScr

liftAggrSpecToFunc(:TestScr, :sum)            # bare Symbol → sum(df.TestScr)
liftAggrSpecToFunc(:TestScr, :( quantile(:_, 0.75) ))
```

Compiled functions are cached and evaluated at a fresh world-age, so call them via
`Base.invokelatest`. (The higher-level verbs below — `aggregate`, `dim`,
`pivottable` — do this internally; their callers never need `invokelatest`.)

### AggrHints — how to aggregate each column

Resolution order: column `Symbol` → element `Type` (by subtyping, first match
wins) → `default` (a `Type -> spec` function, `defaultAggr` unless overridden:
`Real → :sum`, `Vector → :unionall`, otherwise `:uniqvalue`).

```julia
hints = AggrHints(:TestScr => :( mean(:_, Weights(:EnrlTot)) ),
                  AbstractString => :uniqvalue)
resolveaggr(hints, :TestScr, Float64)   # the Expr above
aggregate(df, [:County]; hints)         # one row per County, all other cols reduced
```

## Dimensioning

A dimension is a *new* column computed from sibling rows. Two kinds:

- **`WindowDim(name, spec; by, order)`** — `:col` binds to the partition's
  row-level subvector (sorted by `order` if given). The spec result is a scalar
  (broadcast to the partition) or a partition-length vector. Covers group
  totals, shares, z-scores, `cumsum`/`lag`/`lead`/ranks.
- **`PivotDim(name, spec; by, context)`** — classifies *groups*: within each
  `context` partition, rows are grouped by `by`, the referenced columns are
  aggregated per group (see `dependencies(d)` and `AggrHints`), the spec runs
  over those per-group vectors, and each group's label is broadcast back to its
  member rows. This is the home of `topnames` / `discretize`-over-group-sums
  (the heir of the legacy `CalcPivot`).

```julia
dim!(df, WindowDim(:share, :( :sales ./ sum(:sales) ), by = :region))       # in place
df2 = dim(df, WindowDim(:cum, :( cumsum(:sales) ), by = :region, order = :date),
              WindowDim(:prev, :( lag(:sales) ), by = :region, order = :date))
df3 = dim(df, PivotDim(:top2, :( topnames(:region, :sales, 2) )))           # copy
```

`order` accepts `:col`, `:col => :asc/:desc`, vectors of those, and string
forms (`":date => :desc"`). Results are scattered back through the inverse
permutation, so output stays aligned with the original rows.

## Chains — dimensions as pivot keys, scoped by left context

A **chain** is an ordered pivot list. `Symbol`s (or `String`s) are existing
columns; `name => spec` (or `[name, spec]`, string-friendly) declares a new
dimension whose partition is **everything to its left in the chain**:

```julia
chain = [:County,
         :top5d  => :( topnames(:District, :TestScr, 5) ),   # per County, rank Districts
         :District,
         :scoreq => :( discretize(:TestScr, quantiles = [.25, .5, .75]) )]
                     # row-level quartile within [:County, :top5d, :District]

out = pivottable(df, chain; hints)   # materialize dims, then aggregate over all keys
df2 = dim(df, chain)                 # or: just add the columns, no aggregation
```

- Bare `Expr`/`String` specs default to **window** kind; a top-level `topnames`
  call defaults to **pivot** kind. Everything else is explicit via
  `dimspec(ex; by = extra_grouping_keys, order = ..., kind = :window | :pivot)`.
- A `Tuple` of pairs declares parallel **siblings**: same left context, not in
  each other's context —
  `[:region, (:share => ..., :cum => dimspec(...; order = :date))]`.
- Pure runtime-string chains work for GUI/config paths:
  `["County", ["top5d", "topnames(:District, :TestScr, 5)"], "District"]`.

## Pipelines

`dim(chain...; hints)` and `pivottable(chain; hints)` (no frame argument) return
reusable callable transforms:

```julia
report = pivottable([:region, :quartile => :( discretize(:sales, quantiles = [.25, .5, .75]) )];
                    hints = AggrHints(:sales => :sum))
df |> report                          # apply
df |> dim([:region, :z => :( (:sales .- mean(:sales)) ./ std(:sales) )]) |> report
(report ∘ dim([...]))(df)             # Base ∘ composes transforms
df ∘ dim([...])                       # sugar: apply left-to-right
```

## Presentation verbs

- **`discretize(x, breaks; …)`** / `discretize(x; quantiles/ngroups)` — bin a
  numeric vector into a `CategoricalArray` of human-readable labels
  (`"2. [0,1)"`, `"3. 1 ≤ x < 2"`, `"5. 3+"`), with rank prefixes, compact
  intervals, boundedness modes, and quantile-based auto-breaks.
- **`topnames(name, measure, n; …)`** — top-N ranking with tie handling
  (`dense`), an `"Others"` bucket, absolute-value mode, parenthesised negatives.
- **`lag(v, n; default)` / `lead(v, n; default)`** — shifted siblings, for
  order-based window dimensions.
- **`uniqvalue`**, **`unionall`** — the single unique value / flattened union.

Inside spec expressions, `^(:sym)` escapes a symbol from column substitution
(DataFramesMeta convention) — e.g.
`:( discretize(:x, [0, 1]; boundedness = ^(:boundedbelow)) )`.

## Legacy API (deprecated, kept for TermWin)

`CalcPivot(spec, by)` + `liftCalcPivotToFunc(ex, by)` and the
`CalcPivotAggrDepCache` side channel still work exactly as before, now shimmed
over the dimension engine. New code should use `PivotDim`/`WindowDim` + `dim`:
row-aligned output, `AggrHints` instead of kwargs, `dependencies(d)` instead of
the cache. `Dimension(name, cp::CalcPivot)` converts.

## Trust boundary

General spec expressions are compiled with `Core.eval(Main, …)` so that
module-qualified names (`StatsBase.mean`) resolve against your loaded packages.
The guards (must be a `:call`, no curly type-params, simple/dotted names only,
reject any `!`) make this safe for **specs you author** (config you control) but
are **not a sandbox** — do not feed untrusted user input to these functions.
