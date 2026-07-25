# Guiding the user to a correct spec

*Design note, 2026-07, written after `templates.jl` moved in from TermWin.
Subject: the machinery this package spends on getting an end user to a spec
that parses and means what they wanted — what it is, why it is shaped this
way, and the rules that keep its two halves from drifting apart.*

## Why this is a first-class concern here

Most DSLs are typed by a programmer into a source file, with a compiler, a
linter, an editor and a `git diff` between the typo and the consequence.
This one is typed by an **analyst into a one-line text field** — TermWin's
`newTwSpecEntry`, a config row, a database column — and it runs against
someone's frame moments later. Three properties of that setting decide
everything below:

1. **No second chance.** There is no stack trace to read, no docs tab open,
   often no keyboard shortcut out of the field. A rejection that does not
   say what to type instead is a dead end, not a diagnostic.
2. **No shared vocabulary.** The user arrives from SQL, dplyr, pandas or
   Excel. They will type `avg`, `ROW_NUMBER`, `:col`, `nunique`, `&`. Every
   one of those is *correct* somewhere else.
3. **The grammar is deliberately small.** Default-deny (`safe.jl`) means the
   set of things a user can type that we must reject is unbounded, while the
   set we accept is 86 registry entries and about a dozen shapes. Guidance
   is not a courtesy on top of the grammar — it is the only thing that makes
   a whitelist usable by someone who has not read the whitelist.

The result: 114 `error(` sites across `src/`, 53 foreign-spelling redirects,
18 tailored syntax rejections, 11 did-you-mean call sites, and a whole file
(`templates.jl`) of starter specs. That is a lot of code for something that
never computes an answer. This note is why it earns its place.

## The four moments

Guidance is not one feature; it is four, at four points on the user's
timeline. Naming them is what keeps the pieces from being designed in
isolation.

| Moment | Question the user has | What answers it |
|---|---|---|
| **Before typing** | "What can I even write here?" | `spec_templates` — whole starter specs, narrowed by target/frame/data |
| **While typing** | "What is this identifier called?" | `spec_vocabulary` — the completion list (registry ∪ columns ∪ modifiers) |
| **On submit** | "Is this right, and what does it mean?" | `parseaggr`/`parsedim` rejections + `checkcols`; `specsummary`/`specfields` echo back a valid one |
| **At apply time** | "Why did it blow up on *this* frame?" | `checkcols` again with the real columns; parse-time `check_arity`/`check_kwargs` having already moved two whole MethodError classes forward |

The two ends are the same knowledge read in opposite directions.
`spec_templates` proposes text from the registry; `didyoumean` repairs text
against the registry. That symmetry is the reason `templates.jl` belongs in
this package and not in TermWin (see *Division of labour* below) — and the
reason both must be reviewed together whenever the vocabulary changes.

## The proactive half: narrowing, not enumerating

`spec_templates(kind; coltypes, target, targettype, targetdata)` is not a
catalogue. A catalogue of 54 named operations × N columns is a wall of text
that helps nobody. The design commitment is that **context narrows the list**:

* **`:aggr` templates are target-scoped.** An aggregation reduces exactly one
  column and the host always knows which (a table cursor sits on it), so the
  templates are written against `_` and never enumerate the frame. The
  target's *type family* (`_AGGR_BY_FAMILY`) picks the reducer set — a `Bool`
  column gets `any`/`all`/`count`, not the `Bool <: Number` reducers; a date
  gets `minimum`/`maximum`/`first`/`last`, not `sum`.
* **Sibling columns gate shapes, not names** (`_aggr_context`). A weighted
  mean is offered only when *something* is numeric; `|> orderby(…)` only when
  there is a plausible ordering key.
* **Observed values promote** (`_aggr_datafacts`). Missings present pushes the
  `skipmissing`/`coalesce` variants to the front; a constant or low-cardinality
  column pushes `uniqvalue`/`countuniq`; negatives push the sign predicates.
  Seeing real rows *overrides* the declared type — a `Union{Missing,T}` column
  with no missing in this group keeps the plain spellings.
