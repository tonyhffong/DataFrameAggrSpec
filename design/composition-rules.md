# Composition rules

*Formalization, 2026-07-23. The individual design notes each answer one
narrow question; this note names the invariants that recur across all of
them, so future extensions can be checked against a fixed rule set instead
of re-deriving intent from precedent. Companion notes: `expressiveness.md`
(what the vocabulary may say), `prior-art.md` (how comparable systems
solve the same problems).*

Each rule is stated, then justified against the code as it exists today —
not aspirationally. Where a rule is an obligation on *callers* the engine
cannot verify (rather than something it enforces), that's said explicitly.

## R1 — Left context is the only visibility rule; chains are acyclic by construction

A chain entry at position `i` may reference, in any capacity (as a spec's
data, as a classifier's grouping argument, as a `groupby`/`orderby` modifier
key — including a **computed** modifier key, `groupby(yyyymm(date))`), only
columns that exist strictly before it: original frame columns, or columns
declared by chain entries at position `< i`. Nothing later in the chain is
visible earlier — there is no forward reference, ever.

This is enforced twice, redundantly: **statically**, `chain.jl`'s
`chainentry!` passes each entry a `copy(keycols)` context containing only
what's accumulated so far, before appending the entry's own name; and
**dynamically**, `applydims!` (`dimension.jl`) walks the resolved dimension
list in order and checks `required_columns(d)` against the *incrementally
built* frame, so even a bug in the static check would still fail loudly at
apply time rather than read stale/future data.

The payoff is structural, not incidental: because dependencies only ever
point left, a chain's dependency graph is *by construction* a total order —
there is no cycle-detection code anywhere in the engine because there is
nothing for one to detect. This is why chains are a linear sequence rather
than a general dependency graph; the restriction is what buys the guarantee.

**Composability corollary**: this rule is kind-agnostic. A `WindowDim`'s
output, a `PivotDim`'s output (even `CategoricalArray`-typed), and a
computed `groupby` key's synthetic materialization are all just "a column
that now exists" to anything after them — same visibility rule, no
privileged kind. This is the mechanism behind the README's "move a link up
and down the chain" portability promise, and is exactly what let the #3 fix
(computed `groupby` keys) reuse the existing validation path (`checkcols`/
`required_columns`) instead of inventing a new one.

## R2 — Chain entries are sequential; measures are independent

Chain entries see everything to their left (R1). `agg`'s `cols=`/`allbut=`
measure entries do **not** work this way — each is computed independently
from the same post-`dim` grouped sub-frame, and none may reference another
measure's *output* (only chain-materialized *input* columns). If measure B
needs measure A's result, that is a second `agg`/`dim` statement, not a
second entry in one `cols=` list — the same "side computations are separate
statements, rebuilding context explicitly" rule the README already states
for dimensions applies symmetrically to measures.

## R3 — `dim` is non-destructive, `agg` is destructive, and `agg` is *exactly* decomposable into the two

**Non-destructive (`dim`)**: output row count equals input row count; every
existing column's values are preserved unchanged; the only change is new
columns appended. No information is discarded — the original frame is
always recoverable via `select(out, Not(newcols))`.

**Destructive (`agg`)**: output row count equals the number of distinct key
combinations (generally `< nrow(input)`), and every non-key column's
per-row detail is irreversibly collapsed into one summary value per group.
This is real information loss, not a formality — it's why `agg` bugs are
categorically harder to catch by inspection than `dim` bugs (a wrong `dim`
column is visibly wrong next to its inputs; a wrong `agg` value has no
row-level detail left to compare it against).

**The decomposition is exact, not just conceptually similar** — `agg` and
`dim` call the identical `normalize_chain` + `applydims!` machinery:

```julia
# dim!/dim (dimension.jl):
(_, dims) = normalize_chain(c); applydims!(df, dims; hints, replace)

# agg (pivot.jl):
keycols, dims = normalize_chain(chain)
!isempty(dims) && (df = applydims!(copyframe(df), dims; hints))
```

