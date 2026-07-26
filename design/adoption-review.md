# Adoption review: steering outside habits (2026-07)

*Design note. Subject: how fast a newcomer — human or LLM — arriving from SQL,
pandas, dplyr, Excel, DataFrames.jl or StatsBase gets to a correct spec, and
where their imported habits either fail without guidance or, worse, succeed
with different semantics. Method: ~60 habit probes run against the real
parser (`parseaggr`/`parsedim`), plus checks of the echo-back
(`specsummary`/`specfields`) and template surfaces. Companion to
`user-guidance.md`, which owns the rules (G1–G16) the fixes must satisfy.*

**Status: findings 1–4 fixed in the change that added this note. 5–9 open.**

## What the review confirmed works

The rejection ladder performs as designed on the common arrivals: `avg`,
`nunique`, `n()`, `row_number`, `fillna`, `shift`, `ifelse`, `allequal`,
`nullif`, `ntile`, `case_when` all land on the foreign-spelling rung; `MAX` /
`COUNT` / `dense_rank` hit the casing/underscore redirect; `cumsum(:qty)` gets
the colon-flip message; `.&` redirects to `&&`; arity and kwarg checks fire at
parse time with the accepted alternatives named. Every error that reached the
ladder was directly actionable — which is what makes the
generate→parse→feedback loop converge for an LLM consumer. The findings below
are the residue.

## The ranking principle

Ranked by *harm*, not frequency: a habit that produces a **wrong answer
silently** outranks one that produces a confusing error, which outranks one
that produces a merely unhelpful error. A rejection ladder can only steer
mistakes that produce errors — where a foreign habit maps onto legal text with
different semantics, the interception has to happen at the nearest error the
user *does* hit, and in the docs.

## Findings

### 1. The silent PARTITION BY trap — FIXED (interception + docs)

`SUM(x) OVER (PARTITION BY region ORDER BY date)` translated the obvious way
runs without error and computes something else:

```
dim"cumsum(sales) |> groupby(region) |> orderby(date)"   # pivot: aggregate-then-classify
[:region, :cum => dim"cumsum(sales) |> orderby(date)"]   # what the SQL user meant
```

On the probe frame: `[30, 30, 80, 80, 80]` vs `[10, 30, 5, 20, 50]`. The form
cannot be rejected — it is the legitimate Pareto idiom — so the fix is
interception at the errors a SQL user does hit:

* `ForeignPartitionWords` (`partitionby`, `partition`, `within`, `over`,
  squash-matched) + `partition_reminder` in `rejections.jl`. The **top-level**
  modifier position (`peel_modifiers`) points at the chain's left context and
  explicitly warns that `|> groupby` is not a partition. Before this, the
  generic "expected a modifier call (orderby, groupby)" message read as an
  instruction to "correct" `partitionby` to `groupby` — marching the user into
  the trap.
* The **nested** position (`compile_grouped`) redirects to the composite
  `groupby` instead: `mean(sum(_) |> partitionby(year))` *should* be the
  nested `groupby` — per-key evaluation inside a spec is exactly what that
  node does. The two positions want opposite advice; one table, two messages.
* README: a "Coming from SQL window functions?" callout beside the Pareto
  example, showing both forms and both outputs' meaning.
* Third line of defense, already present: `specsummary` renders the trap form
  as `cumsum [pivot by region; ordered by date]` — a host that echoes it gives
  the user the word "pivot" to trip over.

### 2. Glyph precedence breaks `∘ ≡ |>` on arithmetic/comparison tops — FIXED

`∘` binds as tightly as `*`; `|>` sits between comparisons and `+`. So
`dim"sales - lag(sales) ∘ orderby(date)"` — a day-over-day diff, written in
the README's advertised shape — parsed as `sales - (lag(sales) ∘ orderby(date))`
and died with *"orderby cannot attach to a nested grouped reduction —
subgroups are ordered by their groupby keys"*: a groupby answer to a question
nobody asked. `dim"sales > 12 |> orderby(date)"` hit the same wall.

Fixed in `compile_grouped`: the branch cannot distinguish the precedence trap
from a deliberate nested `orderby`, so the message now names both readings,
leading with the fix — *wrap the spec in parentheses and keep the modifier
last* — and keeping the subgroup fact for the genuine nested case. The
orderby-after-nested-groupby case (`… |> groupby(y) |> orderby(d)` nested)
kept its original message via a new dedicated branch. README and
`glyph-choice.md` (postscript) now carry the precedence caveat.

*This was the one deliberate message reword in the change (G9): the old text
was misleading for the majority reader of that error. `test/safe-modifiers.jl`'s
pin was preserved because the new message still contains the old needle.*

### 3. `count(*)` was a false accept — FIXED

Julia parses `count(*)` as the function `*` in argument position; the compiler
read any bare Symbol as a column, so the most common SQL aggregation spelling
in existence compiled to a column named `*` and died at apply time inside a
DataFrames lookup (a raw `ArgumentError`, not even a `SpecError`). Fixed in
`compile_node`: a bare non-identifier Symbol is rejected at parse time — `*`
with the `nrow` redirect (`:foreign_spelling`), any other operator symbol with
a generic "operator, not a column" (`:unsupported_syntax`).

