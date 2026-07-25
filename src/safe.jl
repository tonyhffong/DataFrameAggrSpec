# The UNTRUSTED spec DSL: aggr"..." / dim"..." and their runtime entry points
# parseaggr / parsedim, for TUI/GUI hosts that accept spec strings from end
# users. Safety comes from a whitelist registry (SafeOps) plus a default-deny
# grammar interpreted by a closure compiler -- there is NO eval anywhere on
# this path, so it shares nothing with the trusted compiler except the
# (f, cols) kernel contract, and the resulting closures live at the current
# world age (no Base.invokelatest needed).
#
# Grammar (deliberately spreadsheet-flavored):
#   * bare identifier  = column reference, in every position (District, wt)
#   * _                = the aggregation target column (aggr specs only)
#   * :sym             = a Symbol literal (kwarg options: boundedness = :boundedbelow)
#   * literals         = numbers, strings, true/false, [ ... ] arrays
#   * whitelisted calls, nestable; kwargs in either `f(x, k = v)` or `f(x; k = v)` form
#   * arithmetic/comparison operators are whitelisted with BROADCAST semantics
#     (vector op scalar and vector op vector both work; no dots needed, dotted
#     forms are aliases)
#   * a NESTED `inner |> groupby(keys...)` is a grouped reduction: `inner`
#     evaluated per distinct key combination, results collected into a vector
#     sorted by key -- the composite-aggregation node,
#     aggr"mean(sum(_) |> groupby(year))" (see compile_grouped)
# Everything else -- qualified names, macros, interpolation, lambdas, indexing,
# blocks, comprehensions, splats, ternaries -- is rejected with a clear error.
# Note one wrinkle of "bare identifier = column": `missing`, `pi`, `Inf` are
# identifiers, hence column references, not constants.
#
# INCLUDE ORDER: this file loads after verbs.jl (the registry references verbs)
# and BEFORE dimension.jl (whose signatures mention SafeDimSpec). One deliberate
# exception cuts the other way: liftAggrSpecToFunc's SafeAggrSpec method calls
# order_indices, defined later in dimension.jl with the rest of the ordering
# primitives. That is fine -- the call sits inside a runtime closure, so the
# name resolves at call time (whole module loaded), not at include time. Keep
# any NEW backward reference to the same shape: runtime-only, never top level.

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

# ---- spec types -------------------------------------------------------------

struct SafeAggrSpec
    source::String          # exact (stripped) user string
    fname::Symbol           # top-level function name
    f::Function             # (colvec1, colvec2, ...) -> value; arg order = cols
    cols::Vector{Symbol}    # first-encounter order; may contain :_
    order::Vector{Pair{Symbol,Bool}}  # from a peeled `|> orderby(cols...)`;
                                      # sort the group's rows before f runs --
                                      # order-sensitive verbs (first, last, ...)
                                      # need it, order-insensitive ones (sum,
                                      # mean, ...) silently ignore it, same as
                                      # rank/denserank/tiedrank do on the dim
                                      # side. A top-level `groupby` is still
                                      # rejected (see parseaggr_impl) -- that
                                      # stays the nested-composite-reduction
                                      # feature.
end

# a `groupby(...)` key that is a COMPUTED expression rather than a bare
# column (e.g. yyyymm(date)) -- gensym'd synthetic column name to materialize
# before DataFrames.groupby (PivotDim's inner grouping requires real
# columns), the compiled elementwise thunk (compile_node contract:
# f(vals::Tuple) -> vector, same call convention as compile_grouped's nested
# groupby keys), and the REAL columns it reads. required_columns/checkcols
# validate `.cols`, never `.name` -- the synthetic name is not a column that
# exists on the host's frame.
struct GroupByKey
    name::Symbol
    f::Function
    cols::Vector{Symbol}
end

struct SafeDimSpec
    source::String
    fname::Symbol
    f::Function
    cols::Vector{Symbol}   # :_ forbidden (checked at parse)
    posargs::Vector{Any}   # simplified top-level positional args: Symbol (bare
                           # column), Vector{Symbol} ([col, ...] array), else
                           # nothing -- feeds pivot_groupkeys (topnames)
    order::Vector{Pair{Symbol,Bool}}  # from a peeled `|> orderby(cols...)`;
                                      # consumed by WindowDim
    by::Vector{Union{Symbol,GroupByKey}}  # from a peeled `|> groupby(keys...)`;
end                        # marks pivot kind, consumed by PivotDim as its
                           # inner grouping -- entries are bare columns or
                           # computed GroupByKeys

Base.:(==)(a::SafeAggrSpec, b::SafeAggrSpec) = a.source == b.source
Base.hash(a::SafeAggrSpec, h::UInt) = hash((:SafeAggrSpec, a.source), h)
Base.show(io::IO, s::SafeAggrSpec) = print(io, "aggr\"", s.source, "\"")

Base.:(==)(a::SafeDimSpec, b::SafeDimSpec) = a.source == b.source
Base.hash(a::SafeDimSpec, h::UInt) = hash((:SafeDimSpec, a.source), h)
Base.show(io::IO, s::SafeDimSpec) = print(io, "dim\"", s.source, "\"")

# ---- AST -> closure compiler ------------------------------------------------

# tailored rejection messages for syntax an end user (or attacker) will hit
const SafeRejections = Dict{Symbol,String}(
    Symbol(".") => "qualified names (A.B) and broadcast calls (f.(x)) are not allowed; hosts can register functions under a plain name with registerop!",
    :curly => "type parameters are not allowed",
    :macrocall => "macros (and command literals) are not allowed",
    :$ => "interpolation is not allowed",
    :string => "string interpolation is not allowed",
    Symbol("->") => "anonymous functions are not allowed",
    :do => "do-blocks are not allowed",
    :block => "blocks are not allowed",
    Symbol("=") => "assignment is not allowed",
    :ref => "indexing is not allowed",
    :comparison => "chained comparisons are not allowed -- combine single " *
                    "comparisons with && (10 < x < 20 becomes x > 10 && x < 20)",
    Symbol("...") => "splatting is not allowed",
    :tuple => "tuples are not allowed",
    :generator => "comprehensions are not allowed",
    :comprehension => "comprehensions are not allowed",
    :flatten => "comprehensions are not allowed",
    :quote => "nested quoting is not allowed",
    :if => "conditionals are not allowed",
)

function colindex!(cols::Vector{Symbol}, c::Symbol)
    i = findfirst(==(c), cols)
    i === nothing ? (push!(cols, c); length(cols)) : i
end

# reminder shown when a modifier name is used (or repaired to) in call position
modifier_reminder(m::Symbol) =
    m == :orderby ?
    "'orderby' is a postfix modifier, not a function -- write the spec " *
    "first: \"cumsum(sales) |> orderby(date)\" (dim specs only)" :
    "'groupby' is a postfix modifier, not a function -- write the spec " *
    "first: \"mean(x) |> groupby(key)\" aggregates the measure per key " *
    "before the verb classifies (dim specs only)"

