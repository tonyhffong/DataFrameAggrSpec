# Can an ordered window dimension sit in the middle of a chain?

*Design note, 2026-07. Question posed: "in most reasonable use cases a window
dim requiring an `orderby` modifier must be the last link of a chain, if used —
is there a counterexample?"*

## The hypothesis, and why it is usually right

A chain entry is a pivot level: its output column becomes a grouping key for
everything to its right and for `agg`'s final group-by.

The *generic* consumers of `orderby` — `cumsum` of a measure, `lag`, `lead`,
rank-style `collect(1:length(x))` — produce values that are (generically)
**distinct for every row within their partition**. Used mid-chain, such a
dimension **atomizes the partition**: every later level sees singleton groups,
and aggregation under it degenerates to the identity.

So a running total, a previous-value column, or a per-row rank is either

- the **terminal** pivot level (e.g. a rank as the leaf ordering level), or
- not a pivot level at all — a **side measure**, which since 0.5.0 lives in its
  own statement outside the chain by force of syntax.

That confirms the hypothesis for the common cases. The row-uniqueness argument
is the mechanism: it is not `orderby` itself that is terminal-only, it is
row-unique output.

## The counterexample family: ordered SEGMENTERS

There is a class of window computations that need `orderby` precisely in order
to produce a **discrete label**, whose entire purpose is to be grouped under —
i.e. they are *never* the last link:

1. **Sessionization** (the canonical one). Within each user, order events by
   time; a new session starts after a large gap:

   ```julia
   df = DataFrame(user = ["u1","u1","u1","u1","u2","u2"],
                  t    = [0, 5, 60, 62, 0, 90],
                  gap  = [0, 5, 55, 2, 0, 90],    # minutes since previous event
                  spend = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0])

   chain = [:user, :session => dim"cumsum(gap > 30) |> orderby(t)"]
   agg(df, chain; hints = AggrHints(:spend => aggr"sum", :t => aggr"minimum"))
   #  user  session  t   gap  spend
   #  u1    0        0    5     3.0     (events at t=0,5)
   #  u1    1        60  57    12.0     (events at t=60,62)
   #  u2    0        0    0    16.0
   #  u2    1        90  90    32.0     (gap: Real → default sum; use cols= to drop it)
   ```

   The session id *requires* ordering (a cumulative count of gap-breaks is
   meaningless unordered), and the whole point is to hang further levels or
   aggregation under it.

2. **Phase flags** — "before/after the running total crossed a threshold":

   ```julia
   [:user, :post5 => dim"(cumsum(spend) > 5) |> orderby(t)", :product]
   ```

   A Boolean phase key; then group products (or districts, or anything) within
   each phase.

3. **Run / streak ids** — change detection producing run-length group
   identifiers:

   ```julia
   [:asset, :streak => dim"cumsum(x != lag(x)) |> orderby(t)"]
   ```

   followed by grouping to measure streak lengths and per-streak statistics.

The common structure: **ordering feeds an accumulation that is then collapsed
to a coarse, discrete value** — a count of rare events, a threshold crossing, a
change detector. The collapse deliberately destroys the row-uniqueness that
makes generic ordered outputs terminal-only.

All three forms work in the current engine unmodified (verified against 0.6.0;
example re-run against 0.8.0 after `pivottable` merged into `agg` — the
sessionization table above is actual 0.8.0 output, and the phase-flag and
streak specs parse under the current safe grammar).

## Design implication

Do **not** encode an "`orderby` ⇒ must be last link" rule or lint. The property
that determines whether a dimension belongs mid-chain is the **discreteness of
its output**, not the presence of the `orderby` modifier — and discreteness is
a semantic property of what the spec computes (`cumsum(sales)` continuous;
`cumsum(gap > 30)` discrete), which cannot be read off the modifier or the
verb. A syntactic rule would reject sessionization, arguably the strongest use
case the ordered-window machinery has.

The existing structural rules already cover the degenerate cases:

- continuous **measures** cannot appear in chains at all (0.5.0: side measures
  are separate statements);
- a user who keys on a genuinely continuous ordered output gets the degeneracy
  they asked for, visibly (singleton groups), not silently wrong numbers.

Status: no code change. This note records the analysis so the "must be last"
rule is not introduced later without revisiting the segmenter family.