* **`:dim` templates stay per-column.** A dimension reads arbitrary columns by
  name and has no `_`, so there is no single target to write against.

One rule inside the proactive half deserves its own name, because it is the
subtlest thing `templates.jl` does:

> **A suggestion that throws on the column it was suggested for is worse than
> no suggestion.**

Hence `_AGGR_MISSING_SAFE`: when the target can be missing, the forms that
*throw* rather than propagate — `quantile(_, .25)`, `count(_ > 0)`, `count(_)`
— are **swapped** for their in-grammar safe spellings, not listed alongside
them. Note this encodes *this package's* evaluation semantics (which forms
throw on a `missing`, which propagate one), which is precisely why the table
cannot live in a UI package. The load-bearing testset in `test/templates.jl`
— every offered template parses **and runs** on the column it was offered for
— exists to keep that table honest as `verbs.jl` changes.

## The reactive half: an ordered ladder, cheapest specific answer first

`unknown_op_error` is the archetype. It is not a lookup; it is a **cascade,
ordered most-specific first**, and each rung exists because a real class of
user has a real reason to be there:

1. **Structural redirect** — `&`/`|` → `&&`/`||`. DataFrames muscle memory.
   The concept is present, the spelling is a different *kind* of node.
2. **Modifier misuse** — `orderby(...)` in call position. The name is
   reserved; the user needs to know it is postfix, not a function.
3. **No-underscores/lowercase redirect** — `dense_rank` → `denserank`. The
   concept and spelling both exist, modulo a naming convention
   (`design/expressiveness.md`).
4. **`ForeignSpellings`** — `avg` → `mean(x)`, `ROW_NUMBER` → `ordinalrank(x)`.
   53 entries. These are **not aliases**: the spec still fails, the registry
   still keeps one spelling per concept. They exist because edit distance
   cannot bridge `avg` → `mean` (four edits), so a user arriving from SQL has
   no path from the rejection to the local name. This is the *escape valve*
   for the "one spelling per concept" law, paid for in error messages rather
   than in vocabulary.
5. **`didyoumean` (OSA repair)** — `maen` → `mean`. Typos.
6. **`registry_summary()`** — the vocabulary dump. Discovery of last resort,
   reached only when the package has nothing more specific to say.

The ordering is the design. Reverse any two rungs and a user gets a worse
answer: `dense_rank` repaired by edit distance to `denserank` would be *lucky*,
not *explained*; `avg` dumped to the registry is a wall of text where a
one-word answer existed.

The same ladder logic recurs elsewhere. `parseaggr` on a bare word
(`aggr"revenue"`) asks `op_is_repairable` first: if the word is not close to
any operator, "this is a column reference, not an aggregation — reduce it"
beats any repair, because a lone unrecognised word in an aggregation field is
far likelier to be a column than a mistyped verb. `groupby_literal_error`
names the *colon* and the *quotes* specifically, because `:col`/`"col"` is by
far the commonest way to write a key wrong — every other DataFrames API wants
exactly that.

### Two MethodError classes moved to parse time

`check_arity` and `check_kwargs` are guidance, not validation. Without them,
`topnames(x)` and `rank(x, reverse = true)` parse cleanly and surface much
later as a raw `MethodError` from inside a group-by, naming neither the spec
nor the mistake. Both are decidable at parse time off the registered
function's own method table, so they are decided there.

Their **restraint** is as deliberate as their existence. `check_arity` fires
only when *no* method could accept the count — so it is session-dependent by
design (StatsBase widens `sum`/`quantile`, and those methods really are
callable from a spec). `check_kwargs` bails out entirely when any method
forwards `kwargs...`. A guidance check that is confidently wrong is worse
than absent, because the user cannot appeal it.

### The spec-source tag

Every rejection ends by quoting the spec it came from — `[in aggr"suum(x)"]`.
A host parses many specs per frame (an `AggrHints` table, the entries of a
chain), and "unknown function 'suum'" alone does not say *which one to fix*.
`with_spec_context` applies the tag **once at the entry point**, not at the
~40 individual error sites in `safe.jl`, which is why it also tags errors
raised by helpers further down (order entries in `dimension.jl`, verbs in
`verbs.jl`).