# Spellings a user arrives with from SQL, dplyr, pandas or Excel, mapped to what
# this grammar calls the same thing. These are NOT aliases -- the registry keeps
# exactly one spelling per concept (design/expressiveness.md) and the spec still
# FAILS. They exist because the OSA repair below can only rescue a misspelling
# of a whitelisted word: `avg` is four edits from `mean`, so a user typing it
# has no way to guess the local name from the rejection alone. Keyed by the
# UNDERSCORE-STRIPPED, lowercased name, so `row_number`/`ROW_NUMBER` land here
# too. Values complete the sentence "Use ___ instead."
const ForeignSpellings = Dict{Symbol,String}(
    :avg            => "mean(x)",
    :average        => "mean(x)",
    :stddev         => "std(x)",
    :stdev          => "std(x)",
    :sd             => "std(x)",
    :variance       => "var(x)",
    :n              => "nrow (the group's row count -- aggr\"nrow\")",
    :rowcount       => "nrow",
    :size           => "nrow for the group's row count, or length(x)",
    :len            => "length(x)",
    :nunique        => "countuniq(x)",
    :ndistinct      => "countuniq(x)",
    :countdistinct  => "countuniq(x)",
    :distinct       => "countuniq(x) to count them, uniqvalue(x) for the one " *
                       "distinct value, or strjoinuniq(x) to list them",
    :unique         => "countuniq(x) to count them, uniqvalue(x) for the one " *
                       "distinct value, or strjoinuniq(x) to list them",
    :groupconcat    => "strjoinuniq(x)",
    :stringagg      => "strjoinuniq(x)",
    :listagg        => "strjoinuniq(x)",
    :concat         => "strjoinuniq(x)",
    :strjoin        => "strjoinuniq(x)",
    :ifelse         => "where(cond), which labels both sides -- or plain " *
                       "arithmetic, e.g. x * (x > 0)",
    :ifthen         => "where(cond)",
    :iif            => "where(cond)",
    :casewhen       => "where(cond) for a two-way split, or " *
                       "discretize(x, breaks) for numeric bands",
    :switch         => "where(cond), or discretize(x, breaks) for numeric bands",
    :filter         => "where(cond) as a chain key, then reduce",
    :subset         => "where(cond) as a chain key, then reduce",
    :rownumber      => "ordinalrank(x)",
    :rowid          => "ordinalrank(x)",
    :ntile          => "quantiles(x, ngroups = 4)",
    :percentile     => "quantile(x, 0.9)",
    :percentilecont => "quantile(x, 0.9)",
    :top            => "topnames(labels, values, n)",
    :topn           => "topnames(labels, values, n)",
    :cut            => "discretize(x, breaks)",
    :bin            => "discretize(x, breaks)",
    :ifnull         => "coalesce(x, 0)",
    :nvl            => "coalesce(x, 0)",
    :isnull         => "ismissing(x) to flag it, coalesce(x, 0) to replace it",
    :isna           => "ismissing(x) to flag it, coalesce(x, 0) to replace it",
    :fillna         => "coalesce(x, 0)",
    :fillmissing    => "coalesce(x, 0)",
    :dropna         => "skipmissing(x)",
    :dropmissing    => "skipmissing(x)",
    :naomit         => "skipmissing(x)",
    :argmax         => "last(_) |> orderby(col) -- the value at col's maximum",
    :argmin         => "first(_) |> orderby(col) -- the value at col's minimum",
    :maxby          => "last(_) |> orderby(col)",
    :minby          => "first(_) |> orderby(col)",
    :shift          => "lag(x) or lead(x)",
    :runningtotal   => "cumsum(x)",
    :sumif          => "sum(x * (cond)) -- the condition is just a column " *
                       "expression",
    :countif        => "count(cond)",
)

# lookup key for ForeignSpellings and the no-underscores redirect
squash(name) = Symbol(replace(lowercase(string(name)), "_" => ""))

# the whitelist as a user should read it. The symbolic entries (dotted aliases,
# unicode twins) are two thirds of listops() and teach nothing when spelled out
# one by one, so they are summarized instead.
function registry_summary()
    named = [s for s in string.(listops()) if isidenttoken(s)]
    "Named operations: " * join(named, ", ") *
    ". Operators: + - * / ^ == != < <= > >= (plus their dotted and unicode " *
    "spellings) and && / || for conditions. " *
    "(listops() shows the live registry; hosts extend it with registerop!.)"
end

# unknown function in call position. Ordered most-specific first: a structural
# redirect, a modifier misuse, the foreign-spelling table, an OSA repair, and
# only then the registry dump -- which is the discovery mechanism of last
# resort, when the package has nothing better to offer than the vocabulary.
function unknown_op_error(what::String, fname::Symbol)
    # DataFrames muscle memory: .& / .| are spelled && / || in this grammar
    if in(fname, (Symbol("&"), Symbol("|"), Symbol(".&"), Symbol(".|")))
        c = in(fname, (Symbol("&"), Symbol(".&"))) ? "&&" : "||"
        specerror(what * ": '" * string(fname) * "' is not an operator here -- " *
                  "combine conditions with '" * c * "' (pure elementwise over " *
                  "columns; binds looser than comparisons, so no parentheses " *
                  "needed: a > 1 " * c * " b < 2)";
                  code = :boolean_operator, token = fname, fix = Symbol(c))
    end
    in(fname, SafeModifiers) && specerror(what * ": " * modifier_reminder(fname);
                                          code = :modifier_misuse, token = fname)
    sq = squash(fname)
    # `dense_rank`, `ROW_NUMBER`: the concept exists, the spelling does not
    # (operator names carry no underscores -- design/expressiveness.md)
    if sq !== fname && haskey(SafeOps, sq)
        specerror(what * ": '" * string(fname) * "' is not registered -- write it " *
                  "as '" * string(sq) * "' (operator names are lowercase and carry " *
                  "no underscores).";
                  code = :spelling_convention, token = fname, fix = sq)
    end
    if haskey(ForeignSpellings, sq)
        # no `fix`: the table's values complete "Use ___ instead" in prose
        # ("nrow (the group's row count -- ...)"), so they are advice rather
        # than a substitution. Deriving a token from prose is the kind of
        # guessing G3 forbids.
        specerror(what * ": '" * string(fname) * "' is not registered here -- use " *
                  ForeignSpellings[sq] * ". (listops() shows the whitelist; " *
                  "hosts can extend it with registerop!.)";
                  code = :foreign_spelling, token = fname)
    end
    n = nearest(string(fname), vcat(listops(), collect(SafeModifiers)))
    if n isa Symbol && in(n, SafeModifiers)
        specerror(what * ": unknown function '" * string(fname) * "'. " *
                  modifier_reminder(n);
                  code = :modifier_misuse, token = fname)
    elseif n !== nothing
        specerror(what * ": unknown function '" * string(fname) *
                  "' -- did you mean '" * string(n) * "'? (listops() shows the " *
                  "whitelist; hosts can extend it with registerop!.)";
                  code = :unknown_op, token = fname, fix = n)
    end
    specerror(what * ": unknown function '" * string(fname) * "'. " *
              registry_summary(); code = :unknown_op, token = fname)
end

