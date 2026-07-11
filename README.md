# DataFrameAggrSpec.jl

A small, UI-free **runtime** DataFrame-aggregation DSL. It compiles aggregation
*specifications* — supplied as `Symbol`s, `Expr`s, or lambdas at runtime — into
functions over a `DataFrame`. Unlike [DataFramesMeta.jl](https://github.com/JuliaData/DataFramesMeta.jl),
whose macros run at compile time, these specs can arrive from a GUI, a config file,
or a database and be turned into working aggregators on the fly.

Extracted from [TermWin.jl](../TermWin), which uses it to power its interactive
DataFrame tree/pivot viewer.

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
`Base.invokelatest`.

## CalcPivot — computed pivot columns

```julia
# top-5 districts by test score, evaluated per (grouped) row
cp = CalcPivot(:( topnames(:District, :TestScr, 5) ), [:District])
f  = liftCalcPivotToFunc(cp.spec, cp.by)
```

`CalcPivot` runs a nested split-apply-combine: it groups by `by`, aggregates the
columns the spec depends on (via `liftAggrSpecToFunc`), then evaluates the spec over
the aggregated groups.

## Presentation verbs

- **`discretize(x, breaks; …)`** / `discretize(x; ngroups=4)` — bin a numeric vector
  into a `CategoricalArray` of human-readable labels (`"2. [0,1)"`, `"3. 1 ≤ x < 2"`,
  `"5. 3+"`), with rank prefixes, compact intervals, boundedness modes, and
  quantile-based auto-breaks.
- **`topnames(name, measure, n; …)`** — top-N ranking with tie handling
  (`dense`), an `"Others"` bucket, absolute-value mode, and parenthesised negatives.

## Trust boundary

General aggregation-spec expressions are compiled with `Core.eval(Main, …)` so that
module-qualified names (`StatsBase.mean`) resolve against your loaded packages. The
guards (must be a `:call`, no curly type-params, simple/dotted names only, reject any
`!`) make this safe for **specs you author** (config you control) but are **not a
sandbox** — do not feed untrusted user input to these functions.
