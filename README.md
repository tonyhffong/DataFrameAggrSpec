# DataFrameAggrSpec.jl

A UI-free **runtime** DSL for DataFrame *aggregation* and *dimensioning*.
Specifications — supplied as `Symbol`s, `String`s, `Expr`s, spec objects, or
lambdas at runtime — are compiled into functions over a `DataFrame`. Unlike
[DataFramesMeta.jl](https://github.com/JuliaData/DataFramesMeta.jl), whose macros
run at compile time, these specs can arrive from a GUI, a config file, or a
database and be turned into working transforms on the fly.

When developing an intuition about a dataframe, a user constantly needs to adjust and apply
aggregation and pivoting (via static or on-the-fly dimensions) operations.
- What are the "top" categories given a measures? e.g. top scoring schools in a state.
- Within a smaller context, what are the "top" categories then? e.g. top scoring schools within each country
- What if I change the definition of "scores"?
We want to easily change our queries without rewriting many lines of code,
even better if we can change this via a GUI/TUI with one action.

Abstraction of this layer is a natural extension of that need.

At the core of this package there are two operator pillars, one composition rule:

- **Dimensioning** — operators that add NEW columns (existing data is never modified) whose
  values are computed from *sibling rows*: rows sharing the same partition-key
  values (`dim"..."` specs, chains, `dim`).
- **Aggregation** — operators that reduce a group of rows to one value per column
  (`aggr"..."` specs, `AggrHints`, `aggregate`).
- **Composition** — *chains* declare dimensions inline in a pivot list,
  partitioned by their **left context**; a declared dimension is immediately a
  pivot key for what follows (`pivottable`).

## Dimensioning

Dimensioning **adds new columns** to a DataFrame. What makes a *dimension*
different from an ordinary computed column is where its values come from: each
row's value is computed from its **sibling rows** — the rows that share the
same grouping-key values. Your existing data is never modified, only new
columns appear. Group totals, shares of a group, running sums, "top 5" labels,
quantile buckets — these are all dimensions.

Specs are written as strings in a small spreadsheet-flavored grammar
(`dim"..."`): bare identifiers are columns, and only whitelisted operations are
allowed, so these strings are safe to accept from an end user's text field.

```julia
using DataFrameAggrSpec, DataFrames

df = DataFrame(region = ["E", "E", "W", "W", "W"],
               date   = [1, 2, 1, 2, 3],
               sales  = [10.0, 20.0, 5.0, 15.0, 30.0])

# each row's share of its region's sales
dim(df, [:region, :share => dim"sales / sum(sales)"])
#  region  date  sales  share
#  E       1     10.0   0.333…   (10 of E's 30)
#  E       2     20.0   0.667…
#  W       1      5.0   0.1      ( 5 of W's 50)
#  ...

# running total within each region, accumulated in date order
dim(df, [:region, :cum => dim"cumsum(sales) |> orderby(date)"])

# label every row by its REGION's rank on total sales ("1. W", "2. E") --
# the groups are ranked, and each member row receives its group's label
dim(df, [:rank => dim"topnames(region, sales, 2)"])

# bucket each row by which sales quantile it falls in ("1. [0%, 25%)", ...)
dim(df, [:q => dim"quantiles(sales, [.25, .5])"])

# same idea per GROUP: aggregate sales by region first, then bucket the regions
dim(df, [:rq => dim"quantiles(sales, [.5]) |> groupby(region)"])
```

`dim` returns a new frame (the input is untouched); `dim!` adds the columns in
place. Two postfix **modifiers** attach engine options to a spec (intent
first, modifier after — `∘` is the pretty synonym; modifiers are metadata,
never function calls): `spec |> orderby(cols...)` sorts the partition before
an order-sensitive operator runs (`orderby(date => :desc)` for direction), and
`spec |> groupby(keys...)` aggregates the measure at that granularity *first*
so the verb classifies groups instead of rows — the table is never reduced;
each group's label lands on all its member rows. The available operations are
listed in [docs/safe-dimension-operators.md](docs/safe-dimension-operators.md).

### Chains: dimensions become pivot keys

The astute reader would have noticed that the `dim` always takes a vector in
the second argument. The vector is a **chain** — an ordered pivot list. `Symbol`s
name existing columns; `name => spec` declares a new dimension. The rule that
makes chains compose: **a dimension's grouping is everything to its left in
the chain** (its *left context*), and once declared, the dimension is
immediately usable as a key by everything to its right:

```julia
chain = [:County, #existing column, Country
         :top5d  => dim"topnames(District, TestScr, 5)",   # per County, rank Districts
         :District,
         :scoreq => dim"discretize(TestScr, quantiles = [.25, .5, .75])"]
                    # row-level quartile within [:County, :top5d, :District]

df2 = dim(df, chain)                 # just add the columns
out = pivottable(df, chain; hints)   # or: materialize dims, then aggregate one
                                     # row per key combination (hints: see below)
```
In the above example, by removing the first element `:County` the result becomes a state level
statistics. 

More chain forms:

- **A chain declares pivot levels only** — every entry joins the left context
  and the key list. Side measures (shares, cumsums, z-scores) are deliberately
  *not expressible inside a chain*: they would poison the grouping of
  everything to their right. Compute them as **separate statements**, each
  rebuilding its context explicitly:

  ```julia
  df |> dim([:region, :share => dim"sales / sum(sales)"],
            [:region, :cum   => dim"cumsum(sales) |> orderby(date)"]) |>
        pivottable([:region, :bucket => dim"quantiles(sales, [.5])"]; hints)
  ```

  The syntax forces the distinction: if it's in a chain, it's a key; if it's a
  measure, it gets its own statement.
- Pure runtime-string chains work for GUI/config paths:
  `["County", ["top5d", "topnames(District, TestScr, 5)"], "District"]`.

## Aggregation

Aggregation **reduces a group of rows to one value per column**. Specs use the
same safe grammar (`aggr"..."`), with one addition: **`_` stands for the target
column** — the column being aggregated — so one spec can be reused across many
columns:

```julia
aggr"sum"                        # bare registered name ≡ sum(_)
aggr"quantile(_, 0.75)"
aggr"sum(_ * wt) / sum(wt)"      # weighted mean (wt = a weight column)
aggr"strjoinuniq(_)"             # unique values joined into a display string
```

`AggrHints` says how to aggregate each column, resolved by column name first,
then element type (by subtyping), then a default (`Real → sum`, otherwise the
single unique value):

```julia
hints = AggrHints(:TestScr => aggr"sum(_ * EnrlTot) / sum(EnrlTot)",
                  AbstractString => aggr"uniqvalue")

aggregate(df, [:County]; hints)      # one row per County, all other cols reduced
pivottable(df, chain; hints)         # chain dims + aggregate over all chain keys
```

The available reductions are listed in
[docs/safe-aggregation-operators.md](docs/safe-aggregation-operators.md).

## Pipelines

`dim(chain...; hints)` and `pivottable(chain; hints)` (no frame argument) return
reusable callable transforms:

```julia
report = pivottable([:region, :quartile => dim"discretize(sales, quantiles = [.25, .5, .75])"];
                    hints = AggrHints(:sales => aggr"sum"))
df |> report                          # apply
df |> dim([:region, :z => dim"(sales - mean(sales)) / std(sales)"]) |> report
(report ∘ dim([...]))(df)             # Base ∘ composes transforms
```

## The safe grammar, and extending it

The string specs above are parsed by a **whitelist grammar with no eval
anywhere** — safe to wire to an end user's text field, which is exactly what a
TUI/GUI host does at runtime via `parseaggr(s)` / `parsedim(s)` (the string
macros are compile-time sugar for the same thing).

- bare identifier = **column** in every position (`District`, `wt`); `_` = the
  target column (aggr specs only); `:sym` = a Symbol option value
  (`boundedness = :boundedbelow`); literals: numbers, strings, `true`/`false`,
  `[...]` arrays; kwargs in either `f(x, k = v)` or `f(x; k = v)` form.
- arithmetic (`+ - * / ^`) and comparisons are whitelisted with **broadcast
  semantics** — vector⊗scalar and vector⊗vector both work, no dots needed.
- whitelisted operations only: reductions (`sum mean median std var quantile
  minimum maximum count length first last …`), the package verbs (`topnames
  discretize quantiles uniqvalue unionall strjoinuniq lag lead`),
  `cumsum`/`cumprod`, and elementwise math (`abs log exp sqrt round …`).
  `listops()` shows the registry; the full reference lives in the two
  [docs/](docs/) operator documents.
- top-level `spec ∘ modifier(...)` / `spec |> modifier(...)` attaches engine
  **modifiers** — `orderby(cols...)` (window ordering) and `groupby(keys...)`
  (pivot grouping: aggregate the measure at this granularity first) — peeled
  structurally as metadata, never called (dim specs only; the names are
  reserved). `groupby` is what makes any verb — including host-registered
  ones — pivot-kind, with zero per-verb registration.
- everything else is rejected with a clear error: qualified names (`Core.eval`),
  macros, interpolation, lambdas, indexing, blocks, comprehensions, splats.
- one wrinkle of "bare identifier = column": `missing`, `pi`, `Inf` are
  identifiers, hence column references, not constants.

Hosts extend the whitelist deliberately, in code:

```julia
registerop!(:double, x -> 2 .* x)              # dim"double(sales)"
using StatsBase; registerop!(:Weights, Weights)
aggr"mean(_, Weights(EnrlTot))"                # mean is already registered;
                                               # dispatch does the rest

# custom classifier verbs (they label groups, like topnames) declare which
# argument carries their grouping key(s):
registerop!(:tophalf, (name, measure) -> ...)
registerclassifier!(:tophalf, 1)               # dim"tophalf(District, TestScr)"
```

## Advanced: trusted Expr specs and the two dimension kinds

Everything below is for package developers who need to go beyond the safe
operators — full Julia inside a spec.

**Trusted specs are `Expr`s** (also bare `Symbol`s and functions — forms that
cannot arrive from a text field). They are compiled with `Core.eval(Main, …)`,
so module-qualified names resolve against *your* loaded packages. Quoted
symbols mark columns (`:sales`), `:_` marks the aggregation target, and
`^(:sym)` escapes a symbol from column substitution:

```julia
using StatsBase

f = liftAggrSpecToFunc(:TestScr, :( StatsBase.mean(:_, StatsBase.Weights(:EnrlTot)) ))
Base.invokelatest(f, df)     # raw lifted functions live at a fresh world-age;
                             # aggregate / dim / pivottable handle this internally

liftAggrSpecToFunc(:TestScr, :sum)                # bare Symbol → sum(df.TestScr)
hints = AggrHints(:TestScr => :( mean(:_, Weights(:EnrlTot)) ))
dim(df, [:region, :share => :( :sales ./ sum(:sales) )])
:( discretize(:x, [0, 1]; boundedness = ^(:boundedbelow)) )
```

Trusted and safe specs interlace freely — each chain entry is resolved
independently, so host-authored `Expr` dims compose with user-typed `dim"..."`
dims (the intended TUI pattern), and measure statements mix trust the same way:

```julia
dim(df, [:County, :top1 => dim"topnames(District, TestScr, 1)"],   # user-typed key
        [:County, :top1, :share => :( :TestScr ./ sum(:TestScr) )], # trusted measure
        [:County, :top1, :cum => dim"cumsum(EnrlTot) |> orderby(TestScr)"])
```

**The two dimension kinds.** Under the hood every dimension evaluates in one of
two ways, deciding what a column reference binds to (picked by inference, or
forced with `dimspec(...; kind = ...)`); the kinds are semantics, not types you
construct:

- **window** — a column binds to the partition's row-level subvector (sorted by
  `order` if given). The spec result is a scalar (broadcast to the partition)
  or a partition-length vector. Covers group totals, shares, z-scores,
  `cumsum`/`lag`/`lead`/ranks. Bare specs default to this kind.