## The rules

These are what the two halves must jointly satisfy. They are stated so a
future change can be checked against them rather than against precedent.

**G1 — The message says what to type instead.**
Not what is wrong; what to write. `"'orderby' is a postfix modifier, not a
function — write the spec first: \"cumsum(sales) |> orderby(date)\""`, not
`"orderby is not callable"`. Every rejection in `safe.jl` is held to this.

**G2 — Repair XOR enumerate, except where the list is short.**
When did-you-mean fires, the alternatives list is suppressed (`checkcols`,
`unknown_op_error`); when it does not, the list is the fallback. The one
deliberate exception is `check_kwargs`, which gives both — a function's
keyword list is a handful of names, so it fits a one-line hint, and knowing
the full set is genuinely useful when you got one wrong.

**G3 — Repair is refused rather than guessed.**
`nearest` returns `nothing` for tokens under 2 characters, and only considers
candidates of the token's own *shape* (`isidenttoken` — word vs punctuation).
Both guards were learned from the registry, which mixes words and punctuation:
without them a 1-edit budget "repairs" `_` to `!`. A wrong repair is worse
than none, because the user will act on it.

**G4 — Every guidance surface reads the live registry.**
`spec_templates`, `spec_vocabulary`, `registry_summary`, `unknown_op_error`
and `didyoumean` all read `SafeOps`/`SafeModifiers`. A host `registerop!` is
therefore reflected in completion, in the vocabulary dump, and in repair,
with no second catalogue to update. This is the property that makes host
extension registration-free on the guidance side, matching what
`design/why-two-modifier-names.md` establishes on the engine side.

**G5 — What the proactive half offers, the reactive half must accept.**
Anything `spec_templates` emits must `parseaggr`/`parsedim` without error, and
any identifier it emits must be completable from `spec_vocabulary`. This is
the coherence contract between the two files; `test/templates.jl` enforces the
first clause, and the second is checked below.

**G6 — The echo-back must be lossless enough to distinguish two specs the
engine distinguishes.**
`specsummary`/`specfields` exist so a host can show the user what the text
they typed actually *means*. If two specs that compute different answers
render identically, the echo is worse than absent — it confirms a mistake.

**G7 — Guidance never widens the grammar.**
`ForeignSpellings` redirects but does not alias. Templates propose only legal
text. The did-you-mean names a spelling but does not accept it. Trust and
vocabulary are unchanged by everything in this note — cf. R5 in
`design/composition-rules.md` (trust never escalates through composition).

**G8 — Placeholders are honest.**
Where a template cannot know the real name, it uses an obviously-generic one
(`wt`, `date`, `year`) and relies on `checkcols` to route the user to the real
column. The alternative — a plausible-looking wrong name — reads as an
assertion about the frame. See *Known gaps*, which records where G8 is
currently paying more than it should.

## Division of labour: package vs host

The line is drawn at **grammar knowledge vs presentation**.

This package owns: which templates exist for a given target/frame/data, the
completion vocabulary, the structural rendition of a parsed spec, and every
rejection message. All of it is grammar-and-registry knowledge; none of it
knows what a terminal is. Everything is a pure function returning
`Vector{String}` or `String`.

