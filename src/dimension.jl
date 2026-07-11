# Dimensioning: NEW columns whose values are computed from "sibling" rows --
# rows sharing the same partition-key values. Existing data is never modified.
#
# Two kinds, dispatched on type (see README):
#   * WindowDim -- `:col` binds to the partition's row-level subvector
#                  (order-sorted if `order` is given); the spec result is a
#                  scalar (broadcast to the partition) or a partition-length
#                  vector. Covers group totals, shares, z-scores, rank/cumsum/
#                  lag/lead.
#   * PivotDim  -- classify *groups* by their aggregates (topnames, discretize
#                  over group sums); one label per group, broadcast to member
#                  rows. The heir of the legacy CalcPivot.

abstract type AbstractDimension end

# ---------------------------------------------------------------- ordering --

# normalize order inputs to Vector{Pair{Symbol,Bool}} (col => rev)
orderentry(s::Symbol) = s => false
orderentry(p::Pair{Symbol,Bool}) = p
function orderentry(p::Pair{Symbol,Symbol})
    if p.second == :asc
        p.first => false
    elseif p.second == :desc
        p.first => true
    else
        error("order direction must be :asc or :desc, got " * string(p.second))
    end
end
orderentry(s::AbstractString) = orderentry_parsed(Meta.parse(s))
orderentry(x) = error("cannot interpret order entry " * string(x))

# interpret a *literal* parsed order entry -- no eval
function orderentry_parsed(ex)
    if isa(ex, Symbol)
        return ex => false
    elseif isa(ex, QuoteNode) && isa(ex.value, Symbol)
        return ex.value => false
    elseif Base.Meta.isexpr(ex, :call, 3) && ex.args[1] == :(=>)
        col = literal_symbol(ex.args[2])
        dir = literal_symbol(ex.args[3])
        return orderentry(col => dir)
    end
    error("cannot interpret order entry " * string(ex))
end

function literal_symbol(x)
    isa(x, Symbol) && return x
    isa(x, QuoteNode) && isa(x.value, Symbol) && return x.value
    Base.Meta.isexpr(x, :quote, 1) && isa(x.args[1], Symbol) && return x.args[1]
    error("expected a symbol literal, got " * string(x))
end

normalize_order(x::Union{AbstractVector,Tuple}) =
    Pair{Symbol,Bool}[orderentry(e) for e in x]
normalize_order(x) = Pair{Symbol,Bool}[orderentry(x)]

tosyms(x::Symbol) = Symbol[x]
tosyms(x::AbstractString) = Symbol[Symbol(x)]
tosyms(x::Union{AbstractVector,Tuple}) = Symbol[Symbol(e) for e in x]

# --------------------------------------------------------------- WindowDim --

struct WindowDim <: AbstractDimension
    name::Symbol
    spec::Any                        # Expr, or Function f(::AbstractDataFrame)
    by::Vector{Symbol}
    order::Vector{Pair{Symbol,Bool}}
    refs::Vector{Symbol}             # columns the spec expression references
end

function WindowDim(
    name::Symbol,
    spec::Union{Expr,AbstractString,Function};
    by = Symbol[],
    order = Pair{Symbol,Bool}[],
)
    if isa(spec, AbstractString)
        spec = Meta.parse(spec)
    end
    refs = Symbol[]
    if isa(spec, Expr)
        check_spec_call(spec, "WindowDim")
        refs = referenced_columns(spec)
    end
    WindowDim(name, spec, tosyms(by), normalize_order(order), refs)
end

dependencies(d::WindowDim) = d.refs

# window kernels: f(colvec1, colvec2, ...) compiled from the spec expression,
# cached on the spec alone (partitioning/ordering happen outside the kernel).
# Returns (func, cols) with cols in the kernel's argument order.
const WindowKernelCache = Dict{Any,Tuple{Function,Vector{Symbol}}}()

function window_kernel(ex::Expr)
    if haskey(WindowKernelCache, ex)
        return WindowKernelCache[ex]
    end
    cex = deepcopy(ex)
    convertExpression!(cex)
    membernames = Dict{Symbol,Symbol}()
    cex = replace_col_syms(cex, membernames)
    cols = collect(keys(membernames))
    vars = [membernames[c] for c in cols]
    funname = gensym("DFWindow")
    code = :(function $funname($(vars...))
        $cex
    end)
    # Eval in Main so module-qualified names in the user-supplied expression
    # resolve against the user's loaded packages (see module trust boundary).
    f = Core.eval(Main, code)
    WindowKernelCache[ex] = (f, cols)
