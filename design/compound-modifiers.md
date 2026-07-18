# Compound modifiers: how should `groupby(...) |> orderby(...)` be read?

*Design note, 2026-07. Question posed: "should the compound modifier
`spec |> groupby(g) |> orderby(m)` be read right-to-left or left-to-right?
With the original `∘` symbol, composition says I should think orderby first,
then groupby, then the verb — analyze the semantic fidelity of what we are
trying to do."*

Context: `expressiveness-roadmap.md` #4 proposes allowing `orderby` on pivot
dims (sort the inner groups before the kernel — the Pareto idiom
`cumsum(sales) |> groupby(region) |> orderby(sales => :desc)`), which is the
first place both modifiers would legally coexist on one spec. This note
settles what their textual order may mean *before* that lands.

## The engine has exactly one plan

For a pivot dim with both modifiers there is a single coherent evaluation
order:

```
context partition → group by keys + aggregate deps → sort the groups → verb → broadcast labels back
      (chain)            [groupby(...)]               [orderby(...)]
```

Ordering cannot come first: in
`cumsum(sales) ∘ groupby(region) ∘ orderby(sales => :desc)`, the `sales`
that `orderby` names is the *group-level aggregated* sales — a value that
does not exist until grouping and aggregation have happened. **The
modifier's argument reveals its stage.** Reference determines binding, the
same way the chain's left-context rule derives semantics from what is in
scope rather than from ceremony. (The would-be alternative plan — sort ROWS
before aggregation, for order-sensitive aggregates like `first`/`last` — is
the AggrHints axis, deliberately not spec-addressable; so reordering the
modifiers has no second plan to denote.)

## Testing both reading conventions against that plan

**`∘` as true composition (right-to-left, verb last).** For SINGLE modifiers
this reading is literally, perfectly true:

- `cumsum(sales) ∘ orderby(date)` = "order, then cumsum" ✓
- `discretize(EnrlTot, [35]) ∘ groupby(District)` = "aggregate to district
  grain, then discretize" ✓

The verb sits leftmost and runs last, exactly as `g ∘ f` promises. But for
the compound, composition fidelity demands `verb ∘ orderby(m) ∘ groupby(g)`
— groupby innermost/first. The order a user naturally types (`groupby` then
`orderby`, mirroring SQL) reads *falsely* under strict composition: it
claims rows are ordered before grouping.

**`|>` as SQL clause order (left-to-right).** Here
`verb |> groupby(g) |> orderby(m)` is faithful twice over: it matches SQL's
clause sequence (`GROUP BY` then `ORDER BY`, where everyone already accepts
that the SELECT expression is written first but evaluated last), and it
matches SQL window-function syntax exactly —
`OVER (PARTITION BY region ORDER BY date)` puts partitioning before
ordering, and that ordering means precisely what #4 proposes: order the
things the aggregate consumes.

**So the two glyphs, read "honestly" in their own traditions, demand
OPPOSITE textual orders.** And the grammar has already made a promise it
cannot break: `∘` ≡ `|>`, exact synonyms (the README's accessibility
argument — `∘` is the truthful glyph, `|>` is the typeable one). If textual
order carried meaning, one tradition's readers would be systematically lied
to, and mixed-glyph specs (`verb ∘ groupby(g) |> orderby(d)`, which parses
fine given Julia's precedence — `∘` binds tighter than `|>`) would contain
two reading directions in one expression.

## Resolution: modifiers are keyword arguments, not stages

The README already states the intended reading: *"read it as 'with this
engine option', not 'pipe the data into orderby'"* — and the Julia-side
mirror makes it structural: `dimspec(spec; by = ..., order = ...)`. Nobody
reads keyword-argument order as execution order. The modifiers have exactly
that fidelity: **declarative option-attachment; textual order free; engine
plan fixed.** This is what `peel_modifiers` already implements — it
accumulates into the `order`/`by` fields order-insensitively (a test in
test/safe.jl pins both-modifier parsing), and duplicates are rejected.

Should one order be canonicalized and the other rejected, on-brand with
"errors, never precedence"? No — and `why-two-modifier-names.md` supplies
the criterion: reject where **two denotable plans** exist (there, window-`by`
vs pivot-`by`). Here both textual orders denote the *same unique plan*;
pre-aggregation row ordering is not reachable from the spec, so there is no
second semantics to guard against. An error distinguishing two spellings of
one meaning would not prevent a wrong computation; it would only punish a
stylistic choice. **Errors should mark ambiguity, not variance.**

## Design implications

1. **Textual modifier order is non-semantic, by design** — kwarg fidelity,
   protected by the `∘` ≡ `|>` synonym invariant, which makes any
   order-sensitive reading impossible to honor for both glyphs at once.
2. **The single-modifier composition mnemonic is literally true** (the
   modifier's transformation precedes the verb; the verb is leftmost and
   runs last) — safe to document, and worth documenting.
3. **For compounds, teach the dependency reading, not a direction**: the
   plan is fixed at group → order-the-groups → verb, visible from the spec
   itself — `orderby`'s columns name values that exist only
   post-aggregation. Anchor for SQL readers: the natural spelling coincides
   with `OVER (PARTITION BY … ORDER BY …)`.
4. **When #4 lands**: `orderby` on a pivot dim = sort the inner groups (by
   aggregated deps or keys) before the kernel; accept either textual order;
   keep rejecting duplicates.

## The honest cost

We give up the pure right-to-left `∘` story for compounds — a mathematician
reading `verb ∘ groupby ∘ orderby` strictly will infer a false order. The
mitigation is the one SQL has used for fifty years: clauses are
declarations, and the docs say so in one sentence.

Status: no code change (current parse behavior already matches). This note
constrains #4's implementation: do NOT make compound-modifier order
meaningful, and do NOT canonicalize one order with an error on the other.
