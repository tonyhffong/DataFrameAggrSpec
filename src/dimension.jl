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
#                  rows.

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
    spec::Union{Expr,AbstractString,Function,SafeDimSpec};
    by = Symbol[],
    order = Pair{Symbol,Bool}[],
)
    if isa(spec, AbstractString)
        spec = parsedim(spec)   # Strings are UNTRUSTED: safe whitelist grammar
    end
    refs = Symbol[]
    if isa(spec, Expr)
        check_spec_call(spec, "WindowDim")
        refs = referenced_columns(spec)
    elseif isa(spec, SafeDimSpec)
        isempty(spec.by) || error(
            "WindowDim " * string(name) * ": the groupby modifier implies pivot kind",
        )
        refs = copy(spec.cols)
        if !isempty(spec.order)   # from a peeled `... |> orderby(cols...)`
            if isempty(normalize_order(order))
                order = spec.order
            else
                error(
                    "WindowDim " * string(name) * ": order given both in the " *
                    "spec string (orderby) and via dimspec/order",
                )
            end
        end
    end
    WindowDim(name, spec, tosyms(by), normalize_order(order), refs)
end

# dependencies: every column the dimension needs -- the spec's references plus
# any ordering columns (planners like TermWin read this to know what to carry)
dependencies(d::WindowDim) = union(d.refs, Symbol[p.first for p in d.order])

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

# kernel: (f, cols) for any dimension spec kind. Trusted Exprs go through the
# eval'd (cached) window_kernel; untrusted SafeDimSpecs are already compiled.
kernel(ex::Expr) = window_kernel(ex)
kernel(s::SafeDimSpec) = (s.f, s.cols)

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
    kernelf, cols = isa(d.spec, Function) ? (d.spec, Symbol[]) : kernel(d.spec)
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
    spec::Union{Expr,SafeDimSpec}
    by::Vector{Union{Symbol,GroupByKey}}  # inner grouping keys (the groups
                             # being classified) -- bare columns or, from a
                             # safe-string `groupby(computed_expr)`, GroupByKeys
    context::Vector{Symbol}  # outer partition: classification runs per context group
    deps::Vector{Symbol}     # referenced non-key columns, aggregated per inner group
    order::Vector{Pair{Symbol,Bool}}  # GROUP-level ordering: sort the inner
                             # groups (by keys or aggregated deps) before the
                             # kernel runs -- the Pareto idiom. Empty = groups
                             # arrive in encounter order.
end

# grouping keys implied by classifier verbs (ClassifierVerbs table, safe.jl),
# auto-added to a PivotDim's `by` -- e.g. topnames' name column (argument 1)
expr_sym(a) =
    isa(a, QuoteNode) && isa(a.value, Symbol) ? a.value :
    Base.Meta.isexpr(a, :quote, 1) && isa(a.args[1], Symbol) ? a.args[1] : nothing

groupkey_error(fname::Symbol, argpos::Int) = error(
    string(fname) * ": argument " * string(argpos) *
    " expects a grouping column (name column)",
)

function pivot_groupkeys(fname::Symbol, spec::Expr)
    argpos = get(ClassifierVerbs, fname, 0)
    argpos == 0 && return Symbol[]
    pa = positional_args(spec)
    s = length(pa) >= argpos ? expr_sym(pa[argpos]) : nothing
    s === nothing && groupkey_error(fname, argpos)
    Symbol[s]
end

function pivot_groupkeys(fname::Symbol, sd::SafeDimSpec)
    argpos = get(ClassifierVerbs, fname, 0)
    argpos == 0 && return Symbol[]
    (length(sd.posargs) >= argpos && isa(sd.posargs[argpos], Symbol)) ||
        groupkey_error(fname, argpos)
    Symbol[sd.posargs[argpos]]
end

function PivotDim(
    name::Symbol,
    spec::Union{Expr,AbstractString,SafeDimSpec};
    by = Symbol[],
    context = Symbol[],
    order = Pair{Symbol,Bool}[],
)
    if isa(spec, AbstractString)
        spec = parsedim(spec)   # Strings are UNTRUSTED: safe whitelist grammar
    end
    orderv = normalize_order(order)
    if isa(spec, SafeDimSpec)
        fname = spec.fname
        refs = copy(spec.cols)
        if !isempty(spec.order)   # from a peeled `... |> orderby(cols...)`
            if isempty(orderv)
                orderv = spec.order
            else
                error(
                    "PivotDim " * string(name) * ": order given both in the " *
                    "spec string (orderby) and via dimspec/order",
                )
            end
        end
    else
        fname = check_spec_call(spec, "PivotDim")
        refs = referenced_columns(spec)
    end
    byv = tosyms(by)
    ctxv = tosyms(context)
    if isa(spec, SafeDimSpec) && !isempty(spec.by)   # `|> groupby(keys...)`
        if haskey(ClassifierVerbs, spec.fname)
            error(
                "PivotDim " * string(name) * ": " * string(spec.fname) *
                " declares its own grouping (argument " *
                string(ClassifierVerbs[spec.fname]) *
                "); remove the groupby modifier",
            )
        end
        if isempty(byv)
            byv = copy(spec.by)
        else
            error(
                "PivotDim " * string(name) * ": grouping given both in the " *
                "spec string (groupby) and via dimspec/by",
            )
        end
    end
    for k in pivot_groupkeys(fname, spec)
        in(k, byv) || push!(byv, k)
    end
    isempty(byv) && error("PivotDim " * string(name) * ": non-empty `by` required")
    # order columns are dependencies too: non-key order columns get aggregated
    # per hints exactly like spec references (the group-level sort needs them)
    deps = setdiff(union(refs, Symbol[p.first for p in orderv]), union(byv, ctxv))
    PivotDim(name, spec, byv, ctxv, deps, orderv)