end

# partition row-index lists for a by-key set (empty by = one whole-frame partition)
function partition_indices(df::AbstractDataFrame, by::Vector{Symbol})
    if isempty(by)
        return [collect(1:nrow(df))]
    end
    gd = groupby(df, by; sort = false, skipmissing = false)
    gidx = groupindices(gd)
    idxlists = [Int[] for _ = 1:length(gd)]
    for (i, g) in enumerate(gidx)
        push!(idxlists[g], i)
    end
    idxlists
end

function window_values(df::AbstractDataFrame, d::WindowDim)
    n = nrow(df)
    out = Vector{Any}(undef, n)
    kernelf, cols = isa(d.spec, Function) ? (d.spec, Symbol[]) : window_kernel(d.spec)
    for idxs in partition_indices(df, d.by)
        ridx = idxs
        if !isempty(d.order)
            ocols = [p.first for p in d.order]
            revs = [p.second for p in d.order]
            perm = sortperm(df[idxs, ocols], ocols, rev = revs)
            ridx = idxs[perm]
        end
        # invokelatest: kernels are eval'd at a newer world age than this loop
        if isa(d.spec, Function)
            res = Base.invokelatest(kernelf, view(df, ridx, :))
        else
            args = Any[df[ridx, c] for c in cols]
            res = Base.invokelatest(kernelf, args...)
        end
        if isa(res, AbstractVector)
            if length(res) != length(ridx)
                error(
                    "WindowDim " * string(d.name) * ": spec returned a vector of length " *
                    string(length(res)) * " for a partition of " * string(length(ridx)) *
                    " rows",
                )
            end
            out[ridx] = res      # aligned to the (possibly order-sorted) rows
        else
            for i in ridx
                out[i] = res     # scalar: broadcast to the whole partition
            end
        end
    end
    identity.(out)               # narrow eltype from Any
end

# ---------------------------------------------------------------- PivotDim --

struct PivotDim <: AbstractDimension
    name::Symbol
    spec::Expr
    by::Vector{Symbol}       # inner grouping keys (the groups being classified)
    context::Vector{Symbol}  # outer partition: classification runs per context group
    deps::Vector{Symbol}     # referenced non-key columns, aggregated per inner group
end

function PivotDim(
    name::Symbol,
    spec::Union{Expr,AbstractString};
    by = Symbol[],
    context = Symbol[],
)
    if isa(spec, AbstractString)
        spec = Meta.parse(spec)
    end
    fname = check_spec_call(spec, "PivotDim")
    byv = tosyms(by)
    ctxv = tosyms(context)
    if fname == :topnames # ensure the name column is an inner grouping key
        if isa(spec.args[2], QuoteNode)
            name_col = spec.args[2].value
        elseif Base.Meta.isexpr(spec.args[2], :quote)
            name_col = spec.args[2].args[1]
        else
            error("topnames: 1st argument expects a symbol (name column)")
        end
        in(name_col, byv) || push!(byv, name_col)
    end
    isempty(byv) && error("PivotDim " * string(name) * ": non-empty `by` required")
    deps = setdiff(referenced_columns(spec), union(byv, ctxv))
    PivotDim(name, spec, byv, ctxv, deps)
end

dependencies(d::PivotDim) = d.deps

