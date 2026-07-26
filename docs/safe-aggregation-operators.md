# Safe Aggregation Operators

The operators available inside **untrusted aggregation specs** — strings parsed
by `parseaggr(s)` / `aggr"..."` and typically typed by an end user in a TUI/GUI.
An aggregation spec reduces a group of rows to **one value** for a target
column.

> **Maintenance rule:** this document must list every aggregation-relevant
> operator in the `SafeOps` registry (`src/registry.jl`). Whenever an operator is
> added to or removed from the shipped registry, update this file (or
> `safe-dimension-operators.md`). The testset *"operator docs stay in sync"*
> in `test/safe-grammar.jl` fails otherwise.

## The spec must reduce

An aggregation lands on **one value per group**, so the parser rejects a spec
whose shape is row-wise or a loose collection — it would otherwise compile
cleanly and drop a vector (or a lazy `SkipMissing`) into a cell:

```julia
aggr"sum(_)"                    # ✓
aggr"sum(_ * wt) / sum(wt)"     # ✓ a division, but both operands reduce
aggr"where(sum(_) > 100)"       # ✓ labels the GROUP by its total
aggr"cumsum(_)"                 # ✗ one value per ROW — that is a dim spec
aggr"skipmissing(_)"            # ✗ many values — feed it to a reduction
```

The rule is each operator's declared **shape** (`opshape`), propagated through
the expression rather than read off the top-level name: `sum(_ * wt) / sum(wt)`
and `sales / sum(sales)` are both divisions, and only the first reduces.

## Grammar recap

- bare identifier = **column** (`wt`, `EnrlTot`); **`_`** = the target column
- `:sym` = a Symbol option *value*, and only that — a positional `:col` is
  rejected with a pointer to the bare spelling, since the colon means the
  opposite of what it means in a trusted `Expr`. Literals: numbers, strings,
  `true`/`false`, `[ ... ]` arrays (a `[:a, :b]` array of Symbols is fine —
  the restriction is on the argument position, not on Symbols)
- kwargs in either form: `f(x, k = v)` or `f(x; k = v)`
- a bare registered name is shorthand for applying it to the target:
  `aggr"sum"` ≡ `aggr"sum(_)"`
- no dots needed for arithmetic — operators broadcast (see below)
- Boolean conditions combine with `&&`, `||`, `!` — pure elementwise (Kleene:
  `missing` propagates, both sides always evaluated), binding looser than
  comparisons: `aggr"sum(_) > 100 && length(_) > 5"` is a Bool measure, and
  `aggr"where(sum(_) > 100)"` labels it — the labels default to the condition
  text (see the `where` entry in
  [safe-dimension-operators.md](safe-dimension-operators.md))
- a top-level `|> orderby(cols...)` modifier sorts the group's rows before
  the spec runs (see Ordering, below); `|> groupby(...)` is a dimension-spec
  feature and stays rejected at the top level — nest it instead (see
  Composite aggregation, below)

## Reductions

Whole-vector functions that produce the aggregate value.

