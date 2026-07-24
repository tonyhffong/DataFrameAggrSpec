# Expressiveness roadmap

*Review, 2026-07 (against 0.8.0). Question posed: "review the package, focus on
expressiveness." Every finding below was verified empirically against the
current code, not just read off the source.*

## Verdict

The core language is in good shape — chains with left context, the
`orderby`/`groupby` modifier pair, trusted/untrusted interlacing per chain
entry, and the repair-quality error messages form a coherent, genuinely
expressive design; the existing design notes show the remaining sharp edges
are deliberate. The gaps that remain are mostly **vocabulary, not grammar**:
missing operators that are one-line `registerop!` additions. The one real
composability *break* is `topnames` rejecting categorical columns (#3).

Suggested priority: **#3** (a bug against the package's own portability
promise), then **#1 and #2** (cheap vocabulary wins), then the **#4**
decision, with #5/#6 opportunistic.

## #1 The safe grammar has no conditional or boolean vocabulary (highest impact)

**Status: RESOLVED in 0.8.2, with a better design than proposed below.**
Instead of registering `ifelse`/`&`/`|`: (a) `&&`/`||` are translated
STRUCTURALLY in `compile_node` (they parse as their own heads, not `:call`,
so they cannot be registry entries) into pure elementwise Kleene and/or —
both sides always evaluated, `missing` propagates, and they bind looser than
comparisons so `a > 1 && b < 2` needs no parentheses (the `&`-binds-tighter
trap never exists); `&`/`|` are deliberately NOT registered — their
unknown-op error redirects to `&&`/`||`. (b) `!` ships as a broadcast
registry operator (direct assignment; `registerop!`'s `!`-ban remains a rule
for host names). (c) The `where(cond)` verb labels a condition with the
condition's own source text (`dim"where(sales > 100)"` → `"sales > 100"` /
`"Not sales > 100"`; `true_label`/`false_label` customize, `false_label`
defaults to `"Not " * true_label`) — labels are injected at parse time by
`desugar_where!` since only the compiler sees the text; trusted-Expr callers
pass `true_label` explicitly. `ifelse` was REJECTED (owner decision, 2026-07):
given `where`, the flag/labeling use case is covered, and the residual numeric
uses (cap-at-zero) have spellings already (`max(x, 0)`, `x * (x > 0)`) or a
host `registerop!`. Do not re-propose `ifelse` without a new use case.

**0.8.6 closed the last corner**: `ismissing` and `coalesce` ship as
broadcast registry ops — the row-level missing trio is complete (drop =
`skipmissing`, replace = `coalesce`, flag = `ismissing`), and
`ismissing(x) || x > 3` composes correctly with the Kleene `||`.

**Naming: why `coalesce` and not `replace_missing`/`fillmissing`**
(owner-ratified, 2026-07): (a) the shipped registry is a *projection of
Julia* — every Base-wrapping op keeps its Julia name, invented names are
reserved for package-authored verbs; an alias would be the first exception
and would break the colon-flip vocabulary portability across the trust
boundary (the same words must work in `aggr"sum(coalesce(_, 0))"` and
`:( sum(coalesce.(:_, 0)) )`). (b) `replace_missing` names only the arity-2
corner: `coalesce` is an n-ary fallback cascade
(`coalesce(phone_mobile, phone_home, 0)`), and the general operation deserves
its general name. (c) Borrowed capital: SQL/dplyr/Spark all spell it
`coalesce`, and SQL-literate users type it unprompted — with an alias-only
registry their spelling would fail with no OSA repair possible. (d) House
style has no underscores. The friendliness budget went into the docs (the
drop/replace/flag framing), not the name. `fillmissing` was the strongest
rejected alternative.

Original analysis:

"Flag rows where A and B", "cap at zero", "bucket manually with a condition"
are analytics bread-and-butter; none has a first-class spelling:

- **`ifelse` is not registered.** `dim"ifelse(sales > 6, 1, 0)"` fails. A
  broadcast-wrapped `ifelse` (`bcast(ifelse)`, src/safe.jl) is safe —
  non-short-circuiting, pure — and unlocks conditional measures and manual
  bucketing.
