# aggregate: one row per group of keycols, every other requested column reduced
# per its resolved aggregation spec. The non-UI core of TermWin's leaf aggregation.
function aggregate(
    df::AbstractDataFrame,
    keycols::AbstractVector{Symbol};
    hints::AggrHints = AggrHints(),
    cols::AbstractVector{Symbol} = setdiff(propertynames(df), keycols),
)
    funcs = Dict{Symbol,Function}(
        c => liftAggrSpecToFunc(c, resolveaggr(hints, c, eltype(df[!, c]))) for c in cols
    )
    gd = groupby(df, collect(keycols); sort = false, skipmissing = false)
    combine(gd) do sdf
        # invokelatest: lifted aggregators live at a newer world age than this closure
        DataFrame([c => [aggrvalue(Base.invokelatest(funcs[c], sdf))] for c in cols]...)
    end
end

aggregate(df::AbstractDataFrame, keycol::Symbol; kwargs...) =
    aggregate(df, [keycol]; kwargs...)

# pivottable: materialize a chain's inline dimensions, then aggregate every
# remaining column over the full key list -- the one-call groupby-with-
# on-the-fly-dimensions. The non-UI core of TermWin's pivot tree.
function pivottable(
    df::AbstractDataFrame,
    chain::Union{AbstractVector,Tuple};
    hints::AggrHints = AggrHints(),
)
    keycols, dims = normalize_chain(chain)
    if !isempty(dims)
        df = applydims!(copyframe(df), dims; hints = hints)
    end
    aggregate(df, keycols; hints = hints)
end

pivottable(df::AbstractDataFrame, key::Symbol; kwargs...) = pivottable(df, [key]; kwargs...)

# ------------------------------------------------------------- transforms --
# Curried forms return reusable callables, so pipelines compose:
#   df |> dim(chain) |> pivottable(keys)      (t2 ∘ t1)(df)      df ∘ dim(chain)

struct DimTransform
    specs::Tuple
    hints::AggrHints
    replace::Bool
end
(t::DimTransform)(df::AbstractDataFrame) =
    dim(df, t.specs...; hints = t.hints, replace = t.replace)

dim(chains::Union{Pair,AbstractVector,Tuple}...; hints::AggrHints = AggrHints(),
    replace::Bool = false) = DimTransform(chains, hints, replace)

struct PivotTransform
    chain::Any
    hints::AggrHints
end
(t::PivotTransform)(df::AbstractDataFrame) = pivottable(df, t.chain; hints = t.hints)

pivottable(chain::Union{AbstractVector,Tuple,Symbol}; hints::AggrHints = AggrHints()) =
    PivotTransform(chain, hints)