| Operator | Meaning | Example |
|---|---|---|
| `sum` | sum of values | `aggr"sum"` |
| `prod` | product of values | `aggr"prod(_)"` |
| `mean` | arithmetic mean | `aggr"mean(_)"` |
| `median` | median | `aggr"median(_)"` |
| `std` | standard deviation | `aggr"std(_)"` |
| `var` | variance | `aggr"var(_)"` |
| `quantile` | q-th quantile | `aggr"quantile(_, 0.75)"` |
| `minimum` | smallest value | `aggr"minimum(_)"` |
| `maximum` | largest value | `aggr"maximum(_)"` |
| `extrema` | `(min, max)` tuple | `aggr"extrema(_)"` |
| `length` | group row count | `aggr"length(_)"` |
| `nrow` | group row count (DataFrames.jl-flavored alias for `length`) | `aggr"nrow"` |
| `count` | number of `true`s | `aggr"count(_ > 0)"` |
| `any` | `true` if any value is truthy | `aggr"any(_ > 100)"` |
| `all` | `true` if every value is truthy | `aggr"all(_ > 0)"` |
| `first` | first value in the group | `aggr"first(_)"` |
| `last` | last value in the group | `aggr"last(_)"` |
| `skipmissing` | drop missings before reducing | `aggr"sum(skipmissing(_))"` |
| `uniqvalue` | the single unique non-missing value, else `missing`; kwargs `skipna`, `skipempty` | `aggr"uniqvalue(_)"` |
| `countuniq` | count-distinct: the number of unique non-missing values.<br><br>Kwargs: `skipna` (default `true`; `false` counts `missing` as a value), `skipempty` (drop empty strings) | `aggr"countuniq(_)"` |
| `unionall` | flattened union of a vector-of-vectors column | `aggr"unionall(_)"` |
| `strjoinuniq` | unique non-missing values as strings, sorted and joined.<br><br>`strjoinuniq(_, sep, limit)` with `sep = ","` and `limit = 128` characters (a trailing `…` marks truncation) | `aggr"strjoinuniq(_, \"; \", 64)"` |
| `wmeanfallback` | weighted mean with a CASCADE of candidate weight columns.<br><br>`wmeanfallback(_, [w1, w2, ...])` tries `w1` first, falls to `w2` if `sum(w1)` is zero or `missing`, and so on.<br><br>A bare number in the list (e.g. `1`) is a constant weight, so it cancels out to an unweighted mean — a natural last resort. `missing` if every candidate fails | `aggr"wmeanfallback(_, [Size, Suitability, 1])"` |
| `hhi` | **Herfindahl–Hirschman index**: `sum((x / sum(x))^2)`, the concentration of a market/portfolio/supplier mix. `1/n` (n equal participants) to `1` (one holds everything).<br><br>Takes **sizes, not shares** — the denominator is computed for you. Kwargs: `scale` (`10000` for the antitrust convention, DOJ/FTC thresholds 1500/2500), `skipna` (default `true`; `false` propagates, so any unknown size makes the index unknown).<br><br>`missing` — never a number — when a share is undefined: an empty group, a zero total, or any negative value. Usually two-stage, since concentration is *across a participant* (see below) | `aggr"hhi(sum(_) \|> groupby(store))"` |
| `isuniform` | is this column CONSTANT across the group, strictly? `true` only when every value is equal **and none is `missing`** — an unknown unit is a possibly-different unit.<br><br>Two looser readings stay spellable when you want them: `countuniq(x) == 1` ignores missings entirely, and `countuniq(x, skipna = false) == 1` is exactly Julia's `allequal`.<br><br>Almost always the condition of an `onlyif` | `aggr"onlyif(isuniform(unit), sum(_))"` |

Reductions apply plain Julia semantics: a column containing `missing` makes
`sum`/`mean`/… return `missing`. Four missing-value tools, by role:
**drop** — `aggr"sum(skipmissing(_))"`; **replace** —
`aggr"sum(coalesce(_, 0))"` (`coalesce` = first non-missing wins, elementwise,
so fallbacks cascade: `coalesce(_, backup, 0)`); **flag** —
`aggr"count(ismissing(_))"`; **inject** — `aggr"onlyif(cond, sum(_))"`, which
*produces* a `missing` when `cond` is not true. `coalesce` also patches missing
*results* (`aggr"coalesce(uniqvalue(_), \"mixed\")"`). Defaults must be
literals — bare `missing` is a column name in this grammar, so write
`coalesce(x, 0)`, never `coalesce(x, missing)`.

### Guarding a measure: `onlyif`

`onlyif(cond, x)` is `x` when `cond` is `true` and `missing` otherwise — the
*inject* role above, and Julia's `ifelse(cond, x, missing)` under a name that
survives the trust boundary. Use it when a measure must not be **reported** at
all because another column says it would be meaningless. Totalling across mixed
units is the motivating case:

```julia
aggr"onlyif(isuniform(unit), sum(_))"    # the total, or missing if units differ
aggr"onlyif(nrow > 30, mean(_))"         # suppress means from thin groups
```

Why this matters more than it looks: the obvious arithmetic workaround is
actively wrong. `sum(_) * (countuniq(unit) == 1)` yields **`0`** for a mixed
group — indistinguishable from a genuine zero total — and
`sum(_) + 0 * uniqvalue(unit)` is a `MethodError` as soon as the unit column is
text, which it usually is.

