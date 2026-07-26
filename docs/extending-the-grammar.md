# Extending the Grammar: writing your own safe operators

For **host developers** — a package or application embedding this DSL and
wanting vocabulary of its own. Everything here is host-side Julia code;
nothing in this document can be reached from a spec string, which is the
point.

The shipped vocabulary is documented in
[safe-aggregation-operators.md](safe-aggregation-operators.md) and
[safe-dimension-operators.md](safe-dimension-operators.md). This document is
about adding to it.

- [The rule](#the-rule)
- [The five-minute version](#the-five-minute-version)
- [Step 1: choose the shape](#step-1-choose-the-shape)
- [Step 2: make it take a column](#step-2-make-it-take-a-column)
- [Step 3: decide what a degenerate group returns](#step-3-decide-what-a-degenerate-group-returns)
- [Classifier verbs (labelling groups)](#classifier-verbs-labelling-groups)
- [The re-registration trap](#the-re-registration-trap)
- [What your operator gets for free](#what-your-operator-gets-for-free)
- [Checklist before you ship one](#checklist-before-you-ship-one)

## The rule

Extension is a **trusted act performed in host code**. `registerop!` is a
Julia function you call; there is no spec-string syntax that reaches it, and
a user typing into a text field can never add vocabulary. That is what keeps
the whitelist a whitelist.

Operator names may not contain `.` or `!`, and may not be `orderby` or
`groupby` (reserved modifier names). Both are enforced:

```julia
registerop!(Symbol("bad!"), identity)
# ERROR: registerop!: operator names may not contain '.' or '!', got 'bad!'
#        (alias the function under a clean name instead)
```

Registration affects the **untrusted string grammar only** (`aggr"..."` /
`dim"..."`). Trusted `Expr` specs are evaluated against `Main` and already
reach your package's functions by name, so they need no registration.

## The five-minute version

```julia
using DataFrameAggrSpec, Statistics

registerop!(:geomean, x -> exp(mean(log.(x))); shape = :reduce)

aggr"geomean(_)"                      # now parses
liftAggrSpecToFunc(:sales, aggr"geomean(_)")(df)
```

Three things make that line correct, and each is a section below: it declares
a **shape**, it accepts a **column** (a whole vector) rather than one value,
and it has been considered against **degenerate input**. Skip any of them and
the operator still registers — it just fails later, in someone else's frame.

## Step 1: choose the shape

`shape` says how many values your operator returns **relative to its input
rows**. It is a cardinality question, not a Julia-type question.

| `shape` | Meaning | Shipped examples |
|---|---|---|
| `:reduce` | whole vector → **one** value | `sum`, `mean`, `uniqvalue`, `hhi` |
| `:map` | one value **per row** | `cumsum`, `rank`, `lag`, `discretize` |
| `:elementwise` | follows its arguments (scalar in → scalar out) | `+`, `==`, `abs`, `coalesce`, `where` |
| `:filter` | many values, **not** row-aligned | `skipmissing` |
| `:unknown` | undeclared — the default | anything you don't declare |

**Probe, don't assume.** Call your function with a scalar and with a vector
and see what comes back; the name is not evidence. `where` looks like a `:map`
and is `:elementwise`, because `where(true)` returns a `String` while
`where([true, false])` returns a labelled vector. `unionall` returns a
`Vector` and is a `:reduce`, because one answer per group is the criterion —
not the return type.

**What you give up by omitting it.** `shape` is optional and defaults to
`:unknown`, which makes every shape check *skip* rather than guess. That is a
deliberate safety property (a check that is confidently wrong cannot be
appealed by the user), but it is not free — your users lose the parse-time
protection shipped operators give them:

```julia
registerop!(:mycum, cumsum)                  # no shape declared
aggr"mycum(_)"      # ACCEPTED — and drops [10, 40, 60, 100] into one cell

registerop!(:mycum, cumsum; shape = :map)    # declared
aggr"mycum(_)"      # rejected at parse time, like the shipped aggr"cumsum(_)":
                    # "this computes one value per ROW ... wrap it in a reduction"
```

Shape inference propagates through the whole expression, so one undeclared
operator anywhere silences the checks for that spec. Declare it.

`opshape(:mycum)` reports what is currently registered.

## Step 2: make it take a column

**Your operator is handed column vectors, not individual values.** This is the
most common first-attempt failure, because `registerop!` does *not* wrap your
function in anything — what you register is what gets called.

A `:reduce` or `:map` operator wants the vector anyway, so it just works. An
**`:elementwise`** operator usually does not:

```julia
band(x) = x > 25 ? "high" : "low"        # an ordinary scalar function
registerop!(:band, band; shape = :elementwise)

dim(df, [:b => dim"band(sales)"])
# ERROR: MethodError: no method matching isless(::Int64, ::Vector{Float64})
```

The error arrives at apply time, from inside a group-by, and says nothing
about broadcasting. Wrap the function yourself:

```julia
registerop!(:band, (x...) -> broadcast(band, x...); shape = :elementwise)
dim(df, [:b => dim"band(sales)"])        # ["low", "high", "low", "high"]
```

Forward keyword arguments too if your function takes any:

```julia
registerop!(:band, (x...; kw...) -> broadcast((a...) -> band(a...; kw...), x...);
            shape = :elementwise)
```

That wrapper is exactly what the shipped elementwise operators use internally.
Broadcasting is what makes `dim"sales * 1.2 + qty"` work without dots, so an
elementwise operator that does not broadcast is the odd one out in its own
grammar.

> **Keyword checking is all-or-nothing.** The parser validates option names
> against your function's method table, but a method that forwards `kwargs...`
> — including the wrapper above — disables that check for the operator. This
> is the same "undeclared means unchecked" principle as `shape`. Your users
> get `check_arity` either way.

## Step 3: decide what a degenerate group returns

A grouped computation meets inputs a REPL never shows you: an empty group, a
single row, a constant column, all-missing, a zero total. The package
convention is:

> **Return `missing` rather than a number you cannot stand behind.**

The reasoning is asymmetric risk. A `missing` in an output cell is *visible* —
it propagates, it renders, someone asks about it. A plausible-looking number
is not, and nothing downstream can distinguish it from a real answer. This is
why `hhi` returns `missing` on an empty group instead of `0.0` (which would
read as "perfect competition") and on a negative value instead of an
out-of-range figure; the same instinct makes `isuniform([])` false and
`wmeanfallback` return `missing` when every weight candidate fails. See
[design/expressiveness.md](../design/expressiveness.md), *When an expressible
measure earns a verb anyway*.

The naive spelling of a z-score shows the failure mode — a constant column
gives `std == 0`, and a single-row group gives `std == NaN`:

```julia
using Statistics

function zscore(x)
    s = std(x)
    (ismissing(s) || !isfinite(s) || s == 0) && return fill(missing, length(x))
    (x .- mean(x)) ./ s
end

registerop!(:zscore, zscore; shape = :map)
dim(df, [:region, :z => dim"zscore(sales)"])
```

Without the guard, every row of a single-row partition silently gets `NaN`,
and a constant partition gets `NaN` or `±Inf` depending on the row.

**Errors, when you do raise them.** A host verb validating its own arguments
raises an ordinary `ErrorException` (`error("...")`), not a `SpecError`.
`SpecError` means "something to report against the *user's spec text*", and
consumers catch it on exactly that assumption; keep your verb's internal
complaints out of that channel. Anything you throw during parsing still gets
tagged with the spec source automatically.

## Classifier verbs (labelling groups)

Most pivot verbs need **no registration at all**: the universal
`|> groupby(keys...)` modifier makes any verb pivot-kind, with the grouping
keys coming from the user's spec.

```julia
registerop!(:hilo, measure -> ...; shape = :map)
dim"hilo(sales) |> groupby(District)"          # nothing else needed
```

Register a **classifier** only when the grouping column is *data in the spec
itself* — the way `topnames(District, TestScr, 5)` takes its label column as
argument 1. Then `registerclassifier!` tells the engine which argument that
is, and pivot kind plus the grouping fix-up are inferred:

```julia
registerclassifier!(:tophalf, 1)               # argument 1 = the name column
```

Such verbs reject an additional `groupby` modifier, since their grouping is
already specified.

### What a classifier must return

The docs' skeleton (`(name, measure) -> ...`) leaves out the part that
matters. A classifier returns **one label per group**, and shipped classifiers
make those labels *presentation-ready*. This is a real contract, not a
decoration, and it has two halves:

**1. A fixed-width rank prefix, so lexical order is the intended order.**
Shipped labels look like `" 1. West"`, `" 9. s4"`, `"10. s3"`, `"Others"` —
space-padded to a constant width. That is what makes them sort correctly as
`CategoricalArray` levels, in a group-by, and in a rendered table, with no
custom comparator anywhere. Without the padding, `"10. …"` sorts before
`"2. …"` and the ordering is wrong everywhere the column appears.

**2. Return a `CategoricalArray` if you want one.** `PivotDim` preserves
categorical labels across context partitions, but it re-wraps **only when the
verb's own output was already categorical** — a plain `Vector{String}` stays
a plain `Vector{String}` all the way to the output frame. Since
`categorical(...)` sorts its levels lexically by default, half 1 above is what
makes half 2 come out in the right order for free:

```julia
using CategoricalArrays, Statistics

function tophalf(name, measure)
    med    = median(measure)
    w      = length(string(length(measure)))       # fixed prefix width
    labels = [m >= med ? lpad(1, w) * ". top half" : lpad(2, w) * ". bottom half"
              for m in measure]
    categorical(labels)
end

registerop!(:tophalf, tophalf; shape = :map)
registerclassifier!(:tophalf, 1)

dim(df, [:County, :half => dim"tophalf(District, TestScr)"])
```

Drop the `categorical(...)` and everything still runs — you simply get an
ordinary string column, which is a legitimate choice if the labels are not
meant to be a display dimension.

## The re-registration trap

**Registering an operator a second time under the same name does not change
what already-parsed specs do — including specs parsed from identical text.**

Parsed specs are cached by source string, and a cached spec holds a closure
over the operator as it was at first parse. This bites during exactly the
loop you use to develop an operator:

```julia
registerop!(:ver, x -> "v1"; shape = :reduce)
parseaggr("ver(_)").f([1, 2])          # "v1"   — try it

registerop!(:ver, x -> "v2"; shape = :reduce)   # fix the implementation
parseaggr("ver(_)").f([1, 2])          # "v1"   ← still the old one
parseaggr("ver( _ )").f([1, 2])        # "v2"   ← different text, cache miss
```

Call `clearcaches!()` after re-registering:

```julia
registerop!(:ver, x -> "v2"; shape = :reduce)
clearcaches!()
parseaggr("ver(_)").f([1, 2])          # "v2"
```

It drops all three memos — parsed specs, lifted aggregators and window kernels
— which is what you want, since the `agg`/`AggrHints` path holds a second
cached layer beyond the parsed spec. Everything dropped is a pure memo; the
next parse or apply recomputes it.

Registering a **new** name is always safe and needs no clearing, so a host
package that registers once at load time never calls this. It is the REPL,
test-file and plugin-reload path.

In a host package, this rarely matters because registration happens once at
load time. In a REPL or a test file that re-registers, it matters immediately.

## What your operator gets for free

Every guidance surface reads the registry **live**, so one `registerop!` call
puts your operator into all of these at once, with nothing else to update:

```julia
registerop!(:taxed, x -> 1.2 .* x; shape = :elementwise)

listops()                       # includes :taxed
spec_vocabulary(:dim)           # includes "taxed" — Tab completion in a host UI
parsedim("taxd(sales)")
# ERROR: unknown function 'taxd' -- did you mean 'taxed'?    (OSA repair)
```

**The one surface it does not reach is `spec_templates`.** Templates are a
curated, narrowed *ranking* — a starter list, deliberately not a catalogue of
everything registered — so host operators never appear there and there is no
opt-in. If your host UI wants to propose them, concatenate your own
suggestions onto `spec_templates(...)`; the returned order is a suggestion
ranking, not a stable sequence, so a host that cares about order should sort
the result anyway.

## Checklist before you ship one

1. **Does it already exist?** Check `listops()`, and check
   [design/expressiveness.md](../design/expressiveness.md) — several
   plausible operators (`ifelse`, `&`/`|`, `unique`, aliases for Base names)
   were considered and declined, with reasons that apply to host packages too.
2. **Does it wrap a Base/stdlib function?** Then keep that function's name.
   The registry is a projection of Julia so that vocabulary stays portable
   across the trust boundary; a private alias breaks that for your users.
3. **Is it expressible already?** `sum(_ * wt) / sum(wt)` needs no operator.
   The sanctioned exception is an operator whose expressible form returns a
   *plausible-looking wrong number* on degenerate input — that difference in
   contract is the justification, and it is worth stating in your docstring.
4. **Declare the shape**, probed rather than assumed.
5. **Broadcast** if it is `:elementwise`.
6. **Decide the degenerate cases**, preferring `missing` over a number.
7. **Keep it pure.** Registered operators are assumed side-effect-free and may
   be called per group, per partition, and in any order. This is invariant R9
   in [design/composition-rules.md](../design/composition-rules.md) and is
   *not enforced* — an impure operator produces results that vary with
   grouping, which is very hard to debug.
8. **Test it through the grammar, not just as a function.** Parse it, apply
   it, and test the degenerate group:

   ```julia
   @test aggr"geomean(_)".f([1.0, 4.0]) ≈ 2.0        # through the DSL
   @test opshape(:geomean) == :reduce                 # shape as declared
   @test ismissing(zscore(Float64[])[1] for _ in [])  # degenerate input
   ```

9. **Document it where your users look.** The two shipped operator documents
   cover the defaults only; host operators are deliberately not listed there,
   so they need a page in your own docs.
