# DataFrameAggrSpec.jl

DataFrameAggrSpec specializes in only two things: creating dimensions and creating aggregations (often based on those new
dimensions) from DataFrames. Its design focuses on composability, both internally within this package
(you will get a lot of mileage just using it) and with other packages. Furthermore, it has a "safe" parser to handle instructions
from untrusted input (e.g. TUI/GUI text input), so package developers with user interface in mind can leverage the
DSL defined here safely.

## Contents

- [Introduction](#introduction)
- [Dimensioning](#dimensioning)
  - [Chains: dimensions become pivot keys](#chains-dimensions-become-pivot-keys)
  - [The two dimension kinds](#the-two-dimension-kinds)
- [Aggregation](#aggregation)
  - [Composite aggregation](#composite-aggregation)
- [Pipelines](#pipelines)
- [Untrusted input: the trust boundary](#untrusted-input-the-trust-boundary)
  - [The rule, and the colon flip](#the-rule-and-the-colon-flip)
  - [Trusted Expr specs (advanced)](#trusted-expr-specs-advanced)
- [The safe grammar](#the-safe-grammar)
  - [Writing a spec](#writing-a-spec)
  - [What a host gets](#what-a-host-gets)
- [Operator reference](#operator-reference)
- [Design notes](#design-notes)

## Introduction

A UI-free **runtime** DSL for DataFrame *aggregation* and *dimensioning*. Other packages using it can
register new operators for their own use.

Specifications — supplied as `Symbol`s, `String`s, `Expr`s, spec objects, or
lambdas at runtime — are compiled into functions over a `DataFrame`. Unlike
[DataFramesMeta.jl](https://github.com/JuliaData/DataFramesMeta.jl), whose macros
run at compile time, these specs can arrive from a GUI, a config file, or a
database and be turned into working transforms on the fly. The motivation 
is coming from data analytics.
When developing an intuition about a dataset, a user constantly needs to adjust and apply
different aggregation and pivoting (via static or on-the-fly dimensions) operations. For example, one may
ask:
- What are the "top" categories given a measure? e.g. top scoring schools in a state.
- Which stores have the highest profit margin, this year, this quarter? If I break down by region what is
the answer? If I break down by municipality what is the answer?
- What if I change the definition of "profit margin"?

We want to easily change our queries without rewiring many lines of code, 
scattered across some distances when written in typical query languages.

The core design philosophy is thus "changing one small step in an analysis should only change 
the code in a small, local and expressive way".

At the core of this package there are two operator pillars, one composition rule:

- **Dimensioning** — operators that add NEW columns (existing data is never modified) whose
  values are computed from *sibling rows*: rows sharing the same partition-key
  values (`dim"..."` specs, chains, `dim`).
- **Aggregation** — operators that reduce a group of rows to one value per column
  (`aggr"..."` specs, `AggrHints`, `agg`).
- **Composition** — *chains* declare dimensions inline in a pivot list,
  partitioned by their **left context**; a declared dimension is immediately a
  pivot key for what follows. The same chain drives both verbs: `dim(df, chain)`
  ADDS its columns, `agg(df, chain)` groups by them and reduces.

<p align="center">
  <img src="docs/assets/dim-vs-agg.svg" width="680"
       alt="dim adds a sibling-computed column to every row; agg reduces to one row per key">
</p>

## Dimensioning

Dimensioning **adds new columns** to a DataFrame. What makes a *dimension*
different from an ordinary computed column is where its values come from: each
row's value is computed from its **sibling rows** — the rows that share the
same grouping-key values. Your existing data is never modified, only new
columns appear. Group totals, shares of a group, running sums, "top 5" labels,
quantile buckets — these are all dimensions.

**Motivation**: dimensions are natural pivot keys to look at a dataset. An easy way to define new
dimensions lets users see the same dataset with a new lens quickly. Furthermore, dimensions also
allow users to get answers *locally* from a specific segmentation (a bunch of rows sharing the same
attributes).

Dimension specifications are written as strings in a small spreadsheet-flavored grammar
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

# running total within each region, accumulated in date order. Note the "∘" usage
dim(df, [:region, :cum => dim"cumsum(sales) ∘ orderby(date)"])

# label every row by its REGION's rank on total sales ("1. W", "2. E") --
# the groups are ranked, and each member row receives its group's label
dim(df, [:rank => dim"topnames(region, sales, 2)"])

# bucket each row by which sales quantile it falls in ("1. [0%, 25%)", ...)
dim(df, [:q => dim"quantiles(sales, [.25, .5])"])

# same idea per GROUP: aggregate sales by region first, then bucket the regions
# note that we use "|>" here instead of "∘". They are equivalent in this context.
dim(df, [:rq => dim"quantiles(sales, [.5]) |> groupby(region)"])

# flag rows by a condition -- the label IS the condition, so the new column
# reads as its own definition ("sales > 12" / "Not sales > 12")
dim(df, [:big => dim"where(sales > 12)"])
```

Notice what the classifying verbs emit: not codes, but **presentation-ready
labels** — `"1. W"`, `"2. [25%, 50%)"`, `"3. 1 ≤ x < 2"`, an `"Others"`
bucket for the unranked tail. The fixed-width rank prefix is deliberate: it
makes *lexical* order the intended order, so the labels sort correctly as
`CategoricalArray` levels, in a group-by, and in a rendered table, with no
custom comparator anywhere. A dimension is meant to be looked at as well as
grouped by.

`dim` returns a new frame (the input is untouched); `dim!` adds the columns in
place. Two postfix **modifiers** attach engine options to an intention spec 
(our design favors putting intent first, modifier after).
Here `spec |> orderby(cols...)` sorts the partition before
an order-sensitive operator runs (`orderby(date => :desc)` for direction), and
`spec |> groupby(keys...)` aggregates the measure at that `keys...` granularity *first*
for all the rows that belong to the same keys
so the verb classifies all these rows in one go — the table is never reduced;
each group's label lands on all its member rows. When both appear, `orderby`
sorts the *groups* (by keys or their aggregates) before the verb runs —
the Pareto idiom:

```julia
# running total over REGIONS, largest region first: every row carries the
# cumulative sales of its region's "Pareto position"
dim(df, [:cum => dim"cumsum(sales) |> groupby(region) |> orderby(sales => :desc)"])
```

> **Coming from SQL window functions?** `OVER (PARTITION BY region ORDER BY
> date)` does **not** translate to `|> groupby(region) |> orderby(date)` — that
> form *runs*, but computes something else (it aggregates sales per region
> first, then cumsums over the region totals). The window partition is the
> **chain's left context**:
>
> ```julia
> dim(df, [:region, :cum => dim"cumsum(sales) |> orderby(date)"])   # per-region running total
> ```
>
> `|> partitionby(...)`, `|> over(...)` and `|> within(...)` are rejected with
> this pointer, precisely so nobody "corrects" them to `groupby`.

Modifier textual order carries no meaning (`groupby |> orderby` ≡
`orderby |> groupby` — they are options, like keyword arguments; see
[design/compound-modifiers.md](design/compound-modifiers.md) for why that
has to be true). The available operations are
listed in [docs/safe-dimension-operators.md](docs/safe-dimension-operators.md).

`groupby`'s keys may be **computed**, not just bare columns —
`dim"cumsum(sales) |> groupby(yyyymm(date))"` buckets by calendar month
instead of an existing column, mixable with plain columns
(`groupby(region, yyyymm(date))`); the `[col, ...]` array spelling stays
plain-column-only.

**Why two spellings for the same separator?** `spec ∘ orderby(date)` and
`spec |> orderby(date)` mean exactly the same thing, and the redundancy is
deliberate. `∘` is the more truthful glyph: a modifier is not a pipeline stage
the data flows through — nothing is ever called — it *composes* with the spec,
the way `g ∘ f` builds a new function without running either. It is also the
more succinct on screen. But these specs arrive from TUI text fields and config
files, where `\circ`-tab completion doesn't exist and a Unicode glyph is a real
barrier — so the ASCII `|>` is accepted everywhere with identical meaning.
Whichever you type, read it as "…with this engine option", not "pipe the data
into `orderby`".

One caveat both glyphs share: they parse with Julia's precedence — `∘` binds
as tightly as `*`, and `|>` tighter than a comparison — so when a spec's top
level is arithmetic or a comparison, parenthesize it before attaching the
modifier: `(sales - lag(sales)) |> orderby(date)`. The unparenthesized form is
caught at parse time with the same advice.

### Chains: dimensions become pivot keys

The astute reader would have noticed that the `dim` always takes a vector in
the second argument. The vector is a **chain** — an ordered pivot list. `Symbol`s
name existing columns; `name => spec` declares a new dimension. The rule that
makes chains compose: **a dimension's grouping is everything to its left in
the chain** (its *left context*), and once declared, the dimension is
immediately usable as a key by everything to its right:

```julia
chain = [:County, # existing column, County
         :top5d  => dim"topnames(District, TestScr, 5)",   # per County, rank Districts
         :District,
         :scoreq => dim"discretize(TestScr, quantiles = [.25, .5, .75])"]
                    # row-level quartile within [:County, :top5d, :District]

df2 = dim(df, chain)          # just add the columns
out = agg(df, chain; hints)   # or: group by the chain, one row per key
                              # combination, other cols reduced (hints: see below)
```

<p align="center">
  <img src="docs/assets/chain-context.svg" width="700"
       alt="each dimension in a chain is grouped by its left context and immediately becomes a pivot key for everything to its right">
</p>

In the above example, by removing the first element `:County` the result becomes a state level
statistics. Intuitively, this makes sense. When we remove some of the "left context" the universe of rows
for each key combo to the left are larger so we would be ranking from a larger pool.

More generally, the dynamically generated dimension link is also **portable**. We can move a link up and down
the chain, compose with other dimension links, and they will always obey the
left context rule and act accordingly. Composition includes feeding one
classifier's output to another: dimension labels are `CategoricalArray`s, and
a classifier's name column accepts them (values are stringified as needed). If we want to discretize first and then find the top districts within each 
quantiles, we just swap them. That's it.

More chain forms:

- **A chain declares pivot levels only** — every entry joins the left context
  and the key list. Side measures (shares, cumsums, z-scores) are deliberately
  *not expressible inside a chain*: they would poison the grouping of
  everything to their right. Compute them as **separate statements**, each
  rebuilding its context explicitly:

  ```julia
  df |> dim([:region, :share => dim"sales / sum(sales)"],
            [:region, :cum   => dim"cumsum(sales) |> orderby(date)"]
           ) |> agg([:region, :bucket => dim"quantiles(sales, [.5])"]; hints)
  ```

  The syntax forces the distinction: if it's in a chain, it's a key; if it's a
  measure, it gets its own statement.
- Pure runtime-string chains work for GUI/config paths:
  `["County", ["top5d", "topnames(District, TestScr, 5)"], "District"]`.

### The two dimension kinds

Under the hood every dimension evaluates in one of
two ways, deciding what a column reference binds to (picked by inference, or
forced with `dimspec(...; kind = ...)`); the kinds are semantics, not types you
construct:

- **window** — a column binds to the partition's row-level subvector (sorted by
  `order` if given). The spec result is a scalar (broadcast to the partition)
  or a partition-length vector. Covers group totals, shares, z-scores,
  `cumsum`/`lag`/`lead`/`rank`. Bare specs default to this kind.
- **pivot** — classifies *groups*: within each context partition, rows are
  grouped by the dimension's `by` keys, the referenced columns are aggregated
  per group (via `AggrHints`), the spec runs over those per-group vectors, and
  each group's label is broadcast back to its member rows. This is the home of
  `topnames` / `quantiles` / `discretize`-over-group-sums. Classifier verbs infer
  this kind (see `registerclassifier!`); force it with `dimspec(...; kind = :pivot)`.
  An `order` (in-string `|> orderby(...)`) sorts the *groups* — by keys or
  their aggregates — before the spec runs, for cumulative/Pareto shapes.

<p align="center">
  <img src="docs/assets/window-vs-pivot.svg" width="700"
       alt="window kind computes each row's value from its ordered sibling rows (the orderby modifier); pivot kind aggregates groups, classifies them, and broadcasts each label to the group's member rows (the groupby modifier)">
</p>

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

(`agg` ≡ materialize the chain's declared dimensions, then group by the full key
list and reduce — a pure-Symbol chain is just a plain group-by.)

## Aggregation

Aggregation **reduces a group of rows to one value per column**. The main entry
point is `agg`, which groups by a chain (keys existing or derived) and reduces
the remaining columns:

```julia
hints = AggrHints(:TestScr => aggr"sum(_ * EnrlTot) / sum(EnrlTot)",
                  AbstractString => aggr"uniqvalue")

agg(df, [:County]; hints)            # one row per County, all other cols reduced
agg(df, chain; hints)                # group by chain keys (existing OR computed)
```

The reductions themselves use the same safe grammar (`aggr"..."`), with one
addition: **`_` stands for the target column** — the column being aggregated —
so one spec can be reused across many columns:

```julia
aggr"sum"                        # bare registered name ≡ sum(_)
aggr"quantile(_, 0.75)"
aggr"sum(_ * wt) / sum(wt)"      # weighted mean (wt = a weight column)
aggr"strjoinuniq(_)"             # unique values joined into a display string
```

`AggrHints` says how to aggregate each column, resolved by column name first,
then element type (by subtyping), then a default (`Real → sum`, otherwise the
single unique value). `agg` takes a **chain** also, exactly like `dim`:
bare-symbol entries are existing key columns and `name => spec` entries are
on-the-fly dimensions materialized before grouping — so `agg(df, [:County])` is
a plain group-by and `agg(df, [:region, :bucket => dim"quantiles(sales, [.5])"])`
groups by a derived bucket, with no separate "pivot" verb to remember.

`cols =` selects **and names** the reductions (default: every non-key column
via hints). Each entry is one output column, and the same source column may
appear any number of times under distinct names:

```julia
agg(df, [:County]; cols = [
    :EnrlTot,                                  # hints-resolved, output :EnrlTot
    :TestScr => aggr"maximum(_)",              # inline spec, output stays :TestScr
    :TestScr => aggr"mean(_)" => :scr_avg,     # named measure
    :TestScr => aggr"std(_)"  => :scr_sd,      # ... same column again
])
```

The spec slot takes anything a hint value takes — a safe `aggr"..."` / plain
String, or a trusted Symbol / Expr / Function — and `_` binds to the source
column on the left. Output columns appear in entry order; duplicate output
names and collisions with chain keys are errors.

`allbut =` is the mirror image of `cols`: keep the default hints-driven
reduction for every non-key column *except* the listed ones (the two are
mutually exclusive — both are selection modes). It is the quickest way to
shed a helper column, e.g. `agg(df, chain; hints, allbut = [:gap])` after a
sessionization chain built from `gap`.

Selecting no measures at all — `cols = []`, or an `allbut` that excludes
every remaining column — reduces `agg` to the distinct key combinations
(`SELECT DISTINCT` in SQL terms), one row per group:

```julia
agg(df, [:region]; cols = [])   # every distinct region, no measure columns
```

### Composite aggregation

Panel data often needs **two-stage** reductions: with population snapshots by
district over several years, "the average population" should sum the districts
*within* each year first, then average the yearly totals — a single `mean` or
`sum` over all rows computes something else entirely. A nested
`|> groupby(keys...)` expresses the first stage inside the spec:

```julia
aggr"mean(sum(_) |> groupby(year))"      # sum within each year, then average
aggr"last(sum(_) |> groupby(year))"      # the latest year's total
```

<p align="center">
  <img src="docs/assets/composite-aggregation.svg" width="760"
       alt="the outer chain gives a cohort its meaning and runs the spec once per cohort; within one cohort, the optional nested groupby stages the rows before the outer reduction runs">
</p>

The nested part evaluates the inner spec once per key combination and hands
the key-sorted results to the outer reduction. Keys may be computed
(`groupby(yyyy(t))`), and stages nest. 

The available reductions — and the full rules for composite aggregation — are
listed in
[docs/safe-aggregation-operators.md](docs/safe-aggregation-operators.md).

## Pipelines

`dim(chain...; hints)` and `agg(chain; hints, cols)` (no frame argument) return
reusable callable transforms — `cols` measure entries ride along:

```julia
report = agg([:region, :quartile => dim"discretize(sales, quantiles = [.25, .5, .75])"];
             hints = AggrHints(:sales => aggr"sum"))
df |> report                          # apply
df |> dim([:region, :z => dim"(sales - mean(sales)) / std(sales)"]) |> report
(report ∘ dim([...]))(df)             # Base ∘ composes transforms
```

## Untrusted input: the trust boundary

Every `dim"..."` and `aggr"..."` above was a **string** — and strings are the
one spec form that can arrive from an end user's text field by accident. That
is the situation this section is about, and it is the reason the package
exists in this shape.

This section states the rule and covers the *trusted* side. The untrusted side
is large enough to be its own subsystem and has its own section:
[The safe grammar](#the-safe-grammar).

### The rule, and the colon flip

**`Expr` / `Symbol` / `Function` specs are trusted; plain `String`s are
untrusted** — parsed by the safe whitelist grammar everywhere in the API,
with no exceptions: chains, dimension constructors, `dimspec`, `AggrHints`,
`liftAggrSpecToFunc`. A String can never reach `eval`.

Trusted `Expr` specs are compiled with `Core.eval(Main, …)` so that
module-qualified names (`StatsBase.mean`) resolve against your loaded
packages. The guards (must be a `:call`, no curly type-params, simple/dotted
names only, reject any `!`) make this safe for **specs you author** but are
**not a sandbox** — the sandbox is the String/untrusted path.

Trust is decided per spec and never escalates: a user-typed `dim"..."` sitting
next to a host-authored `Expr` in the same chain gains nothing from the
neighbour ([design/composition-rules.md](design/composition-rules.md), R5).

**The colon flip mnemonic** (crossing the boundary): the colon marks the
exception. In trusted Exprs everything is Julia, so *columns* need the colon
(`:( sum(:sales) )`); in untrusted strings everything is a column, so *symbol
literals* need the colon (`"discretize(x, [0], boundedness = :boundedbelow)"`).

### Trusted Expr specs (advanced)

The other side of the boundary, for package developers who need to go beyond
the safe operators — full Julia inside a spec.

Trusted specs are `Expr`s (also bare `Symbol`s and functions — forms that
cannot arrive from a text field). Quoted symbols mark columns (`:sales`),
`:_` marks the aggregation target, and `^(:sym)` escapes a symbol from column
substitution:

```julia
using StatsBase

f = liftAggrSpecToFunc(:TestScr, :( StatsBase.mean(:_, StatsBase.Weights(:EnrlTot)) ))
Base.invokelatest(f, df)     # raw lifted functions live at a fresh world-age;
                             # agg / dim handle this internally

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

## The safe grammar

Strings are the one spec form that can arrive from an end user's text field, so
the untrusted path is a subsystem in its own right: a **whitelist grammar with
no eval anywhere**, safe to wire straight to a text field via `parseaggr(s)` /
`parsedim(s)` (the string macros are compile-time sugar for the same call).
Only whitelisted operations exist, the result is an ordinary closure at the
current world age, and it is cheap enough to re-parse on every keystroke.

### Writing a spec

Nearly everything follows from one rule — **a bare identifier is a column**:

```julia
dim"cumsum(sales) |> orderby(date)"                        # columns are bare words
aggr"sum(_ * wt) / sum(wt)"                                # `_` = the target column (aggr only)
dim"discretize(x, [0, 10], boundedness = :boundedbelow)"   # `:sym` = an option VALUE
```

- arithmetic and comparisons **broadcast** — no dots needed. Conditions combine
  with `&& || !` (pure, elementwise, `missing`-propagating) and bind looser than
  comparisons, so `sales > 10 && sales < 20` needs no parens.
- a top-level `∘` / `|>` attaches an engine **modifier**, `orderby(cols...)` or
  `groupby(keys...)` — metadata, never called. A *nested* `inner |> groupby(...)`
  is the different thing above: [composite aggregation](#composite-aggregation).
- everything else is rejected: qualified names, macros, interpolation, lambdas,
  indexing, blocks, comprehensions, splats.
- one wrinkle of "bare identifier = column" — `missing`, `pi` and `Inf` are
  identifiers, hence *column references*, not constants. Missing-value defaults
  are literals: `coalesce(x, 0)`, never `coalesce(x, missing)`.

`listops()` shows the live vocabulary; the two [docs/](docs/) operator documents
describe every entry.

### What a host gets

**Mistakes caught at parse time, not inside a group-by** — wrong arity, an
unknown keyword, and a spec whose *shape* cannot be what it is being used as
(`aggr"cumsum(_)"` returns one value per row; `dim"mean(x) |> groupby(g)"`
collapses the very groups it is meant to label).

**Errors written for the person typing**, every one held to "say what to type
instead" and quoting the spec it came from:

| You typed | It says |
|---|---|
| `maen(_)` | did you mean `mean`? — OSA repair, so transpositions are one edit |
| `avg(_)`, `nunique(x)`, `ROW_NUMBER()` | not registered here — use `mean(x)` / `countuniq(x)` / `ordinalrank(x)`. SQL, dplyr, pandas and Excel spellings are redirected by name; they are **not** aliases, so the spec still fails |
| `cumsum(:qty)` | `:qty` is a Symbol literal, only an option *value* here — a column is a bare word, without the colon |
| `cumsum(x) \|> partitionby(region)` | a window partition is the chain's **left context**, not a modifier — and pointedly *not* `groupby`, which aggregates-then-classifies |

Pass `columns = propertynames(df)` to `parseaggr`/`parsedim` and column
references get the same treatment (`checkcols` is the standalone form).

**A machine channel beside the prose.** Every rejection is a `SpecError`
carrying `code`, `token`, a drop-in `fix` and the `span` it replaces — enough
for a linter, an editor quick-fix or an agent repairing its own output, with no
regex over English. `sprint(showerror, e)` still prints exactly what a human
sees.

**Proactive suggestion**, for before and while typing: `spec_templates` proposes
whole starter specs narrowed to the frame (and guaranteed to run on it),
`spec_vocabulary` drives completion, and `specsummary` echoes back what a spec
means.

**Host-extensible** with `registerop!` / `registerclassifier!` — and because
every surface above reads the registry live, a new operator appears in
completion, repair and suggestion at once:

```julia
registerop!(:geomean, x -> exp(mean(log.(x))); shape = :reduce)   # aggr"geomean(_)"
```

`shape` is how the parser knows an operator returns one value per group, per
row, or per argument; declaring it is optional, and an operator that does not
gets no shape checks rather than a guessed one.

Three documents carry the rest: **[docs/extending-the-grammar.md](docs/extending-the-grammar.md)**
for writing your own operators, **[design/user-guidance.md](design/user-guidance.md)**
for the whole guidance system and the sixteen rules it must satisfy, and the two
operator references below.

## Operator reference

Every shipped operator — signature, kwargs, and a worked example — lives in
the two operator documents, which a test keeps in sync with the registry:

- [docs/safe-dimension-operators.md](docs/safe-dimension-operators.md) —
  classifiers (`topnames`, `discretize`, `quantiles`, `where`), calendar
  buckets, order-based verbs (`cumsum`, `lag`, `lead`), the ranking quartet
  (`rank`, `denserank`, `ordinalrank`, `tiedrank`), the modifiers.
- [docs/safe-aggregation-operators.md](docs/safe-aggregation-operators.md) —
  reductions, `uniqvalue` / `countuniq` / `strjoinuniq` / `unionall`,
  `wmeanfallback`, `hhi` (Herfindahl–Hirschman concentration), and the rules
  for composite aggregation.
- [docs/extending-the-grammar.md](docs/extending-the-grammar.md) — for **host
  developers**: writing your own safe operators with `registerop!` /
  `registerclassifier!`, end to end.

`listops()` prints the live registry, including anything a host has added
with `registerop!`.

## Design notes

`design/` records the reasoning behind decisions that look arbitrary until
you hit the case that motivated them. Worth reading before filing an issue
that begins "why doesn't it just…":

- [composition-rules.md](design/composition-rules.md) — the invariants the
  package guarantees: left-context visibility, `dim` non-destructive vs `agg`
  destructive (and why `agg` decomposes exactly into `dim` + reduce, which is
  the debugging technique), trust never escalating through composition.
- [expressiveness.md](design/expressiveness.md) — why the vocabulary has the
  shape it has, and which spellings were declined (`ifelse`, `&`/`|`,
  aliases for Base names). **Read before requesting a new operator.**
- [user-guidance.md](design/user-guidance.md) — how the package gets an analyst
  to a spec that parses and means what they wanted, as one system: what the
  guidance knows (the registry, operator shape, repair), the proactive half
  (`spec_templates`/`spec_vocabulary`), the reactive half (the rejection ladder,
  did-you-mean, `checkcols`), both output channels (prose and `SpecError`), and
  the sixteen rules that keep them from contradicting each other. **Read before
  adding an error message or a template.** Ends with what a consumer — a linter,
  an LSP server, an LLM that writes specs — can build on the same machinery.
- [prior-art.md](design/prior-art.md) — how this relates to Elasticsearch
  bucket/metric aggregations, MongoDB `$setWindowFields`, Tableau LOD
  expressions, and DAX calculated columns vs measures.
- Syntax rationale: [why-two-modifier-names.md](design/why-two-modifier-names.md)
  (why `orderby`/`groupby` and not a single `by`),
  [glyph-choice.md](design/glyph-choice.md) (why `∘`/`|>` and not `.`),
  [compound-modifiers.md](design/compound-modifiers.md) (why modifier order
  carries no meaning),
  [middle-windowpivot-usecase.md](design/middle-windowpivot-usecase.md) (why
  ordered window dims may sit mid-chain).
