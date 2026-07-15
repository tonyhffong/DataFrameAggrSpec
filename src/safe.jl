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
# Everything else -- qualified names, macros, interpolation, lambdas, indexing,
# blocks, comprehensions, splats, ternaries -- is rejected with a clear error.
# Note one wrinkle of "bare identifier = column": `missing`, `pi`, `Inf` are
# identifiers, hence column references, not constants.

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
    length, count, first, last, skipmissing,
    # package verbs
    uniqvalue, unionall, strjoinuniq, topnames, discretize, quantiles, lag, lead,
    # vector transforms
    cumsum, cumprod,
)
    SafeOps[Symbol(f)] = f
end

for f in (abs, log, log2, log10, exp, sqrt, round, floor, ceil, min, max)
    SafeOps[Symbol(f)] = bcast(f)   # scalar math applies elementwise to columns
end

# operators: undotted and dotted spellings bind to the same broadcasting closure
for (name, f) in Any[
    (:+, +), (:-, -), (:*, *), (:/, /), (:^, ^),
    (:(==), ==), (:!=, !=), (:<, <), (:<=, <=), (:>, >), (:>=, >=),
    (:≠, !=), (:≤, <=), (:≥, >=),
]
    b = bcast(f)
    SafeOps[name] = b
    SafeOps[Symbol("." * string(name))] = b
end

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
    by::Vector{Symbol}     # from a peeled `|> groupby(keys...)`; marks pivot
end                        # kind, consumed by PivotDim as its inner grouping

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
    :comparison => "chained comparisons are not allowed; split into single comparisons",
    Symbol("&&") => "boolean && is not allowed",
    Symbol("||") => "boolean || is not allowed",
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

# unknown function in call position: modifier reminder, did-you-mean repair
# against the whitelist, or the full registry as a last resort (it is the only
# discovery mechanism when nothing is close)
function unknown_op_error(what::String, fname::Symbol)
    in(fname, SafeModifiers) && error(what * ": " * modifier_reminder(fname))
    n = nearest(string(fname), vcat(listops(), collect(SafeModifiers)))
    if n isa Symbol && in(n, SafeModifiers)
        error(what * ": unknown function '" * string(fname) * "'. " *
              modifier_reminder(n))
    elseif n !== nothing
        error(what * ": unknown function '" * string(fname) *
              "' -- did you mean '" * string(n) * "'? (listops() shows the " *
              "whitelist; hosts can extend it with registerop!.)")
    end
    error(what * ": unknown function '" * string(fname) *
          "'. Registered operations: " * join(listops(), ", ") *
          ". (Hosts can extend the whitelist with registerop!.)")
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
                    error(what * ": unsupported keyword syntax " * string(p))
                push!(kts, p.args[1] => compile_node(p.args[2], cols, what))
            end
        elseif Base.Meta.isexpr(a, :kw)          # f(x, k = v) form
            isa(a.args[1], Symbol) ||
                error(what * ": unsupported keyword syntax " * string(a))
            push!(kts, a.args[1] => compile_node(a.args[2], cols, what))
        else
            push!(pts, compile_node(a, cols, what))
        end
    end
    if isempty(kts)
        return vals -> op((t(vals) for t in pts)...)
    else
        return vals -> op(
            (t(vals) for t in pts)...;
            Pair{Symbol,Any}[k => t(vals) for (k, t) in kts]...,
        )
    end
end

# ---- entry points -----------------------------------------------------------

function safe_parse(s::AbstractString, what::String)
    ex = try
        Meta.parse(s)
    catch
        error(what * ": cannot parse \"" * s * "\"")
    end
    ex === nothing && error(what * ": empty spec")
    if isa(ex, Expr) && ex.head == :incomplete
        error(what * ": incomplete expression \"" * s * "\"")
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
    by = Symbol[]
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
        else # :groupby -- bare columns (varargs) or one [col, ...] array
            isempty(by) || error(what * ": duplicate groupby modifier")
            for a in args
                s = simple_posarg(a)
                if isa(s, Symbol)
                    push!(by, s)
                elseif isa(s, Vector{Symbol})
                    append!(by, s)
                else
                    error(what * ": groupby expects column names, got " * string(a))
                end
            end
            isempty(by) && error(what * ": groupby needs at least one column")
        end
        ex = lhs
    end
    (ex, order, by)
end

