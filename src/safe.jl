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

# extension is a trusted act done in host code, never via spec strings
function registerop!(name::Symbol, f::Base.Callable)
    s = string(name)
    if occursin(".", s) || occursin("!", s)
        error("registerop!: operator names may not contain '.' or '!', got '" * s *
              "' (alias the function under a clean name instead)")
    end
    if in(name, SafeModifiers)
        error("registerop!: '" * s * "' is a reserved modifier name")
    end
    SafeOps[name] = f
end

listops() = sort!(collect(keys(SafeOps)))

# broadcasting wrapper: kwargs are forwarded to each elementwise application
bcast(f) = (args...; kwargs...) -> Base.broadcast((a...) -> f(a...; kwargs...), args...)

# ---- default registry -------------------------------------------------------
for f in (
    # reductions (whole-vector)
    sum, prod, mean, median, std, var, quantile, minimum, maximum, extrema,
    length, count, first, last, skipmissing, any, all,
    # package verbs
    uniqvalue, countuniq, unionall, strjoinuniq, topnames, discretize, quantiles, lag, lead, where,
    wmeanfallback,
    # vector transforms
    cumsum, cumprod, rank, denserank, ordinalrank, tiedrank,
)
    SafeOps[Symbol(f)] = f
end

# nrow: DataFrames.jl-flavored alias for length -- group row count without
# reaching for `count`, whose Base semantics (number of trues) are unrelated
SafeOps[:nrow] = length

# scalar functions apply elementwise to columns. ismissing/coalesce are the
# row-level missing tools (flag / replace -- skipmissing covers drop); they
# ship under their Julia names on purpose: the registry is a projection of
# Julia, so specs keep the same vocabulary across the trust boundary.
for f in (abs, log, log2, log10, exp, sqrt, round, floor, ceil, min, max,
          ismissing, coalesce)
    SafeOps[Symbol(f)] = bcast(f)
end

# date-bucketing labels (verbs.jl): scalar verbs, elementwise over columns
for f in (yyyy, yyyyq, yyq, yyyymm, yymm)
    SafeOps[Symbol(f)] = bcast(f)
end

# operators: undotted and dotted spellings bind to the same broadcasting closure
# (! ships here directly -- registerop!'s '!' ban is a rule for HOST names)
for (name, f) in Any[
    (:+, +), (:-, -), (:*, *), (:/, /), (:^, ^),
    (:(==), ==), (:!=, !=), (:<, <), (:<=, <=), (:>, >), (:>=, >=),
    (:≠, !=), (:≤, <=), (:≥, >=), (:!, !),
]
    b = bcast(f)
    SafeOps[name] = b
    SafeOps[Symbol("." * string(name))] = b
end

# `in`: SQL/dplyr-style membership, `x in [1, 2, 5]`. Julia lowers infix `in`
# to an ordinary :call (fname :in), so it reaches the compiler and the
# registry exactly like any other operator -- no structural special case
# needed. NOT bcast(in): that would broadcast over the collection argument
# too (zip semantics -- silently wrong when the item and collection lengths
# happen to match, a shape error otherwise). Ref-protect the collection so it
# is compared as a WHOLE, once per item, whether it came from a literal
# array or a column.
SafeOps[:in] = (x, coll) -> Base.broadcast(in, x, Ref(coll))

# ∈ / ∉: Unicode spellings. `Base.:∈ === in` (the identical function, just a
# second token the parser accepts -- unlike `≠`/`≤`/`≥`, which are distinct
# functions wrapping the same closure), so this is a shared reference, not a
# copy. `∉` is `in`'s negation and needs its own Ref-protected closure.
SafeOps[:∈] = SafeOps[:in]
SafeOps[:∉] = (x, coll) -> Base.broadcast(Base.:∉, x, Ref(coll))

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
        error(what * ": '" * string(fname) * "' is not an operator here -- " *
              "combine conditions with '" * c * "' (pure elementwise over " *
              "columns; binds looser than comparisons, so no parentheses " *
              "needed: a > 1 " * c * " b < 2)")
    end
    in(fname, SafeModifiers) && error(what * ": " * modifier_reminder(fname))
    sq = squash(fname)
    # `dense_rank`, `ROW_NUMBER`: the concept exists, the spelling does not
    # (operator names carry no underscores -- design/expressiveness.md)
    if sq !== fname && haskey(SafeOps, sq)
        error(what * ": '" * string(fname) * "' is not registered -- write it " *
              "as '" * string(sq) * "' (operator names are lowercase and carry " *
              "no underscores).")
    end
    if haskey(ForeignSpellings, sq)
        error(what * ": '" * string(fname) * "' is not registered here -- use " *
              ForeignSpellings[sq] * ". (listops() shows the whitelist; " *
              "hosts can extend it with registerop!.)")
    end
    n = nearest(string(fname), vcat(listops(), collect(SafeModifiers)))
    if n isa Symbol && in(n, SafeModifiers)
        error(what * ": unknown function '" * string(fname) * "'. " *
              modifier_reminder(n))
    elseif n !== nothing
        error(what * ": unknown function '" * string(fname) *
              "' -- did you mean '" * string(n) * "'? (listops() shows the " *
              "whitelist; hosts can extend it with registerop!.)")
    end
    error(what * ": unknown function '" * string(fname) * "'. " *
          registry_summary())