- **No `&` / `|` / `not`.** Compound flags require the Bool-arithmetic trick —
  `dim"(sales > 6) * (sales < 20)"` works (verified) but is
  spreadsheet-user-hostile, and there is no OR that stays Bool (`+` on Bools
  yields Int). `&` and `|` are bitwise, non-short-circuiting, broadcastable —
  exactly the shape `bcast` wants — and their names pass `registerop!`'s
  filters. Today `parsedim("(a > 6) & (b < 20)")` errors with *"did you mean
  `*`?"* — the OSA repair accidentally suggests the workaround; luck, not
  design.
- **No missing-value vocabulary at row level.** `skipmissing` covers
  reductions, but `ismissing` and `coalesce` are absent, so "replace missing
  with 0 before summing" or "flag missing rows as a pivot key" is
  inexpressible. This bites because comparisons propagate `missing` into the
  Bool keys the docs recommend. (`coalesce(x, 0)` also sidesteps the
  documented `missing`-is-a-column-name wrinkle: the default is a literal.)

Zero grammar changes needed; the maintenance rule applies (operator docs +
per-operator tests in the same change).

## #2 Count-distinct is inexpressible

**Status: RESOLVED in 0.8.3 as the dedicated verb `countuniq`** (owner-chosen
name, completing the `uniqvalue`/`strjoinuniq` family; same `skipna`/
`skipempty` kwargs as `uniqvalue`). `unique` itself stays unregistered.

Original analysis:

`uniqvalue` and `strjoinuniq` exist, but their most common sibling — "how many
distinct districts per county" — does not: `aggr"length(unique(_))"` fails
because `unique` is not registered (verified). Either register `unique` or add
a dedicated `nunique`/`countunique` verb. The dedicated verb is friendlier for
the TUI vocabulary and avoids exposing a whole-vector `unique` whose bare use
in a dim spec would produce confusing length-mismatch errors.

## #3 `topnames` breaks on categorical columns — the composability bug

**Status: FIXED in 0.8.1 (see "Plan for #3" below, implemented as written).
The rest of this file is analysis only.**

`topnames` is typed `name::AbstractArray{S,1} where S<:AbstractString`
(src/verbs.jl), but `CategoricalArray{String}`'s eltype is
`CategoricalValue{String}`. Two verified failures:

- **Categorical source column:** a frame whose `region` is `categorical`
  (extremely common — `CSV.read(...; pool=true)` produces them) makes
  `dim"topnames(region, sales, 2)"` die with a raw `MethodError`, not a
  TUI-grade error.
- **Classifier over a classifier:** `PivotDim` re-wraps its labels categorical
  (src/dimension.jl, `pivot_values`), so
  `[:t1 => dim"topnames(region, sales, 2)", :t2 => dim"topnames(t1, ...)"]`
  dies the same way. The README explicitly sells "move a link up and down the
  chain, compose with other dimension links" — this is the case where that
  promise fails.

Related tight-signature evidence: the body already contains
`ismissing(measure)` handling that the `T<:Real` measure signature makes
unreachable, and a `Union{Missing,String}` name column cannot dispatch in at
all — the signature is simply tighter than the body's intent.

## #4 Pivot kind silently depends on group-encounter order; group ordering is inexpressible

**Status: RESOLVED in 0.8.4 via the expressiveness route** — `orderby` on a
pivot dim now sorts the inner groups (by keys or hint-aggregated measures)
before the kernel, with inverse-perm scatter-back; order columns join the
dependencies. `dim"cumsum(sales) |> groupby(region) |> orderby(sales => :desc)"`
is the one-spec Pareto idiom. Per `compound-modifiers.md`, textual modifier
order stayed NON-semantic (either order accepted, duplicates rejected), and
orderby is legal on ALL pivot dims (a no-op on order-insensitive verbs, same
as a pointless orderby on a window sum — no semantic linting). Conflicts
(in-string orderby + dimspec order) remain errors. The un-ordered
`cumsum |> groupby` encounter-order behavior described below is thereby no
longer a trap: the ordering knob exists.

`dim"cumsum(sales) |> groupby(region)"` is *accepted* and computes a cumsum
over the per-region aggregates — in `groupby(...; sort = false)`
first-encounter order (`pivot_values`), which the user cannot see or control,
since `orderby` is rejected on pivot dims. An order-sensitive verb over groups
has order-*dependent* semantics with no ordering knob. Two directions:

- **Expressiveness route (preferred):** allow `orderby` on pivot dims,
  meaning "sort the inner groups (by their aggregated values or keys) before
  the kernel". That makes Pareto / cumulative-share-of-groups a one-spec
  idiom: `dim"cumsum(sales) |> groupby(region) |> orderby(sales => :desc)"`.
  Today Pareto *is* expressible, but only as the pipeline
  `df |> agg([:region]) |> dim([:cum => dim"cumsum(sales) |> orderby(sales => :desc)"])`
  — which works and deserves a README example either way; it is the best
  advertisement the transform composition has.
- **Safety route:** if the rejection stays, record the current behavior here,
  because `cumsum |> groupby` looks meaningful and returns
  encounter-order-dependent numbers.

Note the current rejection message ("pivot kind classifies group aggregates —
there is nothing to sort") is slightly false once this case is seen: there
*is* something to sort.

## #5 Accepted asymmetries and smaller gaps

- **Window extra-`by` has no string spelling.** `dimspec(spec; by=...)` adds
  window partition keys, but in-string `groupby` always flips to pivot — a
  pure-string chain can only widen a window partition by adding a chain key,
  which changes `agg` granularity as a side effect. Anticipated by
  `why-two-modifier-names.md`; if it ever hurts in TermWin, a third modifier
  (`|> within(cols...)`) is the natural shape. Known residual, fine as-is.
- **`agg`'s `cols` is all-or-nothing.** RESOLVED in 0.8.5 as
  `allbut = [:gap]` — the mirror image of `cols` (default hints-driven
  reductions minus the listed columns; mutually exclusive with `cols`,
  allbut columns must exist and must not be chain keys). `allbut` was chosen
  over `drop` because it names the resulting *selection* rather than an
  action: it reads as the intent ("aggregate all but gap") and makes the
  mutual exclusivity with `cols` self-evident, where `drop` invites both the
  "drop from the cols list?" composition misreading and row-dropping
  connotations.
- **No first-class row-count measure.** `cols = [:region => aggr"length(_)" => :n]`
  works (verified) but hijacking a key column to count rows is non-obvious; a
  documented idiom or an `nrow`-style measure entry would help.
- **No date/time bucketing.** RESOLVED in 0.8.7, with an owner redesign:
  NOT the Dates cycle accessors proposed below ("cycle is not a very useful
  part of bucketing; coarser bucket is") but five package-authored label
  verbs — `yyyy` `yyyyq` `yyq` `yyyymm` `yymm` (String output; optional
  POSITIONAL delimiter on the month forms — owner choice, typeability over
  the options-keyword convention: `yyyymm(t, "/")`). The formats are
  year-first and zero-padded, so
  **lexical order is chronological order** — the same property the
  rank-prefixed verb labels rely on — and coarser buckets handle year
  boundaries correctly where a month-of-year accessor would conflate
  2025-12 with 2026-12. Cycle accessors stay host-`registerop!` territory.
  (Original analysis: `year/month/quarter/dayofweek` are `bcast`-wrappable
  stdlib functions; `discretize` covers numerics only.)
- **`quantiles(x, qs)` lacks an `ngroups` convenience** that `discretize` has
  ("quartiles" requires typing `[.25, .5, .75]`). RESOLVED in 0.8.8:
  `ngroups` is a KWARG (the same word and spelling as `discretize`'s, for
  vocabulary consistency — the positional date-delim was a flagged exception,
  not the convention), and the boundary vector STAYS positional, merely
  becoming optional (demoting it to a kwarg would have broken every existing
  `quantiles(TestScr, [.5])` spec). Bare `quantiles(x)` defaults to quartiles,
  mirroring `discretize`'s `ngroups = 4` default; boundaries + `ngroups`
  together is an error (conflicts are errors, never precedence). `pctstr`
  gained a 2-decimal cap so `ngroups = 3` prints `33.33%`.

## #6 Doc/comment drift noticed along the way

**Status: RESOLVED in 0.8.4** (verified 2026-07-18 against 0.8.7). All three
items were fixed in the same commit that shipped `dim"where()"`:

- src/dimension.jl (`pivot_groupkeys` comment): the stale "quantiles'
  grouping-column array (argument 3)" clause was deleted — the comment now
  cites only topnames (`quantiles` is no longer a registered classifier).
- The package CLAUDE.md now documents `registerclassifier!(name, argpos)`
  with no `many` kwarg, matching the code (the `many` variant never reached
  a committed version).
- src/pivot.jl transform comment dropped the `df ∘ dim(chain)` example,
  which README / CLAUDE.md explicitly say is *not* supported ("no
  `∘`-on-frame sugar") — only `df |> dim(chain)` and `(t2 ∘ t1)(df)` remain.

## #7 `AggrHints` silently mis-resolved every `Union{Missing,T}` column; `agg` silently returned zero rows for an empty measure list

**Status: FIXED in 0.9.1.** Found in a follow-up review focused on
expressiveness of the aggregation path itself, not the grammar. Both bugs
were verified empirically before and after the fix; neither needed a
grammar change.

**Bug A — `resolveaggr` (src/aggrspec.jl).** The `bytype` scan and the
`default` fallback matched via `T <: K` on the column's *raw* `eltype`. Any
column that has ever held a `missing` — which is to say, essentially any
real-world nullable column — has eltype `Union{Missing,S}`, and
`Union{Missing,Float64} <: Real` is `false`. So the built-in default
(`Real => :sum`) and any **explicit** `bytype` hint (`AggrHints(Real =>
aggr"sum")`, `AggrHints(AbstractString => aggr"uniqvalue")` — the exact
patterns this README teaches) silently missed every nullable column and
fell through to the generic `:uniqvalue` catch-all, with no error. Since
real groups almost always have more than one distinct value, this usually
surfaced as every group's aggregate silently coming back `missing` —
including groups whose own rows contained no `missing` at all. It also
explained an apparent `topnames` regression on an all-`Union{Missing,T}`
measure column (`UndefVarError: T not defined in static parameter
matching`): `PivotDim`'s dependency aggregation resolves through the same
`resolveaggr`, so a nullable measure collapsed to an all-`missing` group
vector, which `topnames`'s `where T<:Real` signature can't bind against —
`topnames` and categorical columns (see #3 above) were never the actual
cause. `test/hints.jl`'s resolution testset only ever exercised bare types
(`Float64`, `String`, `Int`, `Any`), never `Union{Missing,T}`, so this had
zero test coverage despite being the single most common real-world column
shape.

Fix: strip `Missing` via `Base.nonmissingtype(T)` before both the `bytype`
scan and the `default` call — guarded to skip normalization when `T` is
*exactly* `Missing` (an all-missing column), because
`Base.nonmissingtype(Missing) === Union{}`, and `Union{} <: K` is `true` for
every `K` — normalizing that case would make an all-missing column
spuriously match whichever `bytype` entry happens to be registered first,
regardless of relevance. The guard preserves prior (already-sensible)
behavior for all-missing columns: fall through to `default(Missing)`, the
generic `:uniqvalue` catch-all.

**Bug B — `agg`'s empty-measures path (src/pivot.jl).** Whenever the
resolved measure list is empty — `cols = []`, an `allbut` excluding every
remaining column, or simply a chain whose keys already cover every column
in the frame — `combine(gd) do sdf; DataFrame([...for m in measures]...);
end` degraded to `combine(gd) do sdf; DataFrame(); end`. DataFrames.jl's
`combine` counts output rows from the per-group return's row count, and an
empty `DataFrame()` return means "zero rows for this group" — so the whole
result silently collapsed to zero rows instead of the natural "distinct key
combinations" reading (`SELECT DISTINCT keys`) that `cols`/`allbut`'s
"selection mode" framing implies. A `NamedTuple()` per-group return was
tried as a fix candidate and *also* collapses to zero rows — the fix can't
rely on an empty return shape counting as one row; it must force the row
count explicitly via `combine(gd, nrow => tmpcol)` (dropping `tmpcol`
after), which reuses the same `gd` `agg` already builds and reliably yields
exactly one row per group, missing keys included.

Chosen behavior: implement the `SELECT DISTINCT` reading rather than
raising an error, since it's a well-defined operation that completes the
existing `cols`/`allbut` design instead of leaving it as a footgun — see
the README's Aggregation section for the documented idiom.

## #8 `groupby(...)` modifier now accepts computed keys, matching the nested composite form

**Status: FIXED in 0.9.2.** The pivot modifier `spec |> groupby(cols...)`
previously only accepted bare column names / a `[col, ...]` array
(`simple_posarg` in `peel_modifiers`, src/safe.jl), while the *nested*
composite-aggregation `groupby` inside `compile_grouped` (also src/safe.jl)
already compiled arbitrary elementwise expressions as keys —
`aggr"mean(sum(_) |> groupby(yyyy(t)))"` worked, but
`dim"cumsum(sales) |> groupby(yyyymm(date))"` errored ("groupby expects
column names"). Two features sharing a name and a conceptual role
("aggregate/group at this granularity first") shouldn't have different
grammars. Chosen fix: the expressiveness route — extend the modifier, not
restrict the nested form (which would regress a documented, tested
capability).

**Why it wasn't a one-line change.** `PivotDim`'s inner grouping calls
`DataFrames.groupby(sub, d.by)` directly, which requires `d.by` to name real
columns already on the frame. The nested form never touches
`DataFrames.groupby` — it hand-rolls grouping via a `Dict` keyed by evaluated
tuples, which is why it could accept arbitrary expressions for free.
Reimplementing `PivotDim`'s grouping the same way would mean giving up
`GroupedDataFrame`/`groupindices`/the existing `AggrHints` dependency-
aggregation step it already leans on — too much churn for a modest feature.

**The fix.** A `GroupByKey` carrier (src/safe.jl: `name` — a `gensym`'d
synthetic column, `f` — the compiled thunk via the same `compile_node` path
`compile_grouped` uses, `cols` — the real columns it reads) widens
`SafeDimSpec.by`/`PivotDim.by` from `Vector{Symbol}` to
`Vector{Union{Symbol,GroupByKey}}`. At evaluation time (`pivot_values`,
src/dimension.jl), a context partition with at least one computed key gets
its `GroupByKey`s materialized as real gensym'd columns on a `copy` of that
partition before `DataFrames.groupby` runs, exactly the same grouping call as
before — bare-column-only `by` lists (the common case) keep today's
zero-copy `SubDataFrame` path untouched, so nothing about the existing,
overwhelmingly common usage pays for this. `required_columns`/`checkcols`
validate a computed key's real columns (with did-you-mean repair), never its
synthetic name.

**Deliberately out of scope:** `orderby` (wasn't part of the finding — an
"order by a post-aggregation expression" ask has no existing demand); the
Julia-side `by=`/`dimspec(...; by=...)` kwarg (stays `Symbol`-only — trusted
callers can already precompute a column); the `[col, ...]` array spelling of
`groupby` (stays plain-column-only — mixing a computed expression into it is
a clear, redirecting error rather than a new ambiguity to resolve).

## Plan for #3 (agreed fix)

1. **Loosen and normalize `topnames`** (src/verbs.jl):
   - Signature →
     `topnames(name::AbstractVector, measure::AbstractVector{<:Union{Missing,T}}, n::Integer; ...) where {T<:Real}`
     — keep `T` a bound typevar because the body uses `zero(T)` as the
     tie-tracking seed in three places.
   - First step: stringify the name column —
     `Union{Missing,String}[ismissing(v) ? missing : string(v) for v in name]`
     — so `CategoricalValue`s (and integer ids, a small expressiveness gain)
     become plain labels. Missing names never rank and land in `others`.
   - The internal `rankdict` must key on `Union{Missing,String}` sources: skip
     missing names when building it and short-circuit missing on lookup.
   - Missing measures: the body's existing `ismissing` skips become reachable;
     note `sort(..., rev = true)` places missings FIRST, so the rank loops
     must `continue` past them without consuming ranks (they already do —
     add a test).
2. **Normalize pivot key columns in `pivot_values`** (src/dimension.jl):
   collect group-key values as `unwrap(first(g[!, c]))` — `unwrap` is
   identity on non-categorical values (verified) — so *any* classifier verb,
   including host-registered ones, sees plain values instead of
   `CategoricalValue`s.
3. **Tests** (maintenance rule: per-operator tests move with the operator):
   - test/dftests.jl (direct verb): categorical name column; integer name
     column stringified; missing names → `others`; `Union{Missing,Float64}`
     measure (missings unranked, no rank consumed).
   - test/pivotdims.jl or test/chains.jl (integration): chain over a
     categorical source column; classifier-over-classifier
     (`t2 => dim"topnames(t1, ...)"` over `t1`'s categorical output).
4. **Docs:** update the `topnames` row in docs/safe-dimension-operators.md
   (name column may be any value type — values are stringified; categorical
   columns, including another classifier's output, compose). Optionally add
   the chained-classifier example to the README portability paragraph.
5. **Version:** patch bump (0.8.0 → 0.8.1) — behavior widens, nothing breaks.