function pivot_values(df::AbstractDataFrame, d::PivotDim, hints::AggrHints)
    kernelf, cols = window_kernel(d.spec)
    aggrfuncs = Dict{Symbol,Function}(
        c => liftAggrSpecToFunc(c, resolveaggr(hints, c, eltype(df[!, c]))) for c in d.deps
    )
    out = Vector{Any}(undef, nrow(df))
    anycat = false
    for ctxidxs in partition_indices(df, d.context)
        sub = view(df, ctxidxs, :)
        gd = groupby(sub, d.by; sort = false, skipmissing = false)
        gidx = groupindices(gd)          # inner group index per sub row
        ng = length(gd)
        # one row per inner group: key columns take the group value,
        # dep columns are aggregated with the resolved hints
        colvals = Dict{Symbol,Any}()
        for c in cols
            if c in d.deps
                # invokelatest: lifted aggregators live at a newer world age
                colvals[c] = [aggrvalue(Base.invokelatest(aggrfuncs[c], g)) for g in gd]
            else
                colvals[c] = [first(g[!, c]) for g in gd]
            end
        end
        labels = Base.invokelatest(kernelf, Any[colvals[c] for c in cols]...)
        if !(isa(labels, AbstractVector) && length(labels) == ng)
            error(
                "PivotDim " * string(d.name) *
                ": spec must return one value per group (" * string(ng) * " groups)",
            )
        end
        if isa(labels, CategoricalArray)
            anycat = true
            labels = unwrap.(labels)
        end
        for (i, g) in enumerate(gidx)
            out[ctxidxs[i]] = labels[g]
        end
    end
    # re-wrap as categorical: verb labels carry zero-padded rank prefixes, so the
    # default lexical level order is the intended one even across context partitions
    anycat ? categorical(identity.(out)) : identity.(out)
end

# ------------------------------------------------------- Dimension factory --

# umbrella constructor: picks the kind. :auto = window, except a top-level
# `topnames` call which is inherently group-classifying (matches legacy CalcPivot).
function Dimension(
    name::Symbol,
    spec::Union{Expr,AbstractString,Function};
    by = Symbol[],
    order = Pair{Symbol,Bool}[],
    context = Symbol[],
    kind::Symbol = :auto,
)
    if isa(spec, AbstractString)
        spec = Meta.parse(spec)
    end
    if kind == :auto
        kind =
            isa(spec, Expr) && check_spec_call(spec, "Dimension") == :topnames ? :pivot :
            :window
    end
    if kind == :window
        WindowDim(name, spec; by = by, order = order)
    elseif kind == :pivot
        PivotDim(name, spec; by = by, context = context)
    else
        error("Dimension: kind must be :window or :pivot, got " * string(kind))
    end
end

# legacy conversion: a CalcPivot's `by` are inner grouping keys; TermWin's tree
# supplied the outer context implicitly by pre-filtering rows
Dimension(name::Symbol, cp::CalcPivot; context = Symbol[]) =
    isempty(cp.by) ? WindowDim(name, cp.spec) :
    PivotDim(name, cp.spec; by = cp.by, context = context)

# ------------------------------------------------------------- application --

function checkcollision!(df::AbstractDataFrame, name::Symbol, replace::Bool)
    if !replace && name in propertynames(df)
        error(
            "dimension " * string(name) *
            " interferes with an existing column; pass replace=true to overwrite",
        )
    end
end

function apply_dimension!(
    df::DataFrame,
    d::WindowDim;
    hints::AggrHints = AggrHints(),
    replace::Bool = false,
)
    checkcollision!(df, d.name, replace)
    df[!, d.name] = window_values(df, d)
    df
end

function apply_dimension!(
    df::DataFrame,
    d::PivotDim;
    hints::AggrHints = AggrHints(),
    replace::Bool = false,
)
    checkcollision!(df, d.name, replace)
    df[!, d.name] = pivot_values(df, d, hints)
    df
end

# dim! / dim: apply dimensions in order; a later dimension may reference an
# earlier dimension's output column. Accepts concrete dimensions, name => spec
# pairs, and chains (see chain.jl). `dim` copies (SubDataFrame-friendly) so
# the input frame is never touched.
function dim!(
    df::DataFrame,
    specs...;
    hints::AggrHints = AggrHints(),
    replace::Bool = false,
)
    for s in specs
        if isa(s, AbstractDimension)
            apply_dimension!(df, s; hints = hints, replace = replace)
        elseif isa(s, Pair)   # a single name => spec declaration, empty context
            (_, dims) = normalize_chain([s])
            apply_dimension!(df, dims[1]; hints = hints, replace = replace)
        else
            (_, dims) = normalize_chain(s)
            isempty(dims) &&
                error("dim!: chain " * string(s) * " declares no dimensions")
            for d in dims
                apply_dimension!(df, d; hints = hints, replace = replace)
            end
        end
    end
    df
end

dim(df::DataFrame, args...; kwargs...) = dim!(copy(df; copycols = false), args...; kwargs...)
dim(df::SubDataFrame, args...; kwargs...) = dim!(DataFrame(df), args...; kwargs...)
