# Expressiveness: what the DSL says, and what it deliberately will not

*Reference note. Read this before proposing a new operator, a new modifier,
or a grammar change — most such proposals have an existing answer here, and
several have been considered and declined for reasons that still hold.*

The safe grammar is small on purpose. This note records **why the vocabulary
has the shape it has**, which spellings were rejected and on what grounds,
and the one gap that is knowingly still open. It is about the *language*;
`composition-rules.md` covers the semantics the engine must satisfy, and
`prior-art.md` covers what comparable systems do.

## The governing law: the registry is a projection of Julia

Every operator that wraps a Base/stdlib function **keeps its Julia name**.
Invented names are reserved for verbs this package authors (`topnames`,
`discretize`, `quantiles`, `uniqvalue`, `countuniq`, `strjoinuniq`,
`unionall`, `where`, `wmeanfallback`, the date buckets).

This is not style preference — it is what makes vocabulary **portable across
the trust boundary**. The same words must work on both sides of the colon
flip:

```julia
aggr"sum(coalesce(_, 0))"        # untrusted string
:( sum(coalesce.(:_, 0)) )       # trusted Expr
```

An alias for a Base function would be the first exception to that rule and
would break the property for the aliased name. Corollary: a proposal of the
form "let's also accept `fillmissing` for `coalesce`" should be declined, not
because the name is worse in isolation, but because the *aliasing* is the
cost. Friendliness belongs in the docs (the drop/replace/flag framing below),
not in extra registry keys.

A second reason to prefer the Julia/SQL spelling: **borrowed capital.**
SQL/dplyr/Spark users type `coalesce` unprompted. With an alias-only registry
their spelling fails, and the OSA repair cannot rescue a word that isn't in
the whitelist at all.

## Naming conventions, and their sanctioned exceptions

- **Data positional, options keyword.** `topnames(District, TestScr, 5)`
  takes its data positionally; `dense`, `others`, `ranksep` are kwargs.
  - *Exceptions, both deliberate:* `strjoinuniq`'s positional `sep`/`limit`
    predate the convention; the date buckets take a **positional** delimiter
    (`yyyymm(t, "/")`) for typeability in a TUI field, where
    `yyyymm(t, delim = "/")` is a real cost.