end

# a literal where a grouping key belongs. Both `groupby` paths (the nested
# composite reduction and the top-level modifier) funnel here so the colon and
# quote habits -- by far the commonest way to write this wrong, since every
# other DataFrames API wants `:col` or `"col"` -- get named as such instead of
# being reported as "a literal".
function groupby_literal_error(what::String, a)
    if isa(a, QuoteNode) && isa(a.value, Symbol)
        error(what * ": ':" * string(a.value) * "' is a Symbol literal -- a " *
              "grouping key is a bare column name, written without the colon: " *
              "groupby(" * string(a.value) * ")")
    end
    isa(a, AbstractString) && Base.isidentifier(a) && error(
        what * ": " * repr(a) * " is a string literal -- a grouping key is a " *
        "bare column name, written without the quotes: groupby(" * a * ")")
    error(what * ": groupby keys must be columns (or elementwise transforms " *
          "of columns, e.g. yyyy(t)), got the literal " * repr(a))
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
    error(what * ": '" * string(fname) * "' takes " * expected *
          (lo == 1 && hi == 1 ? " positional argument, got " :
           " positional arguments, got ") * string(n) * hint *
          ". (Options go in keyword form: f(x, opt = value).)")
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
        isempty(accepted) && error(
            what * ": '" * string(fname) * "' takes no keyword options, got '" *
            string(k) * "'")
        error(what * ": '" * string(fname) * "' has no keyword option '" *
              string(k) * "'" * didyoumean(k, accepted) * ". Accepted: " *
              join(accepted, ", "))
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
        error(what * ": " * SafeRejections[ex.head] * " (in \"" * string(ex) * "\")")
    else
        error(what * ": unsupported syntax '" *
              (isa(ex, Expr) ? string(ex.head) : string(typeof(ex))) *
              "' in \"" * string(ex) * "\"")
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
            isa(m, Symbol) && in(m, SafeModifiers) && error(
                what * ": " * modifier_reminder(m) *
                ". The separator is '|>' or '∘', never '.'")
            error(what * ": qualified names like '" * string(fname) *
                  "' are not allowed in untrusted specs; hosts can register the " *
                  "function under a plain name with registerop!")
        end
        error(what * ": unsupported function name " * string(fname))
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
            error(what * ": ':" * string(a.value) * "' is a Symbol literal, " *
                  "which is only an option VALUE here (boundedness = " *
                  ":boundedbelow). A column is a bare word -- write '" *
                  string(a.value) * "', without the colon.")
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
            error(what * ": " * string(rhs) * " takes columns -- write " *
                  "\"spec " * string(combinator) * " " * string(rhs) *
                  "(col, ...)\"")
        end
        hint = Base.Meta.isexpr(rhs, :call) && isa(rhs.args[1], Symbol) ?
               didyoumean(rhs.args[1], SafeModifiers) :
               isa(rhs, Symbol) ? didyoumean(rhs, SafeModifiers) : ""
        error(what * ": '" * string(combinator) * "' attaches a groupby " *
              "modifier to a nested spec (\"mean(sum(_) " *
              string(combinator) * " groupby(year))\"), got " *
              string(rhs) * hint)
    end
    if rhs.args[1] == :orderby
        error(what * ": orderby cannot attach to a nested grouped " *
              "reduction -- subgroups are ordered by their groupby keys")
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
        error(what * ": cannot parse \"" * s * "\"" *
              (isempty(detail) ? "" : " -- " * detail))
    end
    ex === nothing && error(
        what * ": empty spec -- a spec is a call over column names, e.g. " *
        (what == "parseaggr" ? "\"sum(_)\"" : "\"cumsum(sales)\""))
    if isa(ex, Expr) && ex.head == :incomplete
        error(what * ": incomplete expression \"" * s *
              "\" -- " * parse_detail(ex.args[1]))
    end
    if isa(ex, Expr) && ex.head == :toplevel
        error(what * ": one expression only (no ';') in \"" * s * "\"")
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
            error(what * ": the modifier must follow the spec -- write " *
                  "\"spec " * string(combinator) * " " *
                  string(lhs.args[1]) * "(...)\"")
        end
        if !ismodifiercall(rhs)
            if isa(rhs, Symbol) && in(rhs, SafeModifiers)   # forgot the parens
                error(what * ": " * string(rhs) * " takes columns -- write " *
                      "\"spec " * string(combinator) * " " * string(rhs) *
                      "(col, ...)\"")
            end
            hint = Base.Meta.isexpr(rhs, :call) && isa(rhs.args[1], Symbol) ?
                   didyoumean(rhs.args[1], SafeModifiers) :
                   isa(rhs, Symbol) ? didyoumean(rhs, SafeModifiers) : ""
            error(what * ": expected a modifier call (" *
                  join(string.(SafeModifiers), ", ") * ") after '" *
                  string(combinator) * "', got " * string(rhs) * hint)
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
        error(what * ": " * SafeRejections[ex.head] * " (in \"" * src * "\")")
    end
    error(what * ": " * generic * ", got \"" * src * "\"")
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
            hint = didyoumean(c, sort(columns))
            error("checkcols: spec \"" * s.source * "\" references " * origin *
                  "column '" * string(c) * "', which does not exist" *
                  (isempty(hint) ? ". Available columns: " *
                                   join(sort(columns), ", ") : hint))
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

