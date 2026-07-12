# DataFrameAggrSpec.jl

A UI-free **runtime** DSL for DataFrame *aggregation* and *dimensioning*.
Specifications — supplied as `Symbol`s, `String`s, `Expr`s, spec objects, or
lambdas at runtime — are compiled into functions over a `DataFrame`. Unlike
[DataFramesMeta.jl](https://github.com/JuliaData/DataFramesMeta.jl), whose macros
run at compile time, these specs can arrive from a GUI, a config file, or a
database and be turned into working transforms on the fly.

Motivation:
When developing [TermWin.jl], the dataframe view constantly needs to adjust and apply
aggregation and pivoting (via static or on-the-fly dimensions) operations on the 
tree/pivot viewer.  Abstraction of this layer is a natural extension of that need.

At the core of this package there are two operator pillars, one composition rule:

- **Aggregation** — operators that reduce a group of rows to one value per column
  (`liftAggrSpecToFunc`, `AggrHints`, `aggregate`).
- **Dimensioning** — operators that add NEW columns (existing data is never modified) whose
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
# One spec can be reused across many target columns (shared weight, per-column mean)
# without typing and retyping their names.

f = liftAggrSpecToFunc(:TestScr, :( StatsBase.mean(:_, StatsBase.Weights(:EnrlTot)) ))
Base.invokelatest(f, df)          # weighted mean of TestScr

#well known math functions can be named by just their name
liftAggrSpecToFunc(:TestScr, :sum)            # bare Symbol → sum(df.TestScr)

#This package depends on the package Statistics so you can do this readily:
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

(`aggregate` is the primitive — `pivottable` ≡ materialize the chain's
dimensions, then `aggregate` over the full key list.)

**The `by` rule**: `by` always means the grouping keys a dimension declares
*itself*; a chain's left context layers on top — for a window dimension it is
unioned into the partition, for a pivot dimension it becomes the outer
`context`.

- Bare `Expr`/`String` specs default to **window** kind; a top-level `topnames`
  call defaults to **pivot** kind. Everything else is explicit via
  `dimspec(ex; by = extra_grouping_keys, order = ..., kind = :window | :pivot)`.
- A `Tuple` of pairs declares parallel **siblings**: same left context, not in
  each other's context —
  `[:region, (:share => ..., :cum => dimspec(...; order = :date))]`.
- Pure runtime-string chains work for GUI/config paths, and are parsed by the
  UNTRUSTED whitelist grammar (bare identifiers = columns — see below):
  `["County", ["top5d", "topnames(District, TestScr, 5)"], "District"]`.
- **Trusted and untrusted dims interlace freely** in one chain — each entry is
  resolved independently, so host-authored `Expr` dims compose with user-typed
  `dim"..."` dims (the intended TUI pattern):

  ```julia
  [:County,
   :top1 => dim"topnames(District, TestScr, 1)",       # from a user text field
   (:share => :( :TestScr ./ sum(:TestScr) ),          # trusted, host-authored
    :cum   => dimspec(dim"cumsum(EnrlTot)"; order = :TestScr))]
  ```

  The left context applies across the mix: every declared dimension scopes
  everything to its right, so keep continuous dims (z-scores, shares) out of
  the context of later ones — sibling tuples, as above, share a context
  without scoping each other.

## Pipelines

`dim(chain...; hints)` and `pivottable(chain; hints)` (no frame argument) return
reusable callable transforms:

```julia
report = pivottable([:region, :quartile => :( discretize(:sales, quantiles = [.25, .5, .75]) )];
                    hints = AggrHints(:sales => :sum))
df |> report                          # apply
df |> dim([:region, :z => :( (:sales .- mean(:sales)) ./ std(:sales) )]) |> report
(report ∘ dim([...]))(df)             # Base ∘ composes transforms
```

## Untrusted specs (whitelist DSL)

Everything above is the **trusted** DSL: specs are compiled with eval and must
come from an author you trust. For TUI/GUI hosts that accept spec strings from
*end users*, there is a separate sandboxed door — `aggr"..."` / `dim"..."`
(string macros for Julia-side code) and `parseaggr(s)` / `parsedim(s)` (what a
host calls on user input at runtime):

```julia
aggr"sum"                                 # bare registered name ≡ sum(_)
aggr"quantile(_, 0.75)"
aggr"sum(_ * wt) / sum(wt)"               # weighted mean, no registration needed
dim"sales / sum(sales)"                   # share of group
dim"topnames(District, TestScr, 5)"
dim"discretize(TestScr, quantiles=[.25,.5,.75])"

# they drop into every trusted slot:
hints = AggrHints(:TestScr => aggr"sum(_ * EnrlTot) / sum(EnrlTot)")
pivottable(df, [:County, :top5d => dim"topnames(District, TestScr, 5)"]; hints)
dimspec(dim"cumsum(sales)"; order = :date)     # attach ordering / kind
```

Grammar (spreadsheet-flavored, default-deny):

- bare identifier = **column** in every position (`District`, `wt`); `_` = the
  target column (aggr specs only); `:sym` = a Symbol option value
  (`boundedness = :boundedbelow`); literals: numbers, strings, `true`/`false`,
  `[...]` arrays; kwargs in either `f(x, k = v)` or `f(x; k = v)` form.
- arithmetic (`+ - * / ^`) and comparisons are whitelisted with **broadcast
  semantics** — vector⊗scalar and vector⊗vector both work, no dots needed.
- whitelisted operations only: reductions (`sum mean median std var quantile
  minimum maximum count length first last …`), the package verbs (`topnames
  discretize uniqvalue unionall lag lead`), `cumsum`/`cumprod`, and elementwise
  math (`abs log exp sqrt round …`). `listops()` shows the registry; the full
  reference lives in [docs/safe-aggregation-operators.md](docs/safe-aggregation-operators.md)
  and [docs/safe-dimension-operators.md](docs/safe-dimension-operators.md).
- everything else is rejected with a clear error: qualified names (`Core.eval`),
  macros, interpolation, lambdas, indexing, blocks, comprehensions, splats.

There is **no eval anywhere** on this path — specs compile to nested closures
over a registry lookup, so results are plain functions (no `Base.invokelatest`
needed) and safety does not depend on eval guards. Hosts extend the whitelist
deliberately, in code:

```julia
registerop!(:double, x -> 2 .* x)              # dim"double(sales)"
using StatsBase; registerop!(:Weights, Weights)
aggr"mean(_, Weights(EnrlTot))"                # mean is already registered;
                                               # dispatch does the rest

# custom classifier verbs (pivot kind, like topnames) declare which argument
# carries their grouping key(s):
registerop!(:tophalf, (name, measure) -> ...)
registerclassifier!(:tophalf, 1)               # dim"tophalf(District, TestScr)"
```

One wrinkle of "bare identifier = column": `missing`, `pi`, `Inf` are
identifiers, hence column references, not constants.

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

**The rule: `Expr` / `Symbol` / `Function` specs are trusted; plain `String`s
are untrusted** — parsed by the safe whitelist grammar everywhere in the API
(the only exception is the deprecated legacy `CalcPivot(::String)` constructor,
frozen for old configs). Strings are the one spec form that can arrive from a
user's text field by accident, so they can never reach eval.

Trusted `Expr` specs are compiled with `Core.eval(Main, …)` so that
module-qualified names (`StatsBase.mean`) resolve against your loaded packages.
The guards (must be a `:call`, no curly type-params, simple/dotted names only,
reject any `!`) make this safe for **specs you author** but are **not a
sandbox** — the sandbox is the String/untrusted path.

**The colon flip mnemonic** (crossing the boundary): the colon marks the
exception. In trusted Exprs everything is Julia, so *columns* need the colon
(`:( sum(:sales) )`); in untrusted strings everything is a column, so *symbol
literals* need the colon (`"discretize(x, [0], boundedness = :boundedbelow)"`).