- **No underscores** in operator names.
- **Name the resulting selection, not the action.** `agg`'s `allbut = [:gap]`
  was chosen over `drop = [:gap]`: it reads as the intent ("aggregate all but
  gap") and makes its mutual exclusivity with `cols` self-evident, where
  `drop` invites both the "drop from the `cols` list?" composition misreading
  and row-dropping connotations.
- **Reuse a kwarg name across verbs that mean the same thing.** `quantiles`
  took `ngroups` because `discretize` already had it. Where a convenience is
  added to one verb, prefer the sibling's existing spelling over a better
  standalone name.
- **Widen, don't break.** When `quantiles` gained `ngroups`, the boundary
  vector stayed *positional* and merely became optional — demoting it to a
  kwarg would have invalidated every saved `quantiles(TestScr, [.5])` spec.
  Specs live in config files and databases; spelling stability outranks
  tidiness.
- **Conflicts are errors, never precedence.** Giving `quantiles` both
  boundaries and `ngroups` is an error rather than a documented winner. See
  `composition-rules.md` R6 for the general form of this rule.

## Boolean and conditional vocabulary

`&&` and `||` are **structural, not registry entries** — they parse as their
own `Expr` heads rather than `:call`, so they cannot be registered even in
principle. `compile_node` translates them directly into pure elementwise
Kleene and/or: both sides always evaluated, `missing` propagates, nothing
short-circuits (there is no control flow in this language).

The payoff is precedence. `&&`/`||` bind **looser** than comparisons, so

```julia
dim"sales > 10 && sales < 20"     # no parentheses needed
```

`&` and `|` are **deliberately not registered**, and their unknown-operator
error redirects to `&&`/`||`. Registering them would import the
`&`-binds-tighter-than-`>` trap, where `a > 1 & b < 2` silently parses as
`a > (1 & b) < 2`. The trap simply does not exist in this grammar, and should
not be introduced for the sake of matching DataFrames.jl muscle memory — the
error message does that job instead.

`!` ships as an ordinary broadcast registry operator. Note the asymmetry:
`registerop!` refuses names containing `!`, but that ban is a rule for *host*
names, not a statement about the shipped registry.

**`ifelse` is declined.** Given `where`, the flag/labeling use case — which
is what people actually reach for `ifelse` to do — is covered. The residual
numeric uses have existing spellings (`max(x, 0)`, `x * (x > 0)`), and
anything beyond that is host `registerop!` territory. Do not re-propose
without a use case that none of those three cover.

**`where` labels itself.** `dim"where(sales > 100)"` labels rows
`"sales > 100"` / `"Not sales > 100"` — the label defaults to the
condition's own source text, so the new column reads as its own definition.
Only the compiler ever sees that text, so the default is injected at parse
time (`desugar_where!`); trusted-`Expr` callers must pass `true_label`
explicitly, because there is no source string to recover.

## Missing values: drop, replace, flag

The row-level trio is complete, and the three roles are the useful framing
for documentation:

| role | operator |
|---|---|
| drop | `skipmissing` |
| replace | `coalesce` |
| flag | `ismissing` |

`coalesce` is n-ary — a fallback cascade
(`coalesce(phone_mobile, phone_home, 0)`) — which is the general operation
and deserves its general name, rather than an arity-2-only
`replace_missing`.

This vocabulary matters more than it looks, because comparisons propagate
`missing` into exactly the Bool columns the docs recommend as pivot keys.
`dim"ismissing(x) || x > 3"` is correct on missing rows precisely because
`ismissing` rescues the branch the Kleene `||` would otherwise leave
`missing`.

One grammar wrinkle to remember when writing defaults: bare identifiers are
**columns**, so `missing`, `pi`, and `Inf` are column references, not
constants. Missing-value defaults must therefore be literals —
`coalesce(x, 0)`, never `coalesce(x, missing)`.

## Date bucketing: coarser buckets, not cycle accessors

The shipped calendar verbs (`yyyy`, `yyyyq`, `yyq`, `yyyymm`, `yymm`) are
**bucket** labels, and the cycle accessors (month-of-year, day-of-week) are
deliberately absent.

Two reasons, both about what a *pivot key* needs. First, a cycle accessor
conflates periods across year boundaries — a month-of-year key puts 2025-12
and 2026-12 in the same bucket, which is a seasonality question, not a
bucketing one. Second, the shipped formats are year-first and zero-padded, so
**lexical order is chronological order** — the same property the rank-prefixed
verb labels rely on, which makes them usable as keys with no custom sort.

Seasonality is a legitimate need; it is host `registerop!` territory, where
any `Dates` accessor can be added in one line.

## Deliberately unregistered

A quick index, so these are not rediscovered one at a time:

| Not registered | Instead | Why |
|---|---|---|
| `ifelse` | `where`, `max(x, 0)`, `x * (x > 0)` | labeling case covered; residual has spellings |
| `&` / `\|` | `&&` / `\|\|` | avoids the binds-tighter-than-comparison trap |
| `unique` | `countuniq`, `uniqvalue`, `strjoinuniq` | a whole-vector `unique` in a dim spec yields confusing length-mismatch errors |
| a unified `by` modifier | `orderby` / `groupby` | see `why-two-modifier-names.md` — the pair is the kind selector for dual-use verbs |
| `.` as modifier separator | `∘` / `\|>` | see `glyph-choice.md` — breaks the "no dots, ever" trust-boundary line |
| aliases for Base names | the Julia name | breaks vocabulary portability across the trust boundary |

## Known residual gap: widening a window partition from a string

**A pure-string spec cannot add a window partition key.** `dimspec(spec;
by = ...)` does it from Julia, but an in-string `groupby(...)` always flips
the spec to *pivot* kind — that is its defined job. So from a string, the
only way to widen a window partition is to add a chain key, which changes
`agg` granularity as a side effect.

This is anticipated by `why-two-modifier-names.md`: the two modifiers are the
kind selector, and a window-widening `by` would be a third meaning competing
for the same slot. If this ever becomes a real constraint for a host, the
natural shape is a **third modifier** — `spec |> within(cols...)` — rather
than overloading either existing one.

Status: accepted as-is. Recorded so it is recognized as a known boundary
rather than mistaken for a bug.

## Checklist for a proposed operator or grammar change

1. Does it wrap a Base/stdlib function? Then it keeps that function's name.
2. Is it an alias for something already registered? Decline — see the
   governing law.
3. Does it introduce a second way to say something that already has a
   spelling? Prefer the existing one; variance is fine, but a *new* spelling
   for an existing meaning is vocabulary debt.
4. Could two channels now specify the same option? Make the combination an
   error, not a precedence rule (`composition-rules.md` R6).
5. Is the grouping column *data in the spec* (like `topnames`)? Then it needs
   `registerclassifier!`. Otherwise it needs no registration at all — the
   universal `groupby` modifier already makes any verb pivot-kind.
6. Is it a host-specific need (seasonality, a domain metric)? Then it is
   `registerop!` territory, not a shipped default.
7. If it ships: update `docs/safe-aggregation-operators.md` or
   `docs/safe-dimension-operators.md` **and** the per-operator tests in
   `test/safe-aggr.jl` / `test/safe-dim.jl` in the same change. The
   `DefaultSafeOps` snapshot and the docs-sync testset turn a forgotten doc
   update into a test failure.