function with_spec_context(f, what::String, src::String)
    try
        f()
    catch e
        isa(e, ErrorException) || rethrow()
        occursin(SPEC_CONTEXT_MARK, e.msg) && rethrow()   # already tagged
        msg = startswith(e.msg, what * ":") ? e.msg : what * ": " * e.msg
        error(msg * SPEC_CONTEXT_MARK *
              (what == "parseaggr" ? "aggr\"" : "dim\"") * src * "\"]")
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
    isempty(by) || error(
        "parseaggr: a top-level groupby modifier is a dimension-spec " *
        "feature; an aggregation spec must reduce to ONE value, and a " *
        "grouped reduction yields one value per key -- NEST it in a " *
        "reduction instead: \"mean(sum(_) |> groupby(year))\". (orderby IS " *
        "allowed at the top level: \"first(_) |> orderby(date)\")",
    )
    any(p -> p.first == :_, order) && error(
        "parseaggr: '_' has no meaning in orderby -- it names the " *
        "aggregation target, which is bound to a real column only when " *
        "the spec is applied (the same spec can target different columns), " *
        "not a fixed row-order key. Order by a real column instead.",
    )
    if isa(ex, Symbol)                   # aggr"sum" -- bare registered name
        if !haskey(SafeOps, ex)
            ex === :_ && error(
                "parseaggr: '_' names the aggregation target column, it is " *
                "not itself an aggregation -- reduce it: \"sum(_)\", " *
                "\"mean(_)\", \"last(_) |> orderby(date)\"")
            # a lone word that repairs to nothing is far likelier to be a
            # column than a mistyped verb -- say the useful thing
            op_is_repairable(ex) || error(
                "parseaggr: '" * string(ex) * "' is a column reference, not " *
                "an aggregation -- reduce it (\"sum(" * string(ex) * ")\"), " *
                "or use '_' to mean whichever column the spec is applied to " *
                "(\"sum(_)\")")
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
            error("parsedim: '" * src * "' is an operator name -- write it " *
                  "as a call: \"" * src * "(col)\"")
        elseif isa(ex, Symbol)
            error("parsedim: a bare column name is a chain KEY, not a " *
                  "dimension spec -- list it directly in the chain " *
                  "([:region, :" * src * "]); a dim spec computes something, " *
                  "e.g. \"cumsum(" * src * ")\"")
        end
        shape_error("parsedim", ex, src,
                    "spec must be a function call (e.g. \"cumsum(sales)\")")
    end
    desugar_where!(ex, "parsedim")
    cols = Symbol[]
    thunk = compile_node(ex, cols, "parsedim")
    in(:_, cols) &&
        error("parsedim: '_' is the aggregation target placeholder and has no " *
              "meaning in a dim spec -- a dimension is computed from named " *
              "columns, so name the one you want (\"cumsum(sales)\")")
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