- **pivot** — classifies *groups*: within each context partition, rows are
  grouped by the dimension's `by` keys, the referenced columns are aggregated
  per group (via `AggrHints`), the spec runs over those per-group vectors, and
  each group's label is broadcast back to its member rows. This is the home of
  `topnames` / `quantiles` / `discretize`-over-group-sums. Classifier verbs infer
  this kind (see `registerclassifier!`); force it with `dimspec(...; kind = :pivot)`.

`dimspec(ex; by = extra_grouping_keys, order = ..., kind = :window | :pivot)`
is the full options carrier — the Julia-side equivalent of the in-string
`|> orderby(...)` / `|> groupby(...)` modifiers (specifying the same option
both ways is an error, not a precedence game). **The `by` rule**: `by` always
means the grouping
keys a dimension declares *itself*; a chain's left context layers on top — for
a window dimension it is unioned into the partition, for a pivot dimension it
becomes the outer context.

`order` accepts `:col`, `:col => :asc/:desc`, vectors of those, and string
forms (`":date => :desc"`). Results are scattered back through the inverse
permutation, so output stays aligned with the original rows.

(`aggregate` is the primitive — `pivottable` ≡ materialize the chain's
dimensions, then `aggregate` over the full key list.)

## Presentation verbs

- **`discretize(x, breaks; …)`** / `discretize(x; quantiles/ngroups)` — bin a
  numeric vector into a `CategoricalArray` of human-readable labels
  (`"2. [0,1)"`, `"3. 1 ≤ x < 2"`, `"5. 3+"`), with rank prefixes, compact
  intervals, boundedness modes, and quantile-based auto-breaks.