# a literal where a grouping key belongs. Both `groupby` paths (the nested
# composite reduction and the top-level modifier) funnel here so the colon and
# quote habits -- by far the commonest way to write this wrong, since every
# other DataFrames API wants `:col` or `"col"` -- get named as such instead of
# being reported as "a literal".
function groupby_literal_error(what::String, a)
    # both quoting habits have a genuine drop-in fix: strip the colon/quotes
    if isa(a, QuoteNode) && isa(a.value, Symbol)
        specerror(what * ": ':" * string(a.value) * "' is a Symbol literal -- a " *
                  "grouping key is a bare column name, written without the colon: " *
                  "groupby(" * string(a.value) * ")";
                  code = :groupby_literal, token = a.value, fix = a.value)
    end
    isa(a, AbstractString) && Base.isidentifier(a) && specerror(
        what * ": " * repr(a) * " is a string literal -- a grouping key is a " *
        "bare column name, written without the quotes: groupby(" * a * ")";
        code = :groupby_literal, token = Symbol(a), fix = Symbol(a))
    specerror(what * ": groupby keys must be columns (or elementwise transforms " *
              "of columns, e.g. yyyy(t)), got the literal " * repr(a);
              code = :groupby_literal)
end

# would unknown_op_error have something concrete to say about this name, or
# would it fall through to the registry dump? Call sites that have a BETTER
# story for an unrepairable name (a bare identifier is far likelier to be a
# column than a mistyped verb) use this to choose which error to raise.
op_is_repairable(fname::Symbol) =
    in(fname, SafeModifiers) ||
    haskey(SafeOps, squash(fname)) ||
    haskey(ForeignSpellings, squash(fname)) ||
    nearest(string(fname), vcat(listops(), collect(SafeModifiers))) !== nothing

# ---- call-shape validation --------------------------------------------------
# Arity and keyword-name mistakes used to parse cleanly and then surface as a
# raw MethodError from inside a group-by -- with no mention of the spec that
# caused it. Both are decidable at parse time from the registered function's
# own method table, so they are decided here.

# positional-arity envelope of a registered function. A bcast-wrapped op (or
# any `(args...)` closure) reports no upper bound and is therefore never
# rejected: the check fires only when NO method could accept the given count.
# The envelope is read off the LIVE method table, so it widens when the host
# session loads a package that extends the name (StatsBase gives `sum` and
# `quantile` weighted methods). That is correct -- the registry holds the
# function object, so those methods really are callable from a spec.
function arity_range(f)
    lo, hi, va = typemax(Int), 0, false
    for m in methods(f)
        n = m.nargs - 1                  # nargs counts the function itself
        if m.isva
            va = true
            n -= 1
        end
        lo = min(lo, n)
        hi = max(hi, n)
    end
    lo == typemax(Int) && return (0, typemax(Int))   # no methods: do not guess
    (lo, va ? typemax(Int) : hi)
end

# a readable signature for THIS package's verbs, whose argument names are
# written for a reader (topnames(name, measure, n)). Base's are terse
# internals (sum's widest method is `sum(f, a)`) and would mislead, so the
# hint stops at the module boundary.
function usage_hint(fname::Symbol, f)
    best, bestn = nothing, -1
    for m in methods(f)
        (m.module === @__MODULE__) || continue
        n = m.nargs - 1 - (m.isva ? 1 : 0)
        n > bestn || continue
        names = Base.method_argnames(m)[2:end]
        all(x -> !occursin('#', string(x)), names) || continue
        best, bestn = names, n
    end
    best === nothing ? "" : " -- " * string(fname) * "(" * join(best, ", ") * ")"
end

function check_arity(what::String, fname::Symbol, op, n::Int)
    lo, hi = arity_range(op)
    lo <= n <= hi && return nothing
    expected = lo == hi ? string(lo) :
               hi == typemax(Int) ? "at least " * string(lo) :
               string(lo) * " to " * string(hi)
    hint = usage_hint(fname, op)
    if isempty(hint) && n == 0
        hint = lo == 1 ? " -- name the column it works on, e.g. '" *
                         string(fname) * "(sales)'" :
                         " -- name the columns it works on"
    end
    specerror(what * ": '" * string(fname) * "' takes " * expected *
              (lo == 1 && hi == 1 ? " positional argument, got " :
               " positional arguments, got ") * string(n) * hint *
              ". (Options go in keyword form: f(x, opt = value).)";
              code = :arity, token = fname)
end

# the keyword names a registered function accepts, or `nothing` when it
# forwards arbitrary keywords (bcast wrappers, discretize's formatter passthrough)
# and no useful check is possible
function op_kwargs(f)
    accepted = Symbol[]
    for m in methods(f)
        for k in Base.kwarg_decl(m)
            endswith(string(k), "...") && return nothing
            in(k, accepted) || push!(accepted, k)
        end
    end
    sort!(accepted)
end

function check_kwargs(what::String, fname::Symbol, op, kws::Vector{Symbol})
    isempty(kws) && return nothing
    accepted = op_kwargs(op)
    accepted === nothing && return nothing
    for k in kws
        in(k, accepted) && continue
        isempty(accepted) && specerror(
            what * ": '" * string(fname) * "' takes no keyword options, got '" *
            string(k) * "'"; code = :unknown_kwarg, token = k)
        r = repair(k, accepted)
        specerror(what * ": '" * string(fname) * "' has no keyword option '" *
                  string(k) * "'" * r.hint * ". Accepted: " *
                  join(accepted, ", ");
                  code = :unknown_kwarg, token = k, fix = r.fix)
    end
    nothing
end

# compile a node to a thunk `vals::Tuple -> value`, where vals are the column
# vectors in `cols` (first-encounter) order. Default-deny: only the node kinds
# below exist in the untrusted language.
function compile_node(ex, cols::Vector{Symbol}, what::String)
    if isa(ex, Symbol)                       # bare identifier = column (incl. _)
        i = colindex!(cols, ex)
        return vals -> vals[i]
    elseif isa(ex, QuoteNode)                # :sym literal
        isa(ex.value, Symbol) ||
            error(what * ": unsupported quoted literal " * repr(ex.value))
        v = ex.value
        return vals -> v
    elseif isa(ex, Union{Number,AbstractString,Char})
        return vals -> ex
    elseif isa(ex, Expr) && ex.head == :vect
        ts = Function[compile_node(a, cols, what) for a in ex.args]
        return vals -> Base.vect((t(vals) for t in ts)...)
    elseif isa(ex, Expr) && (ex.head == :(&&) || ex.head == :(||))
        # && / || are control flow in Julia (their own heads, not :call), so
        # they cannot live in the registry -- translated structurally to PURE
        # elementwise and/or: both sides always evaluated, missing propagates
        # (Kleene). The payoff is precedence: they bind looser than
        # comparisons, so `a > 1 && b < 2` needs no parentheses.
        op = ex.head == :(&&) ? (&) : (|)
        lt = compile_node(ex.args[1], cols, what)
        rt = compile_node(ex.args[2], cols, what)
        return vals -> Base.broadcast(op, lt(vals), rt(vals))
    elseif isa(ex, Expr) && ismodifiershape(ex)
        # `a |> b` / `a ∘ b` reaching the compiler is NESTED (top-level
        # modifiers are peeled by peel_modifiers / gated by parseaggr first)
        return compile_grouped(ex, cols, what)
    elseif isa(ex, Expr) && ex.head == :call
        return compile_call(ex, cols, what)
    elseif isa(ex, Expr) && haskey(SafeRejections, ex.head)
        specerror(what * ": " * SafeRejections[ex.head] * " (in \"" * string(ex) * "\")";
                  code = :unsupported_syntax, token = ex.head)
    else
        specerror(what * ": unsupported syntax '" *
                  (isa(ex, Expr) ? string(ex.head) : string(typeof(ex))) *
                  "' in \"" * string(ex) * "\"";
                  code = :unsupported_syntax)
    end
