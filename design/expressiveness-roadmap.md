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
- **`agg`'s `cols` is all-or-nothing.** To drop one column from the default
  hints-driven reduction you must enumerate every other column —
  `middle-windowpivot-usecase.md` trips on exactly this ("use `cols=` to drop
  it"). A `drop = [:gap]` kwarg (or a rest marker) would be a small, local
  addition true to the "change one small step locally" philosophy.
- **No first-class row-count measure.** `cols = [:region => aggr"length(_)" => :n]`
  works (verified) but hijacking a key column to count rows is non-obvious; a
  documented idiom or an `nrow`-style measure entry would help.
- **No date/time bucketing.** `year/month/quarter/dayofweek` (Dates is stdlib,
  `bcast`-wrappable) are conspicuous absences — `discretize` covers numerics
  only. Shipping them keeps the registration-free promise for the most common
  time-series pivot keys.
- **`quantiles(x, qs)` lacks an `ngroups` convenience** that `discretize` has
  ("quartiles" requires typing `[.25, .5, .75]`).

## #6 Doc/comment drift noticed along the way

- src/dimension.jl (`pivot_groupkeys` comment) still says "quantiles'
  grouping-column array (argument 3)" — `quantiles` is no longer a registered
  classifier.
- The package CLAUDE.md describes `registerclassifier!(name, argpos; many)` —
  there is no `many` kwarg in the code.
- src/pivot.jl transform comment shows `df ∘ dim(chain)`, which README /
  CLAUDE.md explicitly say is *not* supported ("no `∘`-on-frame sugar").

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