So for any `df`/`chain`/`hints`, `agg(df, chain; hints, cols)`'s
pre-reduction frame **is** `dim(df, chain; hints)` — same dims, same hints,
same order of application. This means the debugging technique isn't a
workaround, it's using `agg`'s own definition: when an aggregate looks
wrong, drop to `dim(df, chain; hints)` first and inspect the row-level keys
and measure *source* columns before trusting the (harder-to-verify) reduced
numbers. This is literally how Finding #1 (`AggrHints` silently mis-resolving
`Union{Missing,T}` columns) was diagnosed this session — the row-level data
was visibly fine; only the destructive step was wrong, which the
decomposition made obvious once tried.

One real (harmless) asymmetry: `dim` always copies (`dim(df,...) =
dim!(copyframe(df),...)`, unconditional); `agg` only copies when `dims` is
non-empty — a pure-existing-column chain lets `agg` operate on the caller's
own frame reference (safe, since `groupby`/`combine` don't mutate). Doesn't
affect the decomposition's *result*, only whether a fresh allocation happens.

**Sharpening "destructive"**: it should mean *fewer rows than distinct key
combinations there actually are is a bug*, not an accepted outcome — `agg`
is licensed to lose *per-row detail*, never to lose *groups that exist*.
Finding #2 (`agg` silently returning zero rows for an empty measure list)
was exactly this distinction violated: the destructive step over-destroyed,
collapsing real groups to nothing rather than one summarized row each. The
fix (`cols=[]` yields distinct key combinations) restores the rule rather
than working around it.

## R4 — Never mutate the input, except through the explicit `!` convention

`dim`/`agg` (no bang) never mutate their input frame; `dim!` is the only
function that mutates in place, and even then only by *adding* columns
(R3's non-destructiveness still holds for `dim!` — mutation and
destructiveness are different axes: `dim!` mutates its argument in place but
loses no information; nothing in this package mutates *and* destroys).
Curried transforms (`dim(chain...)`, `agg(chain...)` with no frame argument)
depend on this: the same `DimTransform`/`AggTransform` object is meant to be
reusable — `df |> report; df2 |> report` — which is only safe because
applying it never corrupts the frame it was applied to.

## R5 — Trust is a property of each spec, never inherited or escalated through composition

Trusted (`Expr`/`Symbol`/`Function`) and untrusted (`String`, routed through
the safe grammar) specs interlace freely within one chain, one `cols=` list,
or one curried pipeline — trust is decided per entry at parse time and never
propagates from or to a sibling. A `SafeDimSpec`/`SafeAggrSpec` compiled from
a `String` stays permanently restricted to its compiled closure; composing
it next to a trusted `Expr` entry grants it nothing extra. This is what
makes "accept one string from a text field, author the rest in Julia" safe
without auditing the whole pipeline — only the `String` entries need
scrutiny, and they're the ones already sandboxed.

## R6 — Ambiguity is always an error; variance is always accepted

The engine draws a hard line, stated first in `design/compound-modifiers.md`
("errors should mark ambiguity, not variance"), between two situations that
look similar but are treated oppositely:

- **Variance** — multiple spellings of the *same* outcome: `∘` vs `|>`,
  `groupby(g) |> orderby(m)` vs `orderby(m) |> groupby(g)`. Always accepted;
  there is nothing to disambiguate because both spellings denote the one
  evaluation plan the engine runs (R7).
- **Ambiguity** — two channels making a claim about the *same* option that
  could disagree: `order`/`by`/`kind` given both in-string and via
  `dimspec(...)` kwargs; `cols` and `allbut` both given to `agg`; two
  `orderby`/`groupby` modifiers on one spec; a classifier verb's own
  grouping argument plus an explicit `groupby`; an explicit `kind` that
  contradicts what the spec's own shape infers. Always an error, never
  resolved by precedence ("kwarg wins", "last one wins") — every one of
  these is a distinct `error(...)` call in `safe.jl`/`dimension.jl`/`chain.jl`,
  not a fallthrough.

Practical test for a new feature: if two spellings can only ever mean the
same thing, accept both; if they *could* disagree, reject the combination
outright rather than picking a winner.

## R7 — Each dimension kind has one fixed evaluation plan; options toggle stages, never reorder them

- **Window**: partition by `by` → sort by `order` if given → run the kernel
  over the (possibly sorted) subvector → scatter results back through the
  inverse permutation.
- **Pivot**: partition by `context` → group by `by` and aggregate `deps` per
  `AggrHints` → sort the groups by `order` if given → run the kernel over
  the group-level vectors → broadcast labels back to member rows.

Modifiers select *which optional stages exist* (an absent `order`/`by` is a
no-op stage), never their sequence — the sequence is fixed per kind. This is
what makes R6's "textual order is non-semantic" claim true in the first
place: there is exactly one plan to run regardless of how the modifiers are
spelled or ordered.

## R8 — A dimension's output is an ordinary column to everything downstream

Once materialized, a `WindowDim` or `PivotDim` output is indistinguishable,
to every later consumer, from a column that was always in the frame —
`CategoricalArray` values get transparently unwrapped/stringified at the
few boundaries that need plain values (`pivot_values`'s `unwrap`,
`topnames`'s stringification). No dimension kind is privileged as a data
source. This is R1's composability corollary elevated to its own rule
because it's the one the README sells hardest ("compose with other
dimension links") and the one a new classifier-verb or modifier feature is
most likely to accidentally break by special-casing "real" columns over
computed ones.

## R9 — Registered operators must be pure (unenforced — an authoring obligation, like the trust boundary)

Every cache in the engine (`DataFrameAggrCache`, `WindowKernelCache`,
`SafeSpecCache`, `DataFrameAggrSpec`'s per-`(col, spec)` lifted-function
cache) is keyed on the spec's text or `Expr` *alone* — sound only if
evaluating a spec twice with the same inputs always produces the same
result and touches no external state. `registerop!`/`registerclassifier!`
enforce naming rules (no `.`/`!`, no reserved-modifier names) but perform
**no purity check** — same posture as the trusted-`Expr` path, which is
"honest-author, not sandboxed" by design. A host registering a
side-effecting or non-deterministic operator silently breaks caching
soundness; this rule exists to name that obligation explicitly for anyone
extending the registry, since nothing will fail loudly if it's violated.

## R10 — Synthetic identifiers must never leak

Any name the engine invents for its own bookkeeping — `gensym`'d kernel
function names, the `gensym`'d throwaway column `agg` uses to force
one-row-per-group in the empty-measures fix, a computed `groupby` key's
`GroupByKey.name` — must never appear in (a) the frame returned to the
caller, (b) a user-facing error message, or (c) `required_columns`/
`checkcols` validation output. Errors and validation always name the *real*
columns an expression reads (`GroupByKey.cols`), never the synthetic
column that materializes them. This isn't written down anywhere else in the
codebase, but it was a hand-enforced invariant in every fix this session
that introduced a synthetic column — worth stating as a checklist item for
the next one: use `gensym` (never a plain string), strip it before
returning, and validate/report on the real columns, not the synthetic name.

## R11 — New names are checked eagerly; collisions are errors, never silent overwrite

A dimension's declared name colliding with an existing column
(`checkcollision!`), a measure's output name colliding with a chain key or
another measure's output name (`normalize_measures`) — both are caught at
declaration/application time with a specific error, before a bare
DataFrames assignment could fail more confusingly downstream. The only
override is `dim`'s explicit `replace=true`; there is no equivalent for
`agg`'s measure names, because a key/measure collision is inherently
ambiguous (which one wins isn't a legitimate question) rather than a
"you meant to overwrite" case.

## R12 — Borrowed semantics over invented ones (why the rules above look the way they do)

Every time the engine needed a composition spelling, it reused one the
reader already knows rather than inventing bespoke syntax: Julia's own
`|>`/`∘` for modifiers and transform composition (not a new pipe operator),
SQL's `GROUP BY`/`ORDER BY` clause vocabulary and ordering for the pivot
plan (R7), DataFrames.jl's `col => spec => outname` pair idiom for named
measures. `design/glyph-choice.md` and `design/why-two-modifier-names.md`
both argue this explicitly ("legibility is borrowed capital"). Named here
because it's the reason the other eleven rules tend to have an existing
analogue outside this package — when extending the grammar, prefer whatever
spelling a SQL/dplyr/DataFrames.jl reader would already guess over a novel
one, even if the novel one is marginally shorter.