end

dependencies(d::PivotDim) = d.deps

function pivot_values(df::AbstractDataFrame, d::PivotDim, hints::AggrHints)
    kernelf, cols = kernel(d.spec)
    ocols = Symbol[p.first for p in d.order]
    orevs = Bool[p.second for p in d.order]
    need = union(cols, ocols)   # group-level values: spec refs ∪ order columns
    aggrfuncs = Dict{Symbol,Function}(
        c => liftAggrSpecToFunc(c, resolveaggr(hints, c, eltype(df[!, c]))) for c in d.deps
    )
    out = Vector{Any}(undef, nrow(df))
    anycat = false
    haskeyexpr = any(k -> isa(k, GroupByKey), d.by)
    for ctxidxs in partition_indices(df, d.context)
        sub = view(df, ctxidxs, :)
        if haskeyexpr
            # at least one groupby key is a computed expression (e.g.
            # yyyymm(date)) -- DataFrames.groupby needs real columns, so
            # materialize each computed key as a gensym'd column on a copy
            # of this context partition before grouping. Bare-column keys
            # (the common case) keep the zero-copy SubDataFrame path below.
            grpdf = DataFrame(sub; copycols = true)
            bynames = Symbol[]
            for k in d.by
                if isa(k, Symbol)
                    push!(bynames, k)
                else
                    grpdf[!, k.name] = k.f(Tuple(grpdf[!, c] for c in k.cols))
                    push!(bynames, k.name)
                end
            end
            gd = groupby(grpdf, bynames; sort = false, skipmissing = false)
        else
            gd = groupby(sub, Symbol[k for k in d.by]; sort = false, skipmissing = false)
        end
        gidx = groupindices(gd)          # inner group index per sub row
        ng = length(gd)
        # one row per inner group: key columns take the group value,
        # dep columns are aggregated with the resolved hints
        colvals = Dict{Symbol,Any}()
        for c in need
            if c in d.deps
                # invokelatest: lifted aggregators live at a newer world age
                colvals[c] = [aggrvalue(Base.invokelatest(aggrfuncs[c], g)) for g in gd]
            else
                # key columns may be categorical (e.g. an earlier classifier's
                # output); unwrap so the verb sees plain values, not
                # CategoricalValues (unwrap is identity on everything else)
                colvals[c] = [unwrap(first(g[!, c])) for g in gd]
            end
        end
        # `orderby` on a pivot dim sorts the GROUPS before the kernel runs
        # (group keys or hint-aggregated measures -- the Pareto idiom); labels
        # scatter back through the inverse permutation, the same idiom as
        # window ordering one level down. Textual modifier order is
        # non-semantic (design/compound-modifiers.md).
        pos = 1:ng                       # group index -> kernel input position
        if !isempty(d.order)
            odf = DataFrame(AbstractVector[colvals[oc] for oc in ocols], ocols)
            perm = sortperm(odf, ocols, rev = orevs)
            for c in need
                colvals[c] = colvals[c][perm]
            end
            pos = invperm(perm)
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
            out[ctxidxs[i]] = labels[pos[g]]
        end
    end
    # re-wrap as categorical: verb labels carry zero-padded rank prefixes, so the
    # default lexical level order is the intended one even across context partitions
    anycat ? categorical(identity.(out)) : identity.(out)
end

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

# every column a dimension reads from the frame: the planner-facing
# dependencies plus its partition/grouping keys
required_columns(d::WindowDim) = union(dependencies(d), d.by)
# a GroupByKey's real columns (byrefs, safe.jl) are what must exist on the
# frame -- never its synthetic gensym'd name
required_columns(d::PivotDim) = union(d.deps, byrefs(d.by), d.context)

# applydims!: internal apply loop over resolved dimensions. Missing inputs are
# caught up front with a did-you-mean hint (the TUI path: a misspelled column
# in a spec string would otherwise die deep inside groupby/indexing); later
# dims legitimately see the columns earlier dims added.
function applydims!(
    df::DataFrame,
    dims::Vector{AbstractDimension};
    hints::AggrHints = AggrHints(),
    replace::Bool = false,
)
    for d in dims
        for c in required_columns(d)
            hasproperty(df, c) || error(
                "dimension " * string(d.name) * ": no column " * string(c) *
                didyoumean(c, sort(propertynames(df))))
        end
        apply_dimension!(df, d; hints = hints, replace = replace)
    end
    df
end

copyframe(df::DataFrame) = copy(df; copycols = false)
copyframe(df::AbstractDataFrame) = DataFrame(df)   # SubDataFrame etc.

# dim! / dim: CHAINS are the only public entry -- Symbol keys, `name => spec`
# declarations (a bare Pair is a one-entry chain), and dimspec(...) options;
# see chain.jl. Dimensions apply in order, so a later
# one may reference an earlier one's output column. `dim` copies
# (SubDataFrame-friendly) so the input frame is never touched.
function dim!(
    df::DataFrame,
    chains::Union{Pair,AbstractVector}...;
    hints::AggrHints = AggrHints(),
    replace::Bool = false,
)
    for c in chains
        if isa(c, Pair)   # a single name => spec declaration, empty context
            (_, dims) = normalize_chain([c])
        else
            (_, dims) = normalize_chain(c)
            isempty(dims) &&
                error("dim!: chain " * string(c) * " declares no dimensions")
        end
        applydims!(df, dims; hints = hints, replace = replace)
    end
    df
end

dim(df::AbstractDataFrame, args...; kwargs...) = dim!(copyframe(df), args...; kwargs...)
