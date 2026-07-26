# The whitelist REGISTRY of the untrusted DSL: which operations a spec string
# may name, and what each one does to cardinality.
#
# Extension is a trusted act performed in host code (registerop! /
# registerclassifier!), never through a spec string -- the grammar can only
# reach names that are already here.
#
# INCLUDE ORDER: after verbs.jl, whose verbs the default registration block
# below references at LOAD time. That block, the DefaultSafeOps snapshot and
# the topnames classifier registration are the only things in the whole
# safe-DSL cluster that evaluate at load rather than at call time, which is
# what leaves the rest of the cluster free to be ordered for readability.

const SafeOps = Dict{Symbol,Base.Callable}()   # Callable: constructors (Weights) too

# postfix MODIFIER names: `spec ∘ modifier(cols...)` / `spec |> modifier(cols...)`
# attach engine metadata to a dim spec:
#   orderby(cols...) -- window ordering (sort the partition before the kernel)
#   groupby(keys...) -- pivot grouping: aggregate the spec's measure columns at
#                       this granularity (per AggrHints) BEFORE the verb
#                       classifies; the table is never reduced -- each group's
#                       label broadcasts back to its member rows
# Modifiers are peeled structurally at parse time (peel_modifiers) and are
# never called -- reserve their names so a host cannot shadow them.
const SafeModifiers = (:orderby, :groupby)

# ---- operator SHAPE ---------------------------------------------------------
# How many values an operator returns RELATIVE TO ITS INPUT ROWS. This is a
# cardinality axis, not a Julia-type axis: `unionall` returns a Vector and is
# still a :reduce (one answer for the whole group), while `where` returns a
# String for a scalar condition and a vector for a vector one, so it is
# :elementwise.
#
#   :reduce       whole vector -> ONE value            sum, mean, uniqvalue, unionall
#   :map          one value per input row              cumsum, rank, lag, discretize
#   :elementwise  follows its arguments (scalar in,    +, ==, abs, coalesce, where
#                 scalar out; vector in, vector out)
#   :filter       many values, NOT row-aligned         skipmissing
#   :unknown      not declared -- inference gives up, and every shape check
#                 SKIPS rather than guessing
#
# `:unknown` is the default for `registerop!`, on the same principle as
# check_arity/check_kwargs: a guidance check that is confidently wrong is worse
# than one that is absent, because the user cannot appeal it. A host that wants
# its verb shape-checked opts in by declaring one.
#
# Known imprecision, recorded rather than engineered around: shape is per NAME,
# not per arity, so `first(v)` (:reduce, correct) and the exotic `first(v, 3)`
# (really a map) share one label. Nothing in the shipped grammar reaches the
# second form, and arity-dependent shapes would cost far more than they buy.
const SafeOpShapes = Dict{Symbol,Symbol}()

const OpShapeKinds = (:reduce, :map, :elementwise, :filter, :unknown)

"""
    opshape(name::Symbol) -> Symbol

How many values the registered operator `name` returns relative to its input
rows: `:reduce` (one per group), `:map` (one per row), `:elementwise` (follows
its arguments), `:filter` (many, not row-aligned), or `:unknown` when the
operator has not declared one — including every name that is not registered.

Drives the parse-time shape checks (an aggregation must reduce to one value; a
`groupby` dimension must produce one label per group) and is exposed for linters
and hosts. See `design/user-guidance.md`.
"""
opshape(name::Symbol) = get(SafeOpShapes, name, :unknown)

# single registration point, so SafeOps and SafeOpShapes cannot drift apart
function _register!(name::Symbol, f::Base.Callable, shape::Symbol)
    in(shape, OpShapeKinds) || error(
        "registerop!: shape must be one of " * join(OpShapeKinds, ", ") *
        ", got '" * string(shape) * "'" * didyoumean(shape, OpShapeKinds))
    SafeOps[name] = f
    shape === :unknown ? delete!(SafeOpShapes, name) : (SafeOpShapes[name] = shape)
    f
end

# extension is a trusted act done in host code, never via spec strings
function registerop!(name::Symbol, f::Base.Callable; shape::Symbol = :unknown)
    s = string(name)
    if occursin(".", s) || occursin("!", s)
        error("registerop!: operator names may not contain '.' or '!', got '" * s *
              "' (alias the function under a clean name instead)")
    end
    if in(name, SafeModifiers)
        error("registerop!: '" * s * "' is a reserved modifier name")
    end
    _register!(name, f, shape)
end

listops() = sort!(collect(keys(SafeOps)))

# broadcasting wrapper: kwargs are forwarded to each elementwise application
bcast(f) = (args...; kwargs...) -> Base.broadcast((a...) -> f(a...; kwargs...), args...)

# ---- default registry -------------------------------------------------------
# Grouped by SHAPE (see above), which makes the registry self-documenting about
# what each verb does to cardinality -- and makes "did I put this in the right
# group" the review question when an operator is added.