end

function compile_call(ex::Expr, cols::Vector{Symbol}, what::String)
    fname = ex.args[1]
    if !isa(fname, Symbol)
        if Base.Meta.isexpr(fname, :(.))
            # `spec.orderby(...)` -- the dotted modifier separator, which this
            # grammar deliberately does not have (design/glyph-choice.md).
            # Without this branch it reads as an ordinary qualified name and
            # the user is told about registerop!, which is not their problem.
            m = length(fname.args) == 2 && isa(fname.args[2], QuoteNode) ?
                fname.args[2].value : nothing
            isa(m, Symbol) && in(m, SafeModifiers) && specerror(
                what * ": " * modifier_reminder(m) *
                ". The separator is '|>' or '∘', never '.'";
                code = :modifier_misuse, token = m)
            specerror(what * ": qualified names like '" * string(fname) *
                      "' are not allowed in untrusted specs; hosts can register the " *
                      "function under a plain name with registerop!";
                      code = :unsupported_syntax)
        end
        specerror(what * ": unsupported function name " * string(fname);
                  code = :unsupported_syntax)
    end
    op = get(SafeOps, fname, nothing)
    if op === nothing && startswith(string(fname), ".")
        op = get(SafeOps, Symbol(string(fname)[2:end]), nothing)
    end
    op === nothing && unknown_op_error(what, fname)
    pts = Function[]                     # positional thunks, in order
    kts = Pair{Symbol,Function}[]        # keyword thunks
    for a in ex.args[2:end]
        if Base.Meta.isexpr(a, :parameters)      # f(x; k = v) form
            for p in a.args
                Base.Meta.isexpr(p, :kw) && isa(p.args[1], Symbol) ||
                    error(what * ": '" * string(p) * "' is not a keyword " *
                          "option -- write options as 'name = value' " *
                          "(after ';' or ',')")
                push!(kts, p.args[1] => compile_node(p.args[2], cols, what))
            end
        elseif Base.Meta.isexpr(a, :kw)          # f(x, k = v) form
            isa(a.args[1], Symbol) ||
                error(what * ": '" * string(a) * "' is not a keyword option -- " *
                      "an option name must be a plain word, as in " *
                      "'rank(x, rev = true)'")
            push!(kts, a.args[1] => compile_node(a.args[2], cols, what))
        elseif isa(a, QuoteNode) && isa(a.value, Symbol)
            # The colon flip: in a trusted Expr `:col` IS the column, here a
            # bare word is. A positional :sym is therefore always the DataFrames
            # habit leaking through -- it would compile to a Symbol constant and
            # die at apply time with a MethodError naming neither the spec nor
            # the colon. (Symbols stay legal as option VALUES and inside a
            # literal array, both handled elsewhere.)
            # dropping the colon is a genuine drop-in fix
            specerror(what * ": ':" * string(a.value) * "' is a Symbol literal, " *
                      "which is only an option VALUE here (boundedness = " *
                      ":boundedbelow). A column is a bare word -- write '" *
                      string(a.value) * "', without the colon.";
                      code = :symbol_literal, token = a.value, fix = a.value)
        else
            push!(pts, compile_node(a, cols, what))
        end
    end
    check_arity(what, fname, op, length(pts))
    check_kwargs(what, fname, op, Symbol[k for (k, _) in kts])
    if isempty(kts)
        return vals -> op((t(vals) for t in pts)...)
    else
        return vals -> op(
            (t(vals) for t in pts)...;
            Pair{Symbol,Any}[k => t(vals) for (k, t) in kts]...,
        )
    end
end

# nested grouped reduction: `inner |> groupby(keys...)` (∘ works too) INSIDE a
# spec -- evaluate `inner` once per distinct key combination of the current
# rows and collect the results into a vector, one element per subgroup,
# SORTED BY KEY (first/last read as earliest/latest key). Composite
# aggregation: aggr"mean(sum(_) |> groupby(year))" sums within each year,
# then means across the years; stages nest recursively. This is COMPUTATIONAL
# grouping, distinct from the top-level dim-spec modifier (engine metadata,
# peeled by peel_modifiers before the compiler ever runs). Keys may be
# computed columns (groupby(yyyy(t))); a missing key forms its own subgroup
# (Dict isequal semantics). orderby cannot attach here -- subgroup order is
# the key sort.
function compile_grouped(ex::Expr, cols::Vector{Symbol}, what::String)
    combinator, lhs, rhs = ex.args[1], ex.args[2], ex.args[3]
    if ismodifiershape(lhs)
        error(what * ": one modifier only in a nested grouped reduction -- " *
              "multi-key grouping is groupby(k1, k2, ...)")
    end
    if ismodifiercall(lhs)
        error(what * ": the modifier must follow the spec -- write " *
              "\"mean(sum(_) " * string(combinator) * " groupby(year))\"")
    end
    if !ismodifiercall(rhs)
        if isa(rhs, Symbol) && in(rhs, SafeModifiers)   # forgot the parens
            specerror(what * ": " * string(rhs) * " takes columns -- write " *
                      "\"spec " * string(combinator) * " " * string(rhs) *
                      "(col, ...)\""; code = :modifier_misuse, token = rhs)
        end
        tok = Base.Meta.isexpr(rhs, :call) && isa(rhs.args[1], Symbol) ?
              rhs.args[1] : isa(rhs, Symbol) ? rhs : nothing
        r = tok === nothing ? (hint = "", fix = nothing) : repair(tok, SafeModifiers)
        specerror(what * ": '" * string(combinator) * "' attaches a groupby " *
                  "modifier to a nested spec (\"mean(sum(_) " *
                  string(combinator) * " groupby(year))\"), got " *
                  string(rhs) * r.hint;
                  code = :modifier_misuse, token = tok, fix = r.fix)
    end
    if rhs.args[1] == :orderby
        specerror(what * ": orderby cannot attach to a nested grouped " *
                  "reduction -- subgroups are ordered by their groupby keys";
                  code = :modifier_misuse, token = :orderby)
    end
    it = compile_node(lhs, cols, what)   # inner first: cols in source order
    keyargs = Any[]
    for a in rhs.args[2:end]
        if Base.Meta.isexpr(a, :kw) || Base.Meta.isexpr(a, :parameters)
            error(what * ": groupby takes key columns, not keyword arguments")
        elseif Base.Meta.isexpr(a, :vect)
            append!(keyargs, a.args)     # groupby([a, b]) = groupby(a, b)
        else
            push!(keyargs, a)
        end
    end
    isempty(keyargs) && error(what * ": groupby needs at least one key column")
    for a in keyargs
        isa(a, Union{Number,AbstractString,Char,QuoteNode}) &&
            groupby_literal_error(what, a)
    end
    kts = Function[compile_node(a, cols, what) for a in keyargs]
    nk = length(kts)
    return function (vals)
        kvs = [kt(vals) for kt in kts]
        for kv in kvs
            isa(kv, AbstractVector) || error(
                what * ": a groupby key must evaluate to a column, " *
                "got a scalar")
        end
        n = length(kvs[1])
        all(length(kv) == n for kv in kvs) ||
            error(what * ": groupby key columns differ in length")
        groups = Dict{Any,Vector{Int}}()
        for i = 1:n
            push!(get!(Vector{Int}, groups, ntuple(j -> kvs[j][i], nk)), i)
        end
        ks = try
            sort!(collect(keys(groups)))
        catch
            error(what * ": groupby keys must be mutually comparable to " *
                  "sort the subgroups -- got mixed key types")
        end
        [it(map(v -> view(v, groups[k]), vals)) for k in ks]
    end
