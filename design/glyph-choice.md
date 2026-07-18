# Glyph choice: why the modifier separator is `∘`/`|>` and not `.`

*Design note, 2026-07. Question posed: "why don't we use just a period `.`
instead of `∘` or `|>` as the modifier separator to begin with? Does it parse
right in Julia?"*

Background (from the README): `∘` is the truthful glyph — a modifier
*composes* with the spec, nothing is called — and `|>` is its ASCII twin for
TUI text fields where `\circ`-tab doesn't exist. The two are exact synonyms,
a grammar invariant (see `compound-modifiers.md`). `.` would beat `|>` by one
keystroke, which is exactly the argument that admitted `|>` — hence this note.

## Does it parse? Yes — but as the wrong thing, and fragilely

Verified against Julia's parser (2026-07):

| Spec text | Parse result |
|---|---|
| `cumsum(sales).orderby(date)` | ✓ `Expr(:call, Expr(:., <call>, QuoteNode(:orderby)), :date)` |
| `cumsum(sales).orderby(date).groupby(g)` | ✓ nested getproperty-calls |
| `cumsum(sales) . orderby(date)` | ✗ hard parse error (whitespace) |
| `sales > 10 .orderby(date)` | ✗ hard parse error (number-adjacent dot) |
| `lag(sales, 2).orderby(date)` | ✓ (the dot follows `)`, so numeric args are fine) |

So `.` does not parse as an operator combining two expressions (the way `∘`
and `|>` parse as ordinary 2-arg calls that `peel_modifiers` pattern-matches);
it parses as **field access on the call's result, then call the field** —
the getproperty shape. Structurally peelable, but with three liabilities the
current separators don't have:

1. **Whitespace intolerance.** `spec . orderby(...)` is a parse error; `∘`
   and `|>` tolerate any spacing. A separator that dies on a stray space is
   a real cost in a grammar aimed at end-user text fields.
2. **Number-adjacency failure — and it bites.** `sales > 10 .orderby(date)`
   fails to parse (`10 .orderby` collides with float / dotted-operator
   lexing). Since 0.8.2 a bare condition IS a legal spec, so specs ending in
   a numeric literal exist; with `.` as separator, whether a modifier may be
   attached would depend on the last character of the spec.
3. **It is the same shape as a qualified call.** `cumsum(sales).orderby(d)`
   and `Core.eval(Main, x)` are both "dotted call" to the parser.

## The decisive objection: the trust boundary's bright line

The safe grammar's single most auditable rule — the one carrying the trust
boundary — is **"dots are rejected, always"**: qualified names
(`Core.eval`), broadcast calls (`f.(x)`), every dot shape, one bright line.
A `.` separator turns that into "dots are rejected, *except* when the dotted
head's LHS is itself a call and the field is a reserved modifier name".
Default-deny would still hold (the peeler rejects non-modifier names before
anything compiles), so it is not unsafe — but the one-sentence security
story becomes a paragraph, and in a deny-grammar every carve-out is a
standing audit cost. Not worth it for a separator.

## Semantic fidelity: `.` tells the biggest lie of the three

`compound-modifiers.md` established that modifiers are option-attachment
(kwarg fidelity), not pipeline stages. Rating the glyphs against that truth:

- `∘` — accidentally *true* for single modifiers (the modifier's
  transformation really does precede the verb, and the verb really is
  leftmost-runs-last, as `g ∘ f` promises);
- `|>` — covered by the SQL clause-order reading (`OVER (PARTITION BY …
  ORDER BY …)`), where everyone already knows clauses are declarations;
- `.` — imports the **method-chaining** reading (pandas'
  `df.groupby(...).agg(...)`), in which each `.m()` genuinely transforms the
  object to its left. That is the strongest possible version of the very
  misreading the README disclaims: `spec.orderby(date)` asserts `orderby` is
  a method *of the spec's result*, when it is never called and conceptually
  acts *before* the verb. Simply false.

## Token economics and Julia culture

Within these specs, `.` already means decimal literals (`[.25, .5, .75]` is
everywhere) and dotted-operator aliases (`.+`, `.<`). A third meaning would
make `.` the most overloaded character in a grammar designed for end users.
Julia itself deliberately has no method chaining — its chaining idiom IS
`|>` — so a `.` separator would squat on syntax that means field access
everywhere else in the ecosystem, while `|>` borrows syntax that means
exactly what Julia readers expect a chain to look like.

## What `.` would buy

One keystroke over `|>`. That gain was the entire reason `|>` was admitted
alongside `∘`, and `|>` already collects it.

## Design implication

Keep the separator pair `∘`/`|>` exactly as is. Do **not** add `.` as a
third spelling: it fails on parse robustness (whitespace, number adjacency),
blurs the "no dots, ever" trust-boundary invariant, and imports the
method-chaining misreading that the modifier semantics explicitly reject.

Status: no code change. This note records the analysis so the "just use a
dot, it's easier to type" proposal is not revisited without rereading it.