# :reduce -- whole vector in, ONE value out. `unionall` and `extrema` return
# containers and still belong here: one answer per group is the criterion.
for f in (sum, prod, mean, median, std, var, quantile, minimum, maximum, extrema,
          length, count, first, last, any, all,
          uniqvalue, countuniq, unionall, strjoinuniq, wmeanfallback)
    _register!(Symbol(f), f, :reduce)
end

# :map -- one value per input ROW. These genuinely need the vector (each
# rejects a scalar argument outright), which is what makes the "nothing to map
# over" check below decidable.
for f in (topnames, discretize, quantiles, lag, lead,
          cumsum, cumprod, rank, denserank, ordinalrank, tiedrank)
    _register!(Symbol(f), f, :map)
end

# :filter -- many values out, but NOT one per input row, so it is neither a
# reduction nor row-aligned. Only skipmissing; it exists to feed a reducer.
_register!(:skipmissing, skipmissing, :filter)

# `where` is :elementwise, NOT :map -- it broadcasts over its condition, so it
# returns a String for a scalar condition and a labelled vector for a vector
# one. That is what makes aggr"where(sum(_) > 100)" (label the GROUP by its
# total) and dim"where(sales > 12)" (label each ROW) both legal and correctly
# distinguished, and what lets the pivot check catch a scalar condition under
# `groupby`.
_register!(:where, where, :elementwise)

# nrow: DataFrames.jl-flavored alias for length -- group row count without
# reaching for `count`, whose Base semantics (number of trues) are unrelated
_register!(:nrow, length, :reduce)

# scalar functions apply elementwise to columns. ismissing/coalesce are the
# row-level missing tools (flag / replace -- skipmissing covers drop); they
# ship under their Julia names on purpose: the registry is a projection of
# Julia, so specs keep the same vocabulary across the trust boundary.
for f in (abs, log, log2, log10, exp, sqrt, round, floor, ceil, min, max,
          ismissing, coalesce)
    _register!(Symbol(f), bcast(f), :elementwise)
end

# date-bucketing labels (verbs.jl): scalar verbs, elementwise over columns
for f in (yyyy, yyyyq, yyq, yyyymm, yymm)
    _register!(Symbol(f), bcast(f), :elementwise)
end

# operators: undotted and dotted spellings bind to the same broadcasting closure
# (! ships here directly -- registerop!'s '!' ban is a rule for HOST names)
for (name, f) in Any[
    (:+, +), (:-, -), (:*, *), (:/, /), (:^, ^),
    (:(==), ==), (:!=, !=), (:<, <), (:<=, <=), (:>, >), (:>=, >=),
    (:≠, !=), (:≤, <=), (:≥, >=), (:!, !),
]
    b = bcast(f)
    _register!(name, b, :elementwise)
    _register!(Symbol("." * string(name)), b, :elementwise)
end

# `in`: SQL/dplyr-style membership, `x in [1, 2, 5]`. Julia lowers infix `in`
# to an ordinary :call (fname :in), so it reaches the compiler and the
# registry exactly like any other operator -- no structural special case
# needed. NOT bcast(in): that would broadcast over the collection argument
# too (zip semantics -- silently wrong when the item and collection lengths
# happen to match, a shape error otherwise). Ref-protect the collection so it
# is compared as a WHOLE, once per item, whether it came from a literal
# array or a column.
_register!(:in, (x, coll) -> Base.broadcast(in, x, Ref(coll)), :elementwise)

# ∈ / ∉: Unicode spellings. `Base.:∈ === in` (the identical function, just a
# second token the parser accepts -- unlike `≠`/`≤`/`≥`, which are distinct
# functions wrapping the same closure), so this is a shared reference, not a
# copy. `∉` is `in`'s negation and needs its own Ref-protected closure.
_register!(:∈, SafeOps[:in], :elementwise)
_register!(:∉, (x, coll) -> Base.broadcast(Base.:∉, x, Ref(coll)), :elementwise)

# snapshot of the shipped registry, before any host registerop! calls.
# EVERY operator here must be documented in docs/safe-aggregation-operators.md
# or docs/safe-dimension-operators.md -- a testset in test/safe.jl enforces it.
const DefaultSafeOps = sort!(collect(keys(SafeOps)))

# ---- classifier verbs -------------------------------------------------------
# Pivot-kind dimension verbs whose grouping column is DATA in the spec itself
# (topnames' 1st argument is the label source). name => argument position of
# that single grouping/label column. The table drives kind inference (autokind,
# chain.jl) and the by-fixup (pivot_groupkeys, dimension.jl) for BOTH
# trusted-Expr and safe-string specs.
#
# Most pivot verbs need NO registration: the universal `|> groupby(keys...)`
# modifier marks any spec pivot-kind with those inner grouping keys. Register a
# classifier only when the grouping column doubles as verb data; such verbs
# reject an additional groupby modifier.
const ClassifierVerbs = Dict{Symbol,Int}()

function registerclassifier!(name::Symbol, argpos::Integer)
    ClassifierVerbs[name] = Int(argpos)
    nothing
end

registerclassifier!(:topnames, 1)