end

# ---- entry points -----------------------------------------------------------

# Julia's own ParseError is a multi-line block with a caret diagram; the last
# line carries the actual diagnosis ("extra tokens after end of expression").
# Lift that out so the rejection stays one line, as a TUI needs.
# A syntax error already knows exactly where it is: Julia's ParseError carries
# JuliaSyntax diagnostics with byte ranges. Lift the first one rather than
# re-deriving a span from a token there is none of. Defensive throughout -- this
# reaches into an internal shape, and a missing span is only a missing
# highlight.
function parse_span(err)
    try
        pe = isa(err, Base.Meta.ParseError) && hasproperty(err, :detail) ?
             err.detail : err
        hasproperty(pe, :diagnostics) || return nothing
        ds = pe.diagnostics
        isempty(ds) && return nothing
        r = Base.JuliaSyntax.byte_range(first(ds))
        isa(r, UnitRange{Int}) && !isempty(r) ? r : nothing
    catch
        nothing
    end
end

function parse_detail(err)
    msg = isa(err, AbstractString) ? String(err) :
          isa(err, Base.Meta.ParseError) ? string(err.msg) :
          sprint(showerror, err)
    line = last(split(msg, '\n'))
    i = findlast("── ", line)
    i === nothing ? strip(line) : strip(line[(last(i)+1):end])
end

function safe_parse(s::AbstractString, what::String)
    ex = try
        Meta.parse(s)
    catch err
        detail = parse_detail(err)
        specerror(what * ": cannot parse \"" * s * "\"" *
                  (isempty(detail) ? "" : " -- " * detail);
                  code = :parse, span = parse_span(err))
    end
    ex === nothing && specerror(
        what * ": empty spec -- a spec is a call over column names, e.g. " *
        (what == "parseaggr" ? "\"sum(_)\"" : "\"cumsum(sales)\"");
        code = :empty_spec)
    if isa(ex, Expr) && ex.head == :incomplete
        specerror(what * ": incomplete expression \"" * s *
                  "\" -- " * parse_detail(ex.args[1]); code = :parse)
    end
    if isa(ex, Expr) && ex.head == :toplevel
        specerror(what * ": one expression only (no ';') in \"" * s * "\"";
                  code = :parse)
    end
    ex
end

positional_args(ex::Expr) = [
    a for a in ex.args[2:end] if
    !(Base.Meta.isexpr(a, :kw) || Base.Meta.isexpr(a, :parameters))
]

simple_posarg(a) =
    isa(a, Symbol) ? a :
    Base.Meta.isexpr(a, :vect) && all(x -> isa(x, Symbol), a.args) ?
    Symbol[a.args...] : nothing

ismodifiercall(x) = Base.Meta.isexpr(x, :call) && in(x.args[1], SafeModifiers)
ismodifiershape(ex) =
    Base.Meta.isexpr(ex, :call, 3) && (ex.args[1] == :∘ || ex.args[1] == :|>)

# peel postfix modifiers off a dim spec: `spec ∘ modifier(...)` (or `|>`, the
# ASCII twin). Intent first, modifier after; modifiers are engine METADATA --
# interpreted structurally, never called. Returns (inner, order, by).
function peel_modifiers(ex, what::String)
    order = Pair{Symbol,Bool}[]
    by = Union{Symbol,GroupByKey}[]
    while ismodifiershape(ex)
        combinator, lhs, rhs = ex.args[1], ex.args[2], ex.args[3]
        if ismodifiercall(lhs)
            specerror(what * ": the modifier must follow the spec -- write " *
                      "\"spec " * string(combinator) * " " *
                      string(lhs.args[1]) * "(...)\"";
                      code = :modifier_misuse, token = lhs.args[1])
        end
        if !ismodifiercall(rhs)
            if isa(rhs, Symbol) && in(rhs, SafeModifiers)   # forgot the parens
                specerror(what * ": " * string(rhs) * " takes columns -- write " *
                          "\"spec " * string(combinator) * " " * string(rhs) *
                          "(col, ...)\""; code = :modifier_misuse, token = rhs)
            end
            tok = Base.Meta.isexpr(rhs, :call) && isa(rhs.args[1], Symbol) ?
                  rhs.args[1] : isa(rhs, Symbol) ? rhs : nothing
            r = tok === nothing ? (hint = "", fix = nothing) :
                repair(tok, SafeModifiers)
            specerror(what * ": expected a modifier call (" *
                      join(string.(SafeModifiers), ", ") * ") after '" *
                      string(combinator) * "', got " * string(rhs) * r.hint;
                      code = :modifier_misuse, token = tok, fix = r.fix)
        end
        modname = rhs.args[1]
        args = rhs.args[2:end]
        if modname == :orderby
            isempty(order) || error(what * ": duplicate orderby modifier")
            isempty(args) && error(what * ": orderby needs at least one column")
            for a in args
                push!(order, orderentry_parsed(a))   # :col | col => :asc/:desc
            end
        else # :groupby -- bare columns/computed expressions (varargs), or one
             # [col, ...] array of PLAIN columns (unchanged; the array
             # spelling stays symbol-only -- mixing an expression into it
             # errors with a redirect rather than silently doing something
             # surprising)
            isempty(by) || error(what * ": duplicate groupby modifier")
            for a in args
                s = simple_posarg(a)
                if isa(s, Symbol)
                    push!(by, s)
                elseif isa(s, Vector{Symbol})
                    append!(by, s)
                elseif isa(a, Union{Number,AbstractString,Char,QuoteNode})
                    groupby_literal_error(what, a)
                elseif Base.Meta.isexpr(a, :vect)
                    error(what * ": groupby's [ ... ] array form only " *
                          "accepts plain column names -- write computed " *
                          "keys as separate arguments, e.g. groupby(col1, " *
                          "yyyymm(date))")
                else
                    # a computed key, e.g. groupby(yyyymm(date)) -- compiled
                    # exactly like a nested composite-aggregation groupby
                    # key (compile_grouped), materialized as a real column
                    # before DataFrames.groupby at evaluation time
                    kcols = Symbol[]
                    kf = compile_node(a, kcols, what)
                    push!(by, GroupByKey(gensym(:bykey), kf, kcols))
                end
            end
            isempty(by) && error(what * ": groupby needs at least one column")
        end
        ex = lhs
    end
    (ex, order, by)
