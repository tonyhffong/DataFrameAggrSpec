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

## Postscript (2026-07): the precedence caveat

Both glyphs parse with Julia's precedence, and the two differ: `∘` binds as
tightly as `*`, while `|>` sits between comparisons and `+`. So the README's
"identical meaning" claim holds only when the spec's top level binds tighter
than the glyph — on a top-level `+`/`-` or comparison, the modifier silently
attaches to the nearest operand (`sales - lag(sales) ∘ orderby(date)` reads as
`sales - (lag(sales) ∘ orderby(date))`). The compiler catches the resulting
nested modifier and answers with the fix ("wrap the spec in parentheses and
keep the modifier last"); the README documents the caveat beside the two-glyph
rationale. Found in the 2026-07 adoption review
([adoption-review.md](adoption-review.md), finding 2); a day-over-day diff
with ordering is exactly the spec that hits it.

## Addendum (2026-07): what about `=>`? Its precedence is lower

*Question posed: "what about `=>`? Its precedence is even lower so it forces
fewer parentheses."*

The premise is correct, and this is the one candidate separator that beats the
shipped pair on a real axis. `=>` is precedence 2 — below everything except
assignment — so the postscript's caveat vanishes entirely. Measured against
Julia's parser (2026-07; `∘` = 12, `+` = 11, `|>` = 9, comparison = 7,
`=>` = 2):

| Spec text | Parses as |
|---|---|
| `sales - lag(sales) ∘ orderby(date)` | `sales - (lag(sales) ∘ orderby(date))` ✗ |
| `sales - lag(sales) \|> orderby(date)` | `(sales - lag(sales)) \|> orderby(date)` ✓ |
| `sum(_) > 100 \|> orderby(date)` | `sum(_) > (100 \|> orderby(date))` ✗ |
| `sales - lag(sales) => orderby(date)` | `(sales - lag(sales)) => orderby(date)` ✓ |
| `sum(_) > 100 => orderby(date)` | `(sum(_) > 100) => orderby(date)` ✓ |

(Note the postscript's rule refines per glyph: `∘` loses on `+`/`-` *and*
comparisons, `|>` only on comparisons — but a bare condition is a legal spec
since 0.8.2, so both glyphs have a live failing case. `=>` has none.)

Three objections, in increasing weight.

**1. Right-associativity gives compounds a different AST shape.**
`spec => orderby(a) => groupby(g)` parses as
`spec => (orderby(a) => groupby(g))`: the modifiers nest to the RIGHT and the
spec is a leaf of the outermost pair. `∘` and `|>` are both left-associative
and nest to the LEFT, which is why `peel_modifiers` is one loop that strips
the outer node and descends into `args[2]`. `=>` would need a second traversal.
More to the point, `compound-modifiers.md`'s invariant is that `∘` and `|>`
read compounds in opposite *narrative* directions while producing the **same**
AST — that identity is what makes the textual order safely non-semantic. `=>`
would be the first spelling to break it structurally, and mixing spellings
multiplies the pairings from two to six (`spec => orderby(a) |> groupby(g)`
parses as `spec => (orderby(a) |> groupby(g))`, i.e. a modifier applied to a
modifier, which the peeler rejects with "the modifier must follow the spec").

**2. `=>` already means something here — at two adjacent layers, with the
spec on the opposite side.** A chain entry is `:streak => spec` and a named
measure is `col => spec => outname`; an order entry *inside the modifier* is
`orderby(date => :desc)`. Fully spelled out, the separator proposal reads:

```julia
dim(df, :streak => "cumsum(f) => orderby(date => :desc)")
#              ^ name↦spec        ^ separator      ^ col↦direction
```

Three meanings of one glyph, nested inside each other. This is the "most
overloaded character" objection that sank `.`, but worse: `.`'s competing
meanings were lexical (decimal literals, dotted operators), while `=>`'s are
structural at the very layer being parsed. And the collision inverts the
reader's expectation — everywhere else in this API the thing to the LEFT of
`=>` is the name and the spec is on the right; here the spec would be on the
left.

**3. The governing law: `|>` exists to clear a barrier, and `=>` clears
none.** `expressiveness.md`'s naming law is *no aliases*. Two separator
spellings are already an exception, admitted for exactly one reason: `∘` is
the truthful glyph but cannot be typed into a TUI text field, so ASCII needs a
twin. `|>` collects that. `=>` is also ASCII and also two characters — it
buys no capability, only parentheses. What it would cost is permanent grammar
surface: a third spelling in every doc, rejection message, `SafeModifiers`
test and completion list, plus the second peel shape from objection 1. Set
against that, the thing being bought off is one parenthesis pair on the
minority of specs whose top level is a comparison (or, under `∘`, an
additive) — a case the compiler *already* catches and answers with a drop-in
fix. Trading a standing grammar cost for a diagnosed one-off is the wrong
direction.

**Design implication.** Keep `∘`/`|>`. Do not add `=>` as a third separator,
and do not swap it for `|>` (that would be breaking, and objections 1–2 apply
either way). Prefer `|>` in documentation for specs with an additive or
comparison top level, since it is the glyph that survives `-`.

**One actionable gap found while probing this.** Today
`dim"cumsum(sales) => orderby(date)"` is rejected as
*"unknown function '=>' — did you mean '=='?"*. The OSA repair fires because
`=>` and `==` are one edit apart, and it is exactly wrong: nobody typing `=>`
before `orderby(` meant equality. Per G1 the message should redirect to the
separator (`=>` in modifier position → "the modifier separator is `|>` or
`∘`"), which is the same shape as the `&`/`|` → `&&`/`||` rung already at the
top of `unknown_op_error`'s ladder. Not fixed here.

Status: no code change. Recorded so the "`=>` binds looser, use that" proposal
is not revisited without rereading it.