# checkcols: validate a spec's column references against the columns a host
# knows to exist (typically propertynames(df)), with did-you-mean repair --
# the TUI path, where a misspelled column would otherwise surface much later
# as a bare DataFrames indexing error. `_` is the aggregation target, not a
# column reference. Returns the spec for chaining.
function checkcols(s::Union{SafeAggrSpec,SafeDimSpec}, columns::AbstractVector{Symbol})
    refs = isa(s, SafeAggrSpec) ? setdiff(s.cols, [:_]) :
           union(s.cols, first.(s.order), s.by)
    for c in refs
        if !in(c, columns)
            hint = didyoumean(c, sort(columns))
            error("checkcols: spec \"" * s.source * "\" references column '" *
                  string(c) * "', which does not exist" *
                  (isempty(hint) ? ". Available columns: " *
                                   join(sort(columns), ", ") : hint))
        end
    end
    s
end

# repeated parses of the same string return the identical spec object
const SafeSpecCache = Dict{Tuple{Symbol,String},Any}()

function parseaggr(
    s::AbstractString;
    columns::Union{Nothing,AbstractVector{Symbol}} = nothing,
)
    spec = get!(SafeSpecCache, (:aggr, String(strip(s)))) do
        parseaggr_impl(String(strip(s)))
    end::SafeAggrSpec
    # validated per call, outside the cache: the same spec may be checked
    # against different frames
    columns === nothing ? spec : checkcols(spec, columns)
end

function parseaggr_impl(src::String)
    ex = safe_parse(src, "parseaggr")
    if ismodifiershape(ex) && (ismodifiercall(ex.args[2]) || ismodifiercall(ex.args[3]))
        error("parseaggr: modifiers (orderby, groupby) are dimension-spec " *
              "features; an aggregation spec just reduces a column, e.g. " *
              "\"sum(_ * wt) / sum(wt)\" -- ordering and grouping happen " *
              "in the dim/agg call around it")
    end
    if isa(ex, Symbol)                   # aggr"sum" -- bare registered name
        haskey(SafeOps, ex) || unknown_op_error("parseaggr", ex)
        ex = Expr(:call, ex, :_)         # lower to sum(_), like trusted :sum
    end
    isa(ex, Expr) && ex.head == :call ||
        error("parseaggr: spec must be a function call or a registered " *
              "function name, got \"" * src * "\"")
    cols = Symbol[]
    thunk = compile_node(ex, cols, "parseaggr")
    SafeAggrSpec(src, ex.args[1], (vs...) -> thunk(vs), cols)
end

function parsedim(
    s::AbstractString;
    columns::Union{Nothing,AbstractVector{Symbol}} = nothing,
)
    spec = get!(SafeSpecCache, (:dim, String(strip(s)))) do
        parsedim_impl(String(strip(s)))
    end::SafeDimSpec
    # validated per call, outside the cache: the same spec may be checked
    # against different frames
    columns === nothing ? spec : checkcols(spec, columns)
end

function parsedim_impl(src::String)
    ex = safe_parse(src, "parsedim")
    (ex, order, by) = peel_modifiers(ex, "parsedim")
    if !(isa(ex, Expr) && ex.head == :call)
        if isa(ex, Symbol) && haskey(SafeOps, ex)
            error("parsedim: '" * src * "' is an operator name -- write it " *
                  "as a call: \"" * src * "(col)\"")
        elseif isa(ex, Symbol)
            error("parsedim: a bare column name is a chain KEY, not a " *
                  "dimension spec -- list it directly in the chain " *
                  "([:region, :" * src * "]); a dim spec computes something, " *
                  "e.g. \"cumsum(" * src * ")\"")
        end
        error("parsedim: spec must be a function call (e.g. \"cumsum(sales)\"), got \"" *
              src * "\"")
    end
    cols = Symbol[]
    thunk = compile_node(ex, cols, "parsedim")
    in(:_, cols) &&
        error("parsedim: '_' is the aggregation target placeholder and has " *
              "no meaning in a dim spec")
    posargs = Any[simple_posarg(a) for a in positional_args(ex)]
    SafeDimSpec(src, ex.args[1], (vs...) -> thunk(vs), cols, posargs, order, by)
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
    ret = (_df_::AbstractDataFrame) -> f((_df_[!, col === :_ ? c : col] for col in cols)...)
    DataFrameAggrCache[(c, s)] = ret
end