end

# ---- shape inference --------------------------------------------------------
# What a whole spec EXPRESSION returns, relative to the rows it is handed:
#
#   :scalar      one value       sum(_), mean(x) / std(x), a literal
#   :rowwise     one per row     cumsum(x), x > 1, sales / sum(sales)
#   :collection  many, unaligned skipmissing(x), [a, b], a nested grouped
#                                reduction (one element per KEY, not per row)
#   :unknown     give up         anything touching an undeclared operator
#
# Composition is the point: the top-level NAME is not enough. `sum(_ * wt) /
# sum(wt)` is a division -- elementwise -- yet reduces, because both operands
# do. `sales / sum(sales)` is the same division and does not. Only propagating
# through the tree tells them apart, which is why this is an inference rather
# than a lookup.
#
# :unknown is absorbing on purpose. One undeclared host verb anywhere in the
# expression turns the whole answer into "no opinion", and every check below
# then stays silent -- the same bail-out check_kwargs makes when it meets a
# `kwargs...` method.
function shape_of(ex)
    isa(ex, Symbol) && return ex === :_ ? :rowwise : :rowwise   # column or target
    isa(ex, QuoteNode) && return :scalar
    isa(ex, Union{Number,AbstractString,Char,Bool}) && return :scalar
    isa(ex, Expr) || return :unknown
    ex.head === :vect && return :collection
    (ex.head === :(&&) || ex.head === :(||) || ex.head === :comparison) &&
        return combine_shapes(map(shape_of, ex.args))
    # a nested `inner |> groupby(keys)` yields one element per KEY
    ismodifiershape(ex) && return :collection
    ex.head === :call || return :unknown
    fname = ex.args[1]
    isa(fname, Symbol) || return :unknown
    s = opshape(fname)
    s === :reduce && return :scalar
    s === :map && return :rowwise
    s === :filter && return :collection
    s === :unknown && return :unknown
    combine_shapes([shape_of(a) for a in positional_args(ex)])   # :elementwise
end

# an elementwise call is as "wide" as its widest argument, and one :unknown
# poisons the result
combine_shapes(ss) =
    isempty(ss) ? :scalar :
    any(==(:unknown), ss) ? :unknown :
    any(==(:collection), ss) ? :collection :
    any(==(:rowwise), ss) ? :rowwise : :scalar

# Which call actually collapsed the rows? The TOP-LEVEL name is usually the
# wrong one to blame: in `where(any(flag))` the top is `where` (elementwise,
# innocent) and the culprit is `any` one level down. Descend through
# elementwise calls to name the reduction the user has to reconsider, since
# that is the token they must edit.
function reducing_culprit(ex)
    isa(ex, Expr) || return nothing
    if ex.head === :call && isa(ex.args[1], Symbol)
        opshape(ex.args[1]) === :reduce && return ex.args[1]
        opshape(ex.args[1]) === :elementwise || return nothing
    elseif !(ex.head === :(&&) || ex.head === :(||) || ex.head === :comparison)
        return nothing
    end
    args = ex.head === :call ? positional_args(ex) : ex.args
    for a in args
        c = reducing_culprit(a)
        c === nothing || return c
    end
    nothing
end

# The mirror of reducing_culprit, for the aggregation side: what stopped this
# spec collapsing to one value? A bare column read row by row, or a :map/:filter
# verb that preserves them. Descend only through branches that are NOT already
# scalar -- `sum(a) + qtty` should blame `qtty`, not `sum`.
function unreduced_culprit(ex)
    isa(ex, Symbol) && return ex
    isa(ex, Expr) || return nothing
    local args
    if ex.head === :call && isa(ex.args[1], Symbol)
        s = opshape(ex.args[1])
        (s === :map || s === :filter) && return ex.args[1]
        s === :elementwise || return nothing        # :reduce/:unknown stop here
        args = positional_args(ex)
    elseif ex.head === :(&&) || ex.head === :(||) || ex.head === :comparison
        args = ex.args
    else
        return nothing
    end
    for a in args
        shape_of(a) === :scalar && continue         # this branch already reduced
        c = unreduced_culprit(a)
        c === nothing || return c
    end
    nothing
end

# A :map verb handed nothing but scalars has nothing to map over. This is how
# `where(any(flag)) |> groupby(region)` used to reach the engine and die with a
# raw `TypeError: non-boolean (Int64) used in boolean context` -- and it is
# decidable here because every :map verb rejects a scalar argument outright.
# Silent unless EVERY positional argument is definitively scalar.
function check_mapshape(what::String, fname::Symbol, ex::Expr)
    opshape(fname) === :map || return nothing
    args = positional_args(ex)
    isempty(args) && return nothing
    all(a -> shape_of(a) === :scalar, args) || return nothing
    specerror(what * ": '" * string(fname) * "' works down a column, but every " *
              "argument here is a single value -- name the column it should " *
              "run over, e.g. '" * string(fname) * "(sales)'";
              code = :shape, token = fname)
end

# where's default labels are the condition's SOURCE TEXT, which only the
# compiler knows (the verb just sees a Bool vector) -- inject
# `true_label = "<condition>"` into any where(...) call that does not spell
# its own (false_label then derives from true_label inside the verb, see
# verbs.jl). Every where call passes through here, so the arity check lives
# here too. Trusted-Expr specs get no such injection: their authors pass
# true_label explicitly.
function desugar_where!(ex, what::String)
    isa(ex, Expr) || return ex
    if ex.head == :call && ex.args[1] == :where
        pos = positional_args(ex)
        length(pos) == 1 || error(
            what * ": where takes exactly one Boolean condition, plus " *
            "optional labels -- where(cond) or " *
            "where(cond, true_label = \"...\", false_label = \"...\")",
        )
        haslabel = any(ex.args[2:end]) do a
            Base.Meta.isexpr(a, :kw) && a.args[1] == :true_label ||
                Base.Meta.isexpr(a, :parameters) && any(
                    p -> Base.Meta.isexpr(p, :kw) && p.args[1] == :true_label,
                    a.args,
                )
        end
        haslabel || push!(ex.args, Expr(:kw, :true_label, string(pos[1])))
    end
    for a in ex.args
        desugar_where!(a, what)
    end
    ex
end

# top-level && / || make a legal spec shape too: `a > 1` is already a valid
# Bool-column spec, so its compound form must be as well. :comparison passes
# the shape gate only to reach compile_node's tailored rejection ("combine
# single comparisons with &&") instead of a generic shape error.
iscondshape(ex) =
    isa(ex, Expr) && (ex.head == :(&&) || ex.head == :(||) || ex.head == :comparison)