The host owns: glyphs (TermWin's ✓/✗), the one-row hint budget and its
truncation, the `?` dropdown, Tab wiring, the F6 detail pane, and commit
gating. TermWin's `newTwSpecEntry` is the reference consumer and is a *thin*
wrapper — its only real content is `_strip_spec_prefix` and layout.

`templates.jl` moved here from TermWin in 0.9.5 for exactly this reason. The
decisive argument is `_AGGR_MISSING_SAFE`: knowing that `count(_ > 0)` throws
on a missing while `mean(_)` propagates one is a fact about *this package's
evaluation semantics*, and a UI package holding that table would drift against
`verbs.jl` silently, with no test able to see it.

## Drift guards

Guidance decays quietly — nothing fails when a message goes stale. The
guards that make decay loud:

* `test/safe-grammar.jl` — `"every shipped operator has a test"` and
  `"operator docs stay in sync with the registry"`, both iterating the
  load-time `DefaultSafeOps` snapshot (so host `registerop!` additions are
  exempt). Adding an operator without a test *or* a doc row fails the suite.
* `test/templates.jl` — every offered template parses **and runs** on the
  column it was offered for, on both the aggr and the dim side. This is what
  keeps `_AGGR_MISSING_SAFE` aligned with `verbs.jl`, and it is the reason the
  loops apply `liftAggrSpecToFunc`/`dim` rather than stopping at
  `parseaggr`/`parsedim`. A suggestion is a promise about the *engine*, so
  parsing is not enough to check it — see the three broken templates in the
  section above, none of which a parse-only test could have caught.
* `test/templates.jl` — "templates and vocabulary agree on every identifier":
  every name a template uses in call position must be completable from
  `spec_vocabulary`. This is G5 mechanised, and it is what would have caught
  the missing `:aggr` modifiers at the time they went missing.
* `test/safe-grammar.jl`'s error-quality testsets — spec-source tagging,
  arity/keyword checks, the colon flip, foreign spellings, repair quality,
  modifier/ordering mistakes. These pin *message content*, which is the part
  reviewers do not notice regressing.

There is deliberately **no** guard requiring every registered operator to
appear in some template. Templates are a curated ranking, not a catalogue
(that is the whole point of *narrowing*); `spec_vocabulary` is the surface
that must be complete, and `test/templates.jl` checks that one.

## What the 2026-07 coherence review changed

The review that produced this note found the two halves had drifted since
`templates.jl` arrived. Fixed in the same pass:

* **G5 — `spec_vocabulary(:aggr)` omitted `orderby`/`groupby`** while
  `spec_templates(:aggr)` offered four templates containing them. The `?`
  dropdown handed out text that Tab could not finish. Both modifiers are now
  offered for both kinds; *where* a modifier may appear is the parser's job to
  enforce, not the completion list's to pre-empt. TermWin's
  `_spec_wordlist` test had mirrored the same wrong assumption.
* **G6 — the echo-back dropped ordering.** `aggr"first(_)"` and
  `aggr"first(_) |> orderby(date)"` rendered identically, though they return
  different rows. `specsummary`/`specfields` now read `SafeAggrSpec.order`, and
  both sides render the *direction* too (`d => :desc`, in grammar syntax so it
  round-trips) — the dim side had been collapsing `:desc` to a bare column name.
* **G3 — repair ties broke alphabetically.** `orderby(d => :dsc)` suggested
  `asc`: one edit from both candidates, and `asc` sorts first. `nearest` now
  breaks ties on the longer shared prefix — typos cluster after the first
  character, so the prefix the user got right is evidence. One other shipped
  repair changed (`yyymm` → `yyyymm` rather than `yymm`, also better).
* **G8 — `orderby(date)` was offered to frames with no date column.** The gate
  accepted any numeric *or* date sibling while the template hardcoded `date`.
  The gate now requires a date, so the placeholder never asserts something
  false about the frame.
* **Consistency —** one `isidenttoken` authority instead of a second inline
  `isletter` predicate; did-you-mean on the `kind` arguments of
  `spec_templates`/`spec_vocabulary`/`dimspec`, matching what `orderentry` had
  always done for `:asc`/`:desc`.

**And three templates that had never been executed turned out to be broken.**
Extending the load-bearing test to *run* dim templates (it had only parsed
them, despite its name) caught all three at once:

| Offered | Fails because | Now |
|---|---|---|
| `quantiles(c, 4)` | arg 2 is the *boundaries vector*; the count is `ngroups` | `quantiles(c, ngroups = 4)` |
| `mean(m) \|> groupby(c)` | a pivot dim CLASSIFIES groups — a reducer returns one scalar where the engine wants one label per group | `quantiles(m, ngroups = 4) \|> groupby(c)` |
| `where(any(b)) \|> groupby(c)` | under `groupby` the Bool arrives already aggregated to a per-group count, so `any` gets `Int`s | `where(b > 0) \|> groupby(c)` |

None was reachable by parsing alone: `quantiles(c, 4)` passes `check_arity`
(arity 2 is in range) and dies at apply time. This is the single strongest
argument for the run-it-end-to-end shape of `test/templates.jl` — a suggestion
is a promise about the *engine*, not about the grammar, so only the engine can
check it.

## Known gaps

Recorded so they are not rediscovered as bugs.

1. **Aggr placeholders vs dim's real names.** `_dim_templates_for` names the
   frame's actual columns (`cumsum(sales) |> orderby(trade_dt)`);
   `_aggr_templates_for` keeps `wt`/`year` even though `_aggr_context` has
   already inspected the same column list to decide the shape is offerable. On
   a frame with no column literally named `wt`/`year`, those aggr suggestions
   fail `checkcols`. The `spec_templates` docstring's claim that did-you-mean
   "then names the real column" does not hold in practice — `wt` (2 chars,
   1-edit budget) never repairs to `weight`, and the user gets the full column
   list instead, which is useful but is not what is documented.

   This is a genuine design question, not an oversight, and was deliberately
   left open: the counter-argument is in `templates.jl`'s header comment
   (context *filters* rather than *names*) — but that argument was written
   about the **target**, and the second column is not the target. Deciding it
   means deciding whether `_AGGR_WEIGHTED`/`_AGGR_COMPOSITE` should be
   generated per-frame the way the dim list is. Note the aggr fixture frame in
   `test/templates.jl` contains columns literally named `wt`/`wt1`/`wt2`/`year`
   — the test was built to fit the placeholders, so it cannot see this.

2. **`checkcols` tags its spec differently from everything else.**
   Parser rejections end `[in aggr"…"]`; `checkcols` opens with
   `checkcols: spec "…" references …`. Both name the spec, so the *intent* of
   the rule is met, and unifying them would churn a widely-visible message for
   no user-visible gain — left deliberately.

3. **No guard ties a newly registered operator to a template.** By design:
   templates are a curated ranking, not a catalogue (that is what *narrowing*
   means). `spec_vocabulary` is the surface that must be complete, and it is
   tested. A host adding an exotic `registerop!` verb gets completion and
   repair for free but no template, which is the right default.

## The machine-facing direction: linters and copilots

*Investigation, 2026-07. **Blockers 1 and 2 are now shipped** (`SpecError`,
`src/diagnostics.jl`) — see "What shipped" below. The rest is recorded so the
next person to want a spec linter, an LSP server, or an LLM that writes specs
does not re-derive which parts are ready and which are the actual blockers.*

Everything above is written for a human at a keyboard. The same machinery has a
second audience — a linter checking a config file, an editor, an agent
generating specs — and the interesting finding is that **the hard parts are
already done and the blockers are small and additive**.

### What is already load-bearing

Four properties, none of them accidental:

* **Eval-free and total.** `parseaggr`/`parsedim` never execute user text, so
  hostile input can be linted in CI, an editor, or a web service with no
  sandbox. This is the property that normally makes "lint a DSL" a security
  project rather than an afternoon.
* **Cheap and cached.** `SafeSpecCache` plus keystroke-rate use already proven
  in TermWin's `hintfn`.
* **Two-phase by construction.** `parseaggr(s)` checks grammar;
  `parseaggr(s; columns)` adds schema. A linter usually has no frame — it can
  do phase one and deepen when a schema turns up. That split already exists for
  TUI reasons and is exactly what a linter wants.
* **Signature checking is already static.** `check_arity`/`check_kwargs` moved
  two MethodError classes to parse time (see above).

### What shipped: `SpecError` (blockers 1 and 2)

The problem was that **every diagnostic was an `ErrorException` carrying a
single `:msg` string** — excellent *prose*, unusable *data*. The tell was that
the reference host regexed our English (TermWin's `_strip_spec_prefix`). Worse,
**the fix was computed and then discarded**: `nearest` returned a repaired
`Symbol` and `didyoumean` formatted it into a sentence and threw the Symbol
away.

`src/diagnostics.jl` adds `SpecError <: Exception` with `msg`, `code`, `token`,
`fix` and `spec`. The governing constraint was that **the human contract does
not move**: `showerror` prints `msg` verbatim, and switching a site from
`error` to `specerror` is invisible in output. That was verified rather than
asserted — a 50-case corpus of rejections was rendered against `HEAD` in a
detached worktree and diffed against the converted tree: byte-for-byte
identical. Re-run that check after any future conversion.

Four properties worth preserving:

* **`fix` is a drop-in or it is absent.** It is set only when substituting it
  for `token` yields a valid spec — the quick-fix channel, where a wrong answer
  is worse than none (G3). The foreign-spelling table therefore contributes
  `code` and `token` but **no `fix`**: its values are prose completing "Use ___
  instead", and deriving a token from prose is exactly the guessing G3 forbids.
  A test pins the drop-in property by actually substituting and re-parsing.
* **One repair computation, two currencies.** `repair(tok, candidates)` returns
  `(hint, fix)` — the message fragment and the same answer as data. `didyoumean`
  is now its hint half. A message naming a repair the machine channel does not
  offer would be the same class of incoherence as G5.
* **Classification is additive, never a prerequisite.** `with_spec_context` is
  the choke point: whatever a helper throws — a classified `SpecError`, or a
  plain `ErrorException` from an unconverted site — leaves
  `parseaggr`/`parsedim` as a `SpecError` tagged with the spec source. An
  unclassified site still yields a usable diagnostic (`code = :invalid_spec`),
  so adding a code later is a one-line change with no coordination cost.
* **The scope line is "user spec" vs "host bug".** A diagnostic about
  user-supplied spec text or its column/order references is a `SpecError`;
  developer-facing API misuse (a bad `kind`, a malformed `AggrHints` key,
  `registerop!` name rules, a verb's own argument validation) stays an
  `ErrorException`. This is not cosmetic — it is what lets a consumer catch
  `SpecError` and know it has something to report *against a user's spec*
  rather than a bug in its own calling code. The line was validated by the
  conversion: of 42 `@test_throws ErrorException` assertions, exactly the 11 on
  the spec path changed, and the other 31 stayed put.

**No rule in G1–G8 changed.** Specifically, this is *not* licence to make
messages terser now that a code exists: the prose is the human contract, the
struct is the machine one, and G1 still governs the first.

### Source spans (blocker 4, shipped)

`SpecError.span` is the **byte** range of the offending text within `spec`, so
`e.spec[e.span]` is what to underline and `span` + `fix` together are a
quick-fix edit. Byte ranges are what Julia string indexing wants; an LSP host
converts to UTF-16 offsets itself.

Three decisions, in descending order of how much they mattered:

1. **Derived at the choke point, not threaded through the sites.** The span is
   computed in `with_spec_context` (and in `checkcols`, which runs outside it)
   by locating `token` in the source. That is the same trick `spec` uses, and
   the payoff is that **not one of the ~40 error sites had to learn about byte
   offsets** — a site that sets `token` gets a highlight for free. It also
   rewards having classified `token` correctly, which the previous round did.
2. **A hand-rolled lexer, not `Base.JuliaSyntax`.** Spans are reachable from
   the stdlib, but only through an *internal* API — during this work
   `first_byte(::Token)` turned out to be broken while `Token.range` was fine,
   which is exactly the instability to avoid depending on. The scanner in
   `diagnostics.jl` is ~60 lines and the blast radius of it disagreeing with
   Julia's real lexer is **cosmetic**: the parse is still `Meta.parse`, so a
   discrepancy costs a wrong or missing highlight, never a wrong verdict.
   Advisory precision buys stability. The one place Base *is* consulted is the
   `:parse` code, where `ParseError` already carries its own diagnostic ranges
   — wrapped in a `try` and degrading to `nothing`.
3. **The span is whatever `fix` replaces.** This is subtler than "highlight the
   token" and is what makes the quick-fix channel actually work.
   `cumsum(:qty)` spans `:qty` **including the colon**, because substituting
   `qty` for `qty` would repair nothing — the colon is the mistake. But
   `orderby(d => :dsc)` spans just `dsc`, because `desc` goes *after* the colon
   there. Two codes (`:symbol_literal`, `:groupby_literal`) opt into the
   quoted form; the rest take the bare identifier. A test applies every
   advertised fix at its span and re-parses the result.

Coverage is 21 of 23 diagnostic classes. The two without a span are the empty
spec (nothing to point at) and a qualified name like `Core.eval(Main, x)`,
whose offending "token" is not one — both correctly `nothing` rather than
guessed.

### The one note that did not become work

* **Do not build error recovery.** LSP convention wants all diagnostics per
  parse, but specs are one-liners and independent: a file of 50 specs yields 50
  diagnostics regardless. First-error-per-spec is the right cost/benefit here.

### Operator shape (blocker 3, shipped)

The registry used to record only `name => callable`, so nothing knew whether an
operator collapsed its input or preserved it. That is exactly why
`mean(m) |> groupby(c)` shipped in this package's own templates and only died
at runtime.

`SafeOpShapes` now records, per operator, how many values it returns **relative
to its input rows** — a cardinality axis, deliberately not a Julia-type one:

| Shape | Meaning | Examples |
|---|---|---|
| `:reduce` | whole vector → one value | `sum`, `mean`, `uniqvalue`, `unionall` |
| `:map` | one value per row | `cumsum`, `rank`, `lag`, `discretize` |
| `:elementwise` | follows its arguments | `+`, `==`, `abs`, `coalesce`, `where` |
| `:filter` | many values, not row-aligned | `skipmissing` |
| `:unknown` | undeclared — checks stay silent | any host verb that has not opted in |

Four decisions carried the design:

1. **Cardinality, not type.** `unionall` returns a `Vector` and is a `:reduce`
   (one answer per group); `extrema` returns a Tuple and is likewise `:reduce`.
   The question is never "what Julia type comes back" but "how many answers
   relative to the rows that went in".
2. **`where` is `:elementwise`, not `:map`.** This was found by probing rather
   than assumed: `where(true)` returns a `String` and `where([true,false])` a
   labelled vector, and `aggr"where(sum(_) > 100)"` (label the *group* by its
   total) works end to end. Getting this right is load-bearing twice over — it
   keeps five legitimate aggregation specs legal, *and* it is what makes the
   pivot check catch `where(any(flag)) |> groupby(g)`, the second template bug.
3. **Shape composes; it is inferred, not looked up.** `sum(_ * wt) / sum(wt)`
   and `sales / sum(sales)` are both divisions and only the first reduces. Only
   propagating through the tree tells them apart, so `shape_of` is a small
   recursive inference with `:unknown` **absorbing** — one undeclared verb
   anywhere silences every check, the same bail-out `check_kwargs` makes on a
   `kwargs...` method.
4. **Undeclared is the default.** `registerop!` takes `shape = :unknown` unless
   a host opts in, on the standing principle that a check which is confidently
   wrong is worse than one that is absent.

Two checks follow, plus a third that falls out for free:

* an **aggregation** spec may not be row-wise or a loose collection
  (`aggr"cumsum(_)"`, `aggr"skipmissing(_)"`);
* a **`groupby` dimension** must give one label per group, not collapse them —
  and the message blames the *reduction* (`reducing_culprit`), not the innocent
  top-level verb, since that is the token the user has to edit;
* a `:map` verb handed nothing but scalars has **nothing to map over**
  (`cumsum(sum(x))`), decidable because every `:map` verb rejects a scalar.

**Ordering matters as much as the checks.** Shape is verified *after*
`compile_node`, because a whole-spec verdict is less specific than a per-node
one: `cumsum(:qty)` must be told about the colon, not that it computes one
value per row. That is the same most-specific-first ladder rule as
`unknown_op_error`, and getting it backwards was caught by the existing
error-quality tests.

A drift guard (`"every shipped operator declares a shape"`) joins the docs and
per-operator-test guards: a shipped operator with no shape would silently
switch the checks off for every spec that mentions it.

**What it does not catch**, recorded so the boundary is clear: shape is per
name, not per arity, so `first(v)` and the exotic `first(v, 3)` share one label;
and type errors inside a correctly-shaped spec remain the engine's business.

### Copilot uses that need no new code

1. **Generate → parse → feed the error back → regenerate.** `parseaggr` is a
   cheap, total, side-effect-free verifier, and **G1 is the reason this
   converges**: an error that says what to type instead is precisely what an
   LLM needs to self-correct. `unknown_op_error`'s ladder is already a repair
   oracle — it was built for humans and happens to be the right shape.
2. **`ForeignSpellings` as prompt context.** 53 pairs of "what people say
   elsewhere → what it is called here" is the highest-value context available,
   because it enumerates exactly the mistakes a SQL/pandas-trained model makes.
   `SafeRejections` (18 shapes) and `expressiveness.md`'s deliberately-
   unregistered table serve the same purpose.
3. **`spec_vocabulary` as a constrained-decoding token set** — a model that
   physically cannot emit `avg`.
4. **`spec_templates` as schema-grounded few-shot retrieval** — ranked,
   type-appropriate, and (since the 2026-07 review) actually guaranteed to run.
5. **`specsummary` as a round-trip check** — render a generated spec back and
   compare against stated intent; the same call doubles as "explain this spec".

### Semantic lints the package almost knows how to do

These parse, run, and are probably wrong — warnings rather than errors:

* `first(_)`/`last(_)` with no `orderby` — non-deterministic. This note already
  says orderby is what those verbs need "to mean anything".
* `ordinalrank(x)` with no `orderby` — the template comment already says it
  "needs an order to be defined".
* `count(_ > 0)` on a missing-capable column — throws. `_AGGR_MISSING_SAFE`
  encodes precisely this and is currently **write-only** (templates consume
  it); a linter would read the same table backwards.
* `quantiles(x, ngroups = n)` where the group count is below `n`.
* Chain-level: unused dims, `allbut` naming a key, redundant keys —
  `dependencies` and `normalize_chain`'s left context already hold the graph.

The pattern is worth naming: this knowledge exists, scattered across template
tables and design-note prose. **A linter is the thing that would force it into
data**, which is a good argument for building one even if nobody lints.

### Ranked blockers

| # | Blocker | Status | Unblocks |
|---|---|---|---|
| 1 | String-only diagnostics | **Shipped** — `SpecError`, messages verified unchanged | Everything programmatic |
| 2 | `didyoumean` discards the repair candidate | **Shipped** — `repair` returns `(hint, fix)` | Quick-fixes, auto-apply |
| 3 | No operator shape metadata | **Shipped** — `SafeOpShapes` + `shape_of` inference | The high-value semantic lints |
| 4 | No source spans | **Shipped** — `SpecError.span`, byte range into `spec` | Squiggles, inline fixes |
| 5 | Method-table checks are session-dependent | Open — expose a registry fingerprint | Reproducible CI (a lint that passes with StatsBase loaded and fails without it) |
| 6 | Repair/vocabulary internals unexported (`nearest`, `didyoumean`, `ForeignSpellings`, `registry_summary`) | Open — but much less pressing now that `code`/`fix` are on the diagnostic | Consumers not reaching into internals |

Blockers 1 and 2 were the whole game: they turned an excellent human-facing
error system into a machine-facing one **without changing a single message**.
A consumer can now catch `SpecError`, branch on `code`, apply `fix` at `span`,
and report against `spec` — enough for a quick-fix provider, an agent repair
loop, an LSP diagnostic, or a CI check, with no regex over prose anywhere.

Blocker 3 has since shipped too (see *Operator shape* above): both template
bugs that motivated it — `mean(m) |> groupby(c)` and `where(any(b)) |>
groupby(c)` — are now parse-time rejections rather than runtime failures, and
the invalid pivot pattern turned out to have spread into four test assertions
here and into TermWin's own docstring and test, all corrected in the same pass.

The remaining semantic lints listed above (`first(_)` without `orderby`,
`count(_ > 0)` on a missing-capable column) need no further metadata — they are
now a matter of deciding on a *warning* severity, which `SpecError` does not yet
carry because nothing in the package has ever needed one.