`onlyif` is registered elementwise, so it follows its arguments: a scalar
condition guards an aggregate, a vector condition guards a column
(`dim"onlyif(quality_ok, sales)"` blanks failed rows). A `missing` condition
gives `missing`; a non-Boolean one is an error, as in `where`. It is
deliberately **not** a general `ifelse` — the else-branch is always `missing`,
because the labelling case belongs to `where` and the numeric cases already
have spellings (see `design/expressiveness.md`).

`any`/`all` compose directly with `where` for group-level flags — today's
alternative spellings, `count(cond) > 0` / `count(cond) == length(_)`, still
work but read less directly: `aggr"where(any(_ > 100))"` labels a group
`"any(_ > 100)"` when at least one row clears the threshold.

## Combining reductions with arithmetic

Arithmetic operators are whitelisted with **broadcast semantics**, so ratios of
reductions and elementwise pre-transforms compose freely:

```julia
aggr"sum(_ * wt) / sum(wt)"        # weighted mean (wt = a weight column)
aggr"maximum(_) - minimum(_)"      # range
aggr"count(_ > 100) / length(_)"   # fraction above threshold
aggr"sum(abs(_))"                  # L1 mass
aggr"std(_) / mean(_)"             # coefficient of variation
```

| Operators | Meaning |
|---|---|
| `+` `-` `*` `/` `^` | arithmetic, elementwise when an argument is a column (dotted spellings `.+` `.-` `.*` `./` `.^` are aliases) |
| `==` `!=` `<` `<=` `>` `>=` `≠` `≤` `≥` | comparisons, elementwise; combine with `count` (dotted spellings are aliases) |
| `in` `∈` `∉` | membership test, `x in [1, 2, 5]` (`∈` is a Unicode alias for `in`; `∉` negates) — the item broadcasts elementwise, the collection (literal array or a column) is compared as a WHOLE, not zipped against the item | `aggr"count(_ in [1, 2, 5])"` |

## Ordering (`orderby`)

`first`/`last` (and any future order-sensitive verb) depend on the row order
within the group. The postfix `orderby(cols...)` modifier — the same one dim
specs use (`docs/safe-dimension-operators.md`) — sorts the group's rows by
these keys **before** the reduction runs:

```julia
aggr"first(_) |> orderby(date)"              # earliest value of _
aggr"last(_) |> orderby(date)"               # latest value of _
aggr"first(_) |> orderby(date => :desc)"     # direction, same grammar as dim's orderby
aggr"first(_) |> orderby(region, date)"      # multi-key: date ties broken by region
```

- **Value at an extremum, directly:** `aggr"last(_) |> orderby(t)"` reads as
  "the value of `_` at the maximum `t`" (e.g. price at the latest date) — the
  direct spelling for the common arg-max case. The nested-`groupby` form
  below is for genuine two-stage reductions (aggregating a *measure* per
  subgroup, then reducing again across subgroups), which `orderby` cannot
  express.
- **A no-op on order-insensitive verbs.** `aggr"sum(_) |> orderby(date)"`
  parses and runs fine; sorting the group changes nothing about a sum — the
  same tradeoff `rank`/`denserank`/`tiedrank` already accept from a stray
  `orderby` on the dimension side.
- **Ties** are broken by a stable sort: rows tied on every listed key keep
  their original relative order. Add a tie-breaking key
  (`orderby(date, id)`) for a fully determined answer.
- `groupby` is **not** legal here — a grouped reduction yields one value per
  key, not one value, so it must be nested inside a reduction; see Composite
  aggregation, below.
- `_` is **not** a legal orderby key (`aggr"... |> orderby(_)"` is a
  parse-time error) — order by a real column instead. Rationale:
  `design/expressiveness.md`.

## Composite aggregation (nested `groupby`)

A spec argument of the form `inner |> groupby(keys...)` (`∘` works too) is a
**grouped reduction**: evaluate `inner` once per distinct key combination of
the group's rows and collect the results into a vector — one element per
subgroup, **sorted by key**. Nesting it inside an ordinary reduction gives
two-stage aggregation:

```julia
aggr"mean(sum(_) |> groupby(year))"      # panel data: sum the population
                                         # within each year, then average
                                         # the totals across the years
aggr"maximum(sum(_) |> groupby(year))"   # the best single year
aggr"std(sum(_) |> groupby(year))"       # volatility of the yearly totals
aggr"last(sum(_) |> groupby(year))"      # the LATEST year's total
                                         # (sorted keys: first/last read as
                                         # earliest/latest)
```

- keys may be **computed** columns: `aggr"mean(sum(_) |> groupby(yyyy(t)))"`
  buckets a raw date column by calendar year on the fly
- multiple keys: `groupby(state, year)` (or `groupby([state, year])`)
- the inner spec is a full spec — `aggr"maximum(sum(_ * w) / sum(w) |>
  groupby(year))"` is the best yearly *weighted mean*
- a `missing` key forms its own subgroup (sorted last)
- stages nest:
  `aggr"maximum(mean(sum(_) |> groupby(county)) |> groupby(year))"` — mean
  county total per year, then the best year
- the grouped reduction is a VECTOR, not an aggregate — top-level
  `aggr"sum(_) |> groupby(year)"` is an error (one value per year is not one
  value); wrap it in a reduction. `orderby` cannot attach to a nested
  grouped reduction: subgroup order is the key sort.
- a **top-level** `orderby` still composes with a nested composite reduction,
  though — it pre-sorts the WHOLE group before anything else runs, which
  decides row order *within* every composite subgroup too, so it governs the
  tie-break of an order-sensitive verb nested inside the reduction:

  ```julia
  aggr"last(first(_) |> groupby(year)) |> orderby(t)"
  # within each year, `first(_)` now reads the row with the smallest `t`;
  # `last(...)` then takes the latest year's such value -- "the value of _
  # from the earliest t, within the latest year". Without `orderby(t)`, the
  # inner first(_) falls back to unspecified frame order, same as any
  # order-sensitive verb used bare.
  ```

### Concentration: `hhi` is normally two-stage

`hhi` is the usual reason to reach for the nested form, because concentration
is always *across a participant* — stores, suppliers, customers, issuers —
while the rows in front of you are usually transactions. The inner stage
totals per participant, the outer stage squares and sums the shares:

```julia
# per region: how concentrated are sales across that region's STORES?
agg(df, [:region]; cols = [:sales => aggr"hhi(sum(_) |> groupby(store))"])

aggr"hhi(sum(_) |> groupby(supplier), scale = 10000)"   # antitrust points
```

Writing `aggr"hhi(_)"` instead computes the concentration across the group's
**rows**, which is what you want only when one row *is* one participant (a
pre-aggregated frame). The distinction is not one the engine can make for you:
both are legal, and they answer different questions.

Since `hhi` returns `missing` rather than a number for a degenerate group, a
concentration measure never silently reports `0.0` for an empty group or a
plausible-looking out-of-range figure for a column containing refunds. The
naive spelling does exactly that, which is why the verb exists at all:

```julia
aggr"sum((_ / sum(_))^2)"   # ✗ 0.0 on an empty group, NaN on a zero total,
                            #   and 5.0 (!) on a column with negatives
aggr"hhi(_)"                # ✓ missing in all three cases
```

## Elementwise math (usable inside reductions)

`abs` `log` `log2` `log10` `exp` `sqrt` `round` `floor` `ceil` `min` `max` —
applied elementwise to columns (`aggr"mean(log(_))"`,
`aggr"sum(round(_, digits = 2))"`). `min`/`max` are the *binary* elementwise
forms (`aggr"sum(max(_, 0))"` — clamp then sum); for the group extremum use
`minimum`/`maximum`. `ismissing` and `coalesce` are the elementwise
missing-value tools (see the drop/replace/flag note above).

## Extending the whitelist

Extension is a trusted act done in host code, never via spec strings:

```julia
registerop!(:geomean, x -> exp(mean(log.(x))))   # aggr"geomean(_)"

using StatsBase
registerop!(:Weights, Weights)                   # aggr"mean(_, Weights(wt))"
# `mean` is already registered; method dispatch does the rest.
```

Host-registered operators are deliberately **not** listed here — this document
covers only the shipped defaults.