# a spec whose TOP level is not a call. The shape gate runs before the
# compiler, so without this the tailored SafeRejections wording ("assignment
# is not allowed", "do-blocks are not allowed") would only ever be reached
# from a nested position -- `x = 1` at the top level got the generic
# "must be a function call", which does not name what is wrong.
function shape_error(what::String, ex, src::String, generic::String)
    if isa(ex, Expr) && haskey(SafeRejections, ex.head)
        specerror(what * ": " * SafeRejections[ex.head] * " (in \"" * src * "\")";
                  code = :unsupported_syntax, token = ex.head)
    end
    specerror(what * ": " * generic * ", got \"" * src * "\"";
              code = :unsupported_syntax)
end

# checkcols: validate a spec's column references against the columns a host
# knows to exist (typically propertynames(df)), with did-you-mean repair --
# the TUI path, where a misspelled column would otherwise surface much later
# as a bare DataFrames indexing error. `_` is the aggregation target, not a
# column reference. Returns the spec for chaining.
# flatten a `by` list (bare column Symbols and/or GroupByKeys) to the REAL
# columns that must exist on the host's frame -- a GroupByKey's synthetic
# gensym'd name never does. Shared by checkcols here and PivotDim's
# required_columns (dimension.jl).
byrefs(by) = Symbol[c for k in by for c in (isa(k, Symbol) ? (k,) : k.cols)]

function checkcols(s::Union{SafeAggrSpec,SafeDimSpec}, columns::AbstractVector{Symbol})
    # (column, where it was written) -- naming the modifier matters when a spec
    # references the same-looking name in two places, and it tells the user
    # which part of the string to edit
    refs = Pair{Symbol,String}[]
    seen = Set{Symbol}()
    add!(c, origin) = (in(c, seen) || (push!(seen, c); push!(refs, c => origin)))
    for c in s.cols                        # `_` is the target, not a column
        (isa(s, SafeAggrSpec) && c === :_) || add!(c, "")
    end
    for p in s.order
        add!(p.first, "orderby ")
    end
    isa(s, SafeDimSpec) && foreach(c -> add!(c, "groupby "), byrefs(s.by))
    for (c, origin) in refs
        if !in(c, columns)
            r = repair(c, sort(columns))
            # checkcols runs outside with_spec_context (after the cache lookup),
            # so it locates its own token
            specerror("checkcols: spec \"" * s.source * "\" references " * origin *
                      "column '" * string(c) * "', which does not exist" *
                      (isempty(r.hint) ? ". Available columns: " *
                                         join(sort(columns), ", ") : r.hint);
                      code = :unknown_column, token = c, fix = r.fix,
                      span = token_span(s.source, c, :unknown_column),
                      spec = s.source)
        end
    end
    s
end

# repeated parses of the same string return the identical spec object
const SafeSpecCache = Dict{Tuple{Symbol,String},Any}()

# Every rejection ends by quoting the spec it came from. A host parses many
# specs per frame (an AggrHints table, the entries of a chain), and "unknown
# function 'foo'" on its own does not say WHICH one to fix. Applied once at
# the entry point rather than at the ~40 individual error sites, so it also
# tags errors raised by shared helpers further down (order entries, verbs).
const SPEC_CONTEXT_MARK = " [in "

# This is also the choke point that makes the diagnostic TYPE uniform: whatever
# a helper deeper down threw -- a classified SpecError from safe.jl, or a plain
# ErrorException from a verb or an order-entry helper that has not been
# classified -- comes out of parseaggr/parsedim as a SpecError carrying the
# spec source. An unclassified site therefore still yields a usable diagnostic
# (`code = :invalid_spec`), so classifying a site is always additive and never
# a prerequisite. The message is rebuilt exactly as before.
function with_spec_context(f, what::String, src::String)
    try
        f()
    catch e
        isa(e, Union{ErrorException,SpecError}) || rethrow()
        isa(e, SpecError) && e.spec !== nothing && rethrow()   # already tagged
        occursin(SPEC_CONTEXT_MARK, e.msg) && rethrow()        # ...ditto, untyped
        msg = startswith(e.msg, what * ":") ? e.msg : what * ": " * e.msg
        code  = isa(e, SpecError) ? e.code : :invalid_spec
        token = isa(e, SpecError) ? e.token : nothing
        # locate the offending text here too -- a site that set `token` gets a
        # highlight without ever having to know a byte offset
        span  = isa(e, SpecError) && e.span !== nothing ? e.span :
                token_span(src, token, code)
        throw(SpecError(msg * SPEC_CONTEXT_MARK *
                        (what == "parseaggr" ? "aggr\"" : "dim\"") * src * "\"]";
                        code = code, token = token,
                        fix  = isa(e, SpecError) ? e.fix : nothing,
                        span = span, spec = src))
    end
end

function parseaggr(
    s::AbstractString;
    columns::Union{Nothing,AbstractVector{Symbol}} = nothing,
)
    spec = get!(SafeSpecCache, (:aggr, String(strip(s)))) do
        src = String(strip(s))
        with_spec_context(() -> parseaggr_impl(src), "parseaggr", src)
    end::SafeAggrSpec
    # validated per call, outside the cache: the same spec may be checked
    # against different frames
    columns === nothing ? spec : checkcols(spec, columns)
end

function parseaggr_impl(src::String)
    ex = safe_parse(src, "parseaggr")
    # orderby IS a legal top-level modifier here (sort the group's rows
    # before the reduction runs -- see SafeAggrSpec.order); groupby is not
    # (an aggregation spec must reduce to ONE value, and a grouped reduction
    # yields one value per key -- that stays the NESTED composite form).
    # Reuse the exact same peeling dim specs use, rather than a parallel
    # implementation.
    (ex, order, by) = peel_modifiers(ex, "parseaggr")
    isempty(by) || specerror(
        "parseaggr: a top-level groupby modifier is a dimension-spec " *
        "feature; an aggregation spec must reduce to ONE value, and a " *
        "grouped reduction yields one value per key -- NEST it in a " *
        "reduction instead: \"mean(sum(_) |> groupby(year))\". (orderby IS " *
        "allowed at the top level: \"first(_) |> orderby(date)\")";
        code = :modifier_misuse, token = :groupby,
    )
    any(p -> p.first == :_, order) && specerror(
        "parseaggr: '_' has no meaning in orderby -- it names the " *
        "aggregation target, which is bound to a real column only when " *
        "the spec is applied (the same spec can target different columns), " *
        "not a fixed row-order key. Order by a real column instead.";
        code = :target_placeholder, token = :_,
    )
    if isa(ex, Symbol)                   # aggr"sum" -- bare registered name
        if !haskey(SafeOps, ex)
            ex === :_ && specerror(
                "parseaggr: '_' names the aggregation target column, it is " *
                "not itself an aggregation -- reduce it: \"sum(_)\", " *
                "\"mean(_)\", \"last(_) |> orderby(date)\"";
                code = :target_placeholder, token = :_)
            # a lone word that repairs to nothing is far likelier to be a
            # column than a mistyped verb -- say the useful thing
            op_is_repairable(ex) || specerror(
                "parseaggr: '" * string(ex) * "' is a column reference, not " *
                "an aggregation -- reduce it (\"sum(" * string(ex) * ")\"), " *
                "or use '_' to mean whichever column the spec is applied to " *
                "(\"sum(_)\")"; code = :bare_name, token = ex)
            unknown_op_error("parseaggr", ex)
        end
        ex = Expr(:call, ex, :_)         # lower to sum(_), like trusted :sum
    end
    isa(ex, Expr) && (ex.head == :call || iscondshape(ex)) ||
        shape_error("parseaggr", ex, src,
                    "spec must be a function call or a registered function name")
    desugar_where!(ex, "parseaggr")
    cols = Symbol[]
    thunk = compile_node(ex, cols, "parseaggr")
    # Shape is checked AFTER compiling, deliberately. The compiler's per-node
    # rejections are more specific than any whole-spec verdict -- `cumsum(:qty)`
    # should be told about the colon, not that it computes one value per row --
    # and the ladder rule is most-specific-first (see unknown_op_error).
    # An aggregation must land on ONE value per group; a row-wise or unaligned
    # spec used to compile fine and then put a vector, or a lazy SkipMissing,
    # in a cell.
    let sh = shape_of(ex), culprit = unreduced_culprit(ex)
        sh === :rowwise && specerror(
            "parseaggr: this computes one value per ROW" *
            (culprit === nothing ? "" :
             " ('" * string(culprit) * "' is read row by row)") *
            ", but an aggregation reduces the group to ONE value -- wrap it " *
            "in a reduction, e.g. \"sum(" * src * ")\" or \"mean(" * src *
            ")\". (A dimension spec is the row-wise form: dim\"" * src * "\".)";
            code = :shape, token = culprit)
        sh === :collection && specerror(
            "parseaggr: this yields many values, not one -- an aggregation " *
            "reduces the group to a single value, so feed it to a reduction: " *
            "\"sum(" * src * ")\", \"first(" * src * ")\", \"countuniq(" *
            src * ")\".";
            code = :shape, token = culprit)
    end
    isa(ex, Expr) && ex.head === :call && isa(ex.args[1], Symbol) &&
        check_mapshape("parseaggr", ex.args[1], ex)
    fname = iscondshape(ex) ? Symbol(ex.head) : ex.args[1]
    SafeAggrSpec(src, fname, (vs...) -> thunk(vs), cols, order)
