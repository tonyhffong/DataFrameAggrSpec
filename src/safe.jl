# The untrusted spec DSL -- PUBLIC FACE: the spec types, the parse entry
# points (parseaggr / parsedim and their string macros), the spec cache, and
# the column check a host runs against its frame.
#
# Safety comes from a whitelist registry (registry.jl) plus a default-deny
# grammar interpreted by a closure compiler (compile.jl) -- there is NO eval
# anywhere on this path, so it shares nothing with the trusted compiler except
# the (f, cols) kernel contract, and the resulting closures live at the current
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
# THE CLUSTER. This file was one 1362-line file until the split; the pieces
# are, in include order:
#   registry.jl    -- SafeOps/SafeOpShapes, registerop!, the shipped operators
#   rejections.jl  -- the error vocabulary and with_spec_context
#   checks.jl      -- arity/keyword/shape checks decided at parse time
#   compile.jl     -- the AST -> closure compiler
#   parse.jl       -- Meta.parse, modifier peeling, where desugaring
#   safe.jl        -- this file: the types and the public doors
# Only registry.jl has a hard ORDER requirement (it registers verbs at load
# time, so it follows verbs.jl); this file must precede dimension.jl, whose
# signatures mention SafeDimSpec. The middle four are function bodies and
# consts, so they are ordered for reading, not for the loader.
#
# One deliberate BACKWARD reference: liftAggrSpecToFunc's SafeAggrSpec method
# calls order_indices, defined later in dimension.jl with the rest of the
# ordering primitives. That is fine -- the call sits inside a runtime closure,
# so the name resolves at call time (whole module loaded), not at include
# time. Keep any NEW backward reference to the same shape.

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

# flatten a `by` list (bare column Symbols and/or GroupByKeys) to the REAL
# columns that must exist on the host's frame -- a GroupByKey's synthetic
# gensym'd name never does. Shared by checkcols here and PivotDim's
# required_columns (dimension.jl).
byrefs(by) = Symbol[c for k in by for c in (isa(k, Symbol) ? (k,) : k.cols)]

# checkcols: validate a spec's column references against the columns a host
# knows to exist (typically propertynames(df)), with did-you-mean repair --
# the TUI path, where a misspelled column would otherwise surface much later
# as a bare DataFrames indexing error. `_` is the aggregation target, not a
# column reference. Returns the spec for chaining.
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
    ex = safe_parse(src, :aggr)
    # orderby IS a legal top-level modifier here (sort the group's rows
    # before the reduction runs -- see SafeAggrSpec.order); groupby is not
    # (an aggregation spec must reduce to ONE value, and a grouped reduction
    # yields one value per key -- that stays the NESTED composite form).
    # Reuse the exact same peeling dim specs use, rather than a parallel
    # implementation.
    (ex, order, by) = peel_modifiers(ex)
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
            unknown_op_error(ex)
        end
        ex = Expr(:call, ex, :_)         # lower to sum(_), like trusted :sum
    end
    isa(ex, Expr) && (ex.head == :call || iscondshape(ex)) ||
        shape_error(ex, src,
                    "spec must be a function call or a registered function name")
    desugar_where!(ex)
    cols = Symbol[]
    thunk = compile_node(ex, cols)
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
        check_mapshape(ex.args[1], ex)
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
    ex = safe_parse(src, :dim)
    (ex, order, by) = peel_modifiers(ex)
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
        shape_error(ex, src,
                    "spec must be a function call (e.g. \"cumsum(sales)\")")
    end
    desugar_where!(ex)
    cols = Symbol[]
    thunk = compile_node(ex, cols)
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
        check_mapshape(ex.args[1], ex)
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