- **`topnames(name, measure, n; …)`** — top-N ranking with tie handling
  (`dense`), an `"Others"` bucket, absolute-value mode, parenthesised negatives.
- **`quantiles(measure, qs; …)`** — quantile-bucket labels
  (`"1. [0%, 25%)"`), for groups or individual rows.
- **`strjoinuniq(x, sep, limit)`** — unique values as a sorted, joined,
  length-capped display string.
- **`lag(v, n; default)` / `lead(v, n; default)`** — shifted siblings, for
  order-based window dimensions.
- **`uniqvalue`**, **`unionall`** — the single unique value / flattened union.

## Trust boundary

**The rule: `Expr` / `Symbol` / `Function` specs are trusted; plain `String`s
are untrusted** — parsed by the safe whitelist grammar everywhere in the API, with
no exceptions. Strings are the one spec form that can arrive from a user's text
field by accident, so they can never reach eval.

Trusted `Expr` specs are compiled with `Core.eval(Main, …)` so that
module-qualified names (`StatsBase.mean`) resolve against your loaded packages.
The guards (must be a `:call`, no curly type-params, simple/dotted names only,
reject any `!`) make this safe for **specs you author** but are **not a
sandbox** — the sandbox is the String/untrusted path.

**The colon flip mnemonic** (crossing the boundary): the colon marks the
exception. In trusted Exprs everything is Julia, so *columns* need the colon
(`:( sum(:sales) )`); in untrusted strings everything is a column, so *symbol
literals* need the colon (`"discretize(x, [0], boundedness = :boundedbelow)"`).