end

function parsedim(
    s::AbstractString;
    columns::Union{Nothing,AbstractVector{Symbol}} = nothing,
)
    spec = get!(SafeSpecCache, (:dim, String(strip(s)))) do
        src = String(strip(s))
        with_spec_context(() -> parsedim_impl(src), "parsedim", src)
    end::SafeDimSpec
    # validated per call, outside the cache: the same spec may be checked
    # against different frames
    columns === nothing ? spec : checkcols(spec, columns)
end

function parsedim_impl(src::String)
    ex = safe_parse(src, "parsedim")
    (ex, order, by) = peel_modifiers(ex, "parsedim")
    if !(isa(ex, Expr) && ex.head == :call) && !iscondshape(ex)
        if isa(ex, Symbol) && haskey(SafeOps, ex)
            specerror("parsedim: '" * src * "' is an operator name -- write it " *
                      "as a call: \"" * src * "(col)\"";
                      code = :bare_name, token = ex)
        elseif isa(ex, Symbol)
            specerror("parsedim: a bare column name is a chain KEY, not a " *
                      "dimension spec -- list it directly in the chain " *
                      "([:region, :" * src * "]); a dim spec computes something, " *
                      "e.g. \"cumsum(" * src * ")\"";
                      code = :bare_name, token = ex)
        end
        shape_error("parsedim", ex, src,
                    "spec must be a function call (e.g. \"cumsum(sales)\")")
    end
    desugar_where!(ex, "parsedim")
    cols = Symbol[]
    thunk = compile_node(ex, cols, "parsedim")
    in(:_, cols) &&
        specerror("parsedim: '_' is the aggregation target placeholder and has no " *
                  "meaning in a dim spec -- a dimension is computed from named " *
                  "columns, so name the one you want (\"cumsum(sales)\")";
                  code = :target_placeholder, token = :_)
    # Shape is checked AFTER compiling, deliberately -- the compiler's per-node
    # rejections are more specific than any whole-spec verdict (the ladder rule,
    # see unknown_op_error).
    # A `|> groupby(...)` dim is a PIVOT: the measure is aggregated to one value
    # per group and the verb then CLASSIFIES those groups, so it must return one
    # label PER GROUP. A reducing spec returns a single scalar instead, which
    # the engine could only report much later as "spec must return one value per
    # group (N groups)" -- with no hint that `mean` was the wrong kind of verb.
    # Window dims are exempt: there a scalar is legal and broadcasts.
    if !isempty(by)
        sh = shape_of(ex)
        culprit = reducing_culprit(ex)
        sh === :scalar && specerror(
            "parsedim: a groupby dimension LABELS each group, so it must give " *
            "one value per group" *
            (culprit === nothing ? "" :
             ", but '" * string(culprit) * "' reduces them to a single value") *
            ". Classify the groups instead -- rank/denserank, quantiles, " *
            "discretize, topnames, or where(<condition on the group's total>) " *
            "-- or drop the groupby to compute this per row. (To REDUCE the " *
            "frame to one row per group, that is agg, not dim.)";
            code = :shape, token = culprit)
        sh === :collection && specerror(
            "parsedim: a groupby dimension must give one label per group, but " *
            "this yields a collection that is not aligned with them";
            code = :shape)
    end
    isa(ex, Expr) && ex.head === :call && isa(ex.args[1], Symbol) &&
        check_mapshape("parsedim", ex.args[1], ex)
    posargs = iscondshape(ex) ? Any[] :
              Any[simple_posarg(a) for a in positional_args(ex)]
    fname = iscondshape(ex) ? Symbol(ex.head) : ex.args[1]
    SafeDimSpec(src, fname, (vs...) -> thunk(vs), cols, posargs, order, by)
end

# string-macro sugar; expands to a runtime call so precompilation stays trivial,
# the registry is consulted at use time, and the SafeSpecCache is shared with
# the TUI path. Raw string-macro semantics: no interpolation hole.
macro aggr_str(s)
    :(parseaggr($s))
end

macro dim_str(s)
    :(parsedim($s))
end

# lift a safe aggregation spec exactly like the trusted forms; no eval, so the
# returned closure is directly callable (invokelatest remains harmless)
function liftAggrSpecToFunc(c::Symbol, s::SafeAggrSpec)
    if haskey(DataFrameAggrCache, (c, s))
        return DataFrameAggrCache[(c, s)]
    end
    f = s.f
    cols = s.cols
    order = s.order
    ret = (_df_::AbstractDataFrame) -> begin
        # order-sensitive verbs (first, last, ...) need a defined row order
        # within the group; order-insensitive ones (sum, mean, ...) just sort
        # for nothing -- same tradeoff WindowDim already accepts for rank/
        # denserank/tiedrank. order_indices (dimension.jl) is a no-op when
        # s.order is empty.
        d2 = isempty(order) ? _df_ :
             view(_df_, order_indices(_df_, 1:nrow(_df_), order), :)
        f((d2[!, col === :_ ? c : col] for col in cols)...)
    end
    DataFrameAggrCache[(c, s)] = ret
end