### 4. Excel `IF` was misrepaired to `in` — FIXED

`aggr"IF(_ > 0, _, 0)"` fell past the foreign-spelling rung (no `:if` row) to
the OSA rung, which offered *"did you mean 'in'?"* — a confidently wrong
repair, the exact failure G3 exists to prevent, on a name Excel users type
constantly. Fixed with a `:if` row in `ForeignSpellings` (squash of `IF`;
lowercase `if(` never reaches the table — it is a Julia keyword and fails at
`Meta.parse`). Table count is now 57; `user-guidance.md` updated.

### 5. Raw `Meta.parse` errors for multi-token SQL syntax — OPEN

`count(distinct region)`, `sum(case when … end)`, `x between 1 and 10`,
`sum(x) filter (where …)`, `cumsum(x) over(region)` all surface as *"Expected
`)` or `,`"* / *"extra tokens after end of expression"*. They never parse, so
the ladder never sees them. Proposal: at the `:parse` choke in `safe_parse`,
sniff the raw text for SQL keyword shapes (`case when`, `between … and`,
`distinct`, `over (`, `filter (where`) and append a per-keyword redirect
(`case when` → `where`/`discretize`; `distinct` → `countuniq`; `between` →
`x >= lo && x <= hi`; `over(partition by …)` → the finding-1 message).
Additive at a choke point (G12), advisory text only (G15).

### 6. Vocabulary and G1 gaps — OPEN

* `competerank` falls to the registry dump — ironic, since `rank` is
  documented as the package's one deliberate spelling deviation *from
  StatsBase's `competerank`*. One `ForeignSpellings` row. Also worth rows:
  `zscore` → `(x - mean(x)) / std(x)`, `value_counts` → `countuniq(x)` /
  `agg(df, [:col])`, `sumproduct` → `sum(a * b)`, `averageif` →
  `sum(x * (cond)) / count(cond)`.
* `SafeRejections` entries that name the wall but not the door (G1):
  `:tuple` ("tuples are not allowed" — SQL's `IN ("E", "W")` and
  `quantile(_, (.25, .75))` need the `[ … ]` pointer), `:if` ("conditionals
  are not allowed" — needs the `where`/`onlyif`/arithmetic redirect the
  `ifelse` row already has), `:ref` (`sales[1]` — point at
  `first`/`last`/`lag`/`lead`).
* The `missing`/`null` identifier wrinkle has no error-side story:
  `coalesce(x, null)`, `coalesce(x, NA)` and `coalesce(_, missing)` all die as
  "column 'null'/'NA'/'missing' does not exist". `checkcols` could
  special-case the well-known tokens: SQL's null is Julia's `missing`, this
  grammar reads `missing` as a column — write a concrete default
  (`coalesce(x, 0)`), drop with `skipmissing(x)`, flag with `ismissing(x)`.

### 7. G6 echo collisions — OPEN

Confirmed identical `specsummary`/`specfields` output for specs the engine
distinguishes:

```
mean(sum(_) |> groupby(region))   =>  reduce via mean   [cols: _, region]
mean(_ * region)                  =>  reduce via mean   [cols: _, region]

sum(_ * qty) / sum(qty)           =>  reduce via /      [cols: _, qty]
sum(_) / sum(qty)                 =>  reduce via /      [cols: _, qty]
```

The nested composite stage — the flagship two-stage aggregation — is invisible
in both channels (`specfields` gives `function = mean, columns = _, region`).
The composite case should surface the nested `groupby` stage; if the division
pair is accepted as "structure below one level is not echoed", that boundary
belongs in `user-guidance.md` beside G6.

### 8. Machine adoption: the promised prompt-context tables are internal — OPEN

`user-guidance.md` recommends `ForeignSpellings` as prompt context and
`spec_vocabulary` as a constrained-decoding set, but the table is unexported
(open question 3 there). Cheapest durable fix, matching the operator-docs
pattern: render `ForeignSpellings` into a `docs/` table with a sync-guard
testset, so the "what you say elsewhere → what it is called here" map is a
promptable artifact that cannot drift.

### 9. Template plausibility (low, design-acknowledged) — OPEN

On a frame `region/date::Int/sales`, aggr templates offered
`sum(_ * date) / sum(date)` and `wmeanfallback(_, [date, 1])` — date as a
weight, because the sidecar pick is "first numeric sibling" (G8's positional
rule; name-sniffing was declined as locale-bound). Cheap mitigation within the
rule: exclude a column already chosen as the order key (or a known chain key)
from the weight-candidate pool. Runnable-but-absurd suggestions spend the
user's trust in the `?` dropdown.

## Probe method (for the next review)

Throwaway scripts (session scratchpad, not kept): a `probe(kind, spec)` loop
over the habit spellings of each source dialect, printing accept/first-300-
chars-of-error; a semantic-trap check comparing engine *outputs* for the
habit form vs the intended form; `specsummary` collision pairs; a
`spec_templates` dump on a small typed frame. The lesson worth keeping: parse
acceptance is not the finish line — the two worst findings (1 and the
`count(*)` half of 3) were *accepted* forms, found only by running the result
or reading what it computed.
