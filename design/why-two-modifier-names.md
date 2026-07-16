# Why two modifier names (`orderby`/`groupby`) and not a single `by`?

*Design note, 2026-07. Question posed: "should we just use `by` instead of
`orderby` and `groupby`? The intent operator should already imply which one to
use — do I miss something?"*

## The hypothesis, and where it holds

At the two poles of the operator vocabulary the verb really does imply the
modifier:

- order-consuming accumulators (`cumsum`, `lag`, `lead`) only ever want an
  ordering — `cumsum(sales) |> by(date)` is unambiguous;
- classifier verbs (`topnames`) carry their grouping key **as data** in the
  spec (`topnames(District, …)`), so they want *neither* modifier — and indeed
  the engine rejects `groupby` on classifier verbs outright.

If the vocabulary were only these two poles, a single `by` would work.

## What it misses: the dual-use middle

The middle of the vocabulary is genuinely both kinds. `quantiles`,
`discretize` — and, crucially, **any host-`registerop!`'d verb** — are
row-level operators *and* group classifiers, and the README documents both
readings side by side:

```julia
dim"quantiles(sales, [.5])"                      # window: buckets ROWS
dim"quantiles(sales, [.5]) |> groupby(region)"   # pivot: buckets the REGIONS
```

These are different computations with different answers on the same frame
(label each row by which side of a median it falls on, versus aggregate to
region level and label whole regions). A bare

```julia
dim"quantiles(sales, [.5]) |> by(region)"
```

has two defensible readings — "extra partition key for a window compute"
versus "granularity to aggregate to and then classify" — and whichever one
inference picked, **the other reading would become inexpressible in the string
grammar**. Today the user's word choice *is* the disambiguation.

## The causality runs modifier → kind, not verb → modifier

Kind inference is: classifier verb, or `groupby`-presence. `groupby` is the
signal that flips *any* verb — including host-registered ones the engine knows
nothing about — to pivot kind, **with zero per-verb registration**
(`registerclassifier!` exists only for verbs whose grouping key is data in the
spec, like `topnames`).

A unified `by` reverses the causality: to decide what `by` means, the engine
must know, per verb, whether its `by` is an ordering or a grouping. That is a
per-verb registry — "is it order-sensitive? is it classifier-capable? both?" —
for every shipped *and host-registered* operator, and every unregistered op
becomes ambiguous. Note the engine cannot even use "this verb needs ordering"
as the signal: it does not know which ops are order-sensitive (`cumsum` and
`sum` look identical to it; it just sorts when told).

## Supporting reasons

1. **The modifiers do not take the same arguments.** `orderby` accepts
   direction pairs — `orderby(date => :desc)` — which are meaningless for
   grouping. Under one name, `by(date => :desc)` vs `by(region)` would select
   different *mechanisms* based on payload shape. That is a trap in a grammar
   meant for end-user text fields.

2. **Where the verb does imply the kind, the grammar exploits it by
   *rejecting*, not inferring.** `orderby` on a pivot dim, `groupby` on a
   window dim, `groupby` on a classifier verb — all errors, never precedence,
   each with a TUI-grade message. Distinct names are what make those messages
   possible; a single `by` converts explicit conflicts into silent guesses.

3. **The Julia-side API already treats them as two axes.** `dimspec(ex; by =
   …, order = …)` keeps separate kwargs, and a `WindowDim` carries **both** a
   `by` partition and an `order` sort simultaneously. They cannot be one axis
   in the carrier, so they should not share one name in the string grammar
   that mirrors it.

4. **Legibility is borrowed capital.** `orderby`/`groupby` map one-to-one onto
   SQL's `ORDER BY`/`GROUP BY` (and dplyr's `arrange`/`group_by`). SQL kept
   them separate for the same underlying reason: ordering rows and coarsening
   granularity are different ideas that merely share a preposition.

## The rejected halfway option

Accepting `by` as an alias *where unambiguous* and erroring where ambiguous
was considered and rejected: it makes the token moody (same spelling, legal or
fatal depending on the verb), and spec strings stop being portable — swap
`mean` for `cumsum` in a saved spec and the meaning of its `by` silently
changes category. For a DSL whose specs live in config files and GUI fields,
spelling stability beats keystroke savings.

## Design implication

Keep both names. Do **not** introduce a unified `by` (or `by` alias) into
`SafeModifiers`. The pair is not redundancy; it is the kind selector for the
dual-use middle of the vocabulary, the enabler of zero-registration host
extension, and the source of the conflict *errors* (rather than precedence
rules) that `dimension.jl` guarantees.

Status: no code change. This note records the analysis so a future
"simplification" to `by` is not attempted without revisiting the dual-use
verbs (`quantiles`, `discretize`, arbitrary `registerop!` verbs) and the
zero-registration property.
