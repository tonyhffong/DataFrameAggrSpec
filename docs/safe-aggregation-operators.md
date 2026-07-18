# Safe Aggregation Operators

The operators available inside **untrusted aggregation specs** — strings parsed
by `parseaggr(s)` / `aggr"..."` and typically typed by an end user in a TUI/GUI.
An aggregation spec reduces a group of rows to **one value** for a target
column.

> **Maintenance rule:** this document must list every aggregation-relevant
> operator in the `SafeOps` registry (`src/safe.jl`). Whenever an operator is
> added to or removed from the shipped registry, update this file (or
> `safe-dimension-operators.md`). The testset *"operator docs stay in sync"*
> in `test/safe.jl` fails otherwise.

## Grammar recap

- bare identifier = **column** (`wt`, `EnrlTot`); **`_`** = the target column
- `:sym` = a Symbol option value; literals: numbers, strings, `true`/`false`,
  `[ ... ]` arrays
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
| `first` | first value in the group | `aggr"first(_)"` |
| `last` | last value in the group | `aggr"last(_)"` |
| `skipmissing` | drop missings before reducing | `aggr"sum(skipmissing(_))"` |
| `uniqvalue` | the single unique non-missing value, else `missing`; kwargs `skipna`, `skipempty` | `aggr"uniqvalue(_)"` |
| `countuniq` | count-distinct: the number of unique non-missing values; kwargs `skipna` (default `true`; `false` counts `missing` as a value), `skipempty` (drop empty strings) | `aggr"countuniq(_)"` |
| `unionall` | flattened union of a vector-of-vectors column | `aggr"unionall(_)"` |
| `strjoinuniq` | unique non-missing values as strings, sorted and joined; `strjoinuniq(_, sep, limit)` with `sep = ","` and `limit = 128` characters (a trailing `…` marks truncation) | `aggr"strjoinuniq(_, \"; \", 64)"` |
| `wmeanfallback` | weighted mean with a CASCADE of candidate weight columns: `wmeanfallback(_, [w1, w2, ...])` tries `w1` first, falls to `w2` if `sum(w1)` is zero or `missing`, and so on; a bare number in the list (e.g. `1`) is a constant weight, so it cancels out to an unweighted mean — a natural last resort. `missing` if every candidate fails | `aggr"wmeanfallback(_, [Size, Suitability, 1])"` |

Reductions apply plain Julia semantics: a column containing `missing` makes
`sum`/`mean`/… return `missing`. Three missing-value tools, by role:
**drop** — `aggr"sum(skipmissing(_))"`; **replace** —
`aggr"sum(coalesce(_, 0))"` (`coalesce` = first non-missing wins, elementwise,
so fallbacks cascade: `coalesce(_, backup, 0)`); **flag** —
`aggr"count(ismissing(_))"`. `coalesce` also patches missing *results*
(`aggr"coalesce(uniqvalue(_), \"mixed\")"`). Defaults must be literals — bare
`missing` is a column name in this grammar, so write `coalesce(x, 0)`, never
`coalesce(x, missing)`.

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
