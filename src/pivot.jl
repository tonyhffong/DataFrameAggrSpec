# agg: group-and-reduce over a CHAIN -- the single public aggregation verb.
#
# A chain entry is either a bare Symbol (an EXISTING key column) or a
# `name => spec` declaration of an on-the-fly dimension (discretize / topnames
# buckets, ...). Declared dimensions are materialized first, then every entry --
# existing or computed -- serves as a grouping key; all remaining columns are
# reduced by their resolved AggrHints spec, yielding one row per key combination.
# So the caller never distinguishes "group by an existing column" from "group by
# a derived one" -- both are just chain entries.
#
# `agg` is the reducing sibling of `dim`: `dim(df, chain)` ADDS the chain's
# columns and keeps every row; `agg(df, chain)` groups by them and collapses.
# `cols` selects and names the reductions (default: all non-key columns via
# hints); `allbut = [:gap]` is its mirror image -- the default hints-driven
# set minus the listed columns (the two are mutually exclusive).
# Each `cols` entry is one output column, DataFrames.jl-style:
#   :qty                          hints-resolved spec, output :qty
#   :score => spec                inline spec override, output stays :score
#   :score => spec => :score_avg  named measure -- the same source column may
#                                 appear any number of times under distinct names
# The spec slot takes anything liftAggrSpecToFunc takes (String = UNTRUSTED safe
# grammar, Symbol/Expr/Function trusted, SafeAggrSpec); `_`/`:_` binds to the
# left (source) column. Specs are never Pairs, so the forms are unambiguous.
function normalize_measures(
    df::AbstractDataFrame,
    entries::AbstractVector,
    keycols::AbstractVector{Symbol},
    hints::AggrHints,
)
    measures = @NamedTuple{out::Symbol, src::Symbol, func::Function}[]
    for entry in entries
        if isa(entry, Symbol)
            out, src, spec = entry, entry, nothing
        elseif isa(entry, Pair) && isa(entry.first, Symbol)
            src = entry.first
            if isa(entry.second, Pair)   # :src => spec => :out
                spec = entry.second.first
                out = entry.second.second
                isa(out, Symbol) || error(
                    "agg cols: output name in " * string(entry) * " must be a Symbol")
            else                          # :src => spec
                spec, out = entry.second, src
            end
        else
            error("agg cols: entries must be a column Symbol, `col => spec`, or " *
                  "`col => spec => outname`, got " * string(entry))
        end
        hasproperty(df, src) || error("agg cols: no column " * string(src) *
                                      didyoumean(src, sort(propertynames(df))))
        spec === nothing && (spec = resolveaggr(hints, src, eltype(df[!, src])))
        out in keycols && error(
            "agg cols: output name " * string(out) * " collides with a chain key")
        any(m -> m.out == out, measures) && error(
            "agg cols: duplicate output name " * string(out))
        push!(measures, (out = out, src = src, func = liftAggrSpecToFunc(src, spec)))
    end
    measures
end

function agg(
    df::AbstractDataFrame,
    chain::AbstractVector;
    hints::AggrHints = AggrHints(),
    cols::Union{Nothing,AbstractVector} = nothing,
    allbut::Union{Nothing,Symbol,AbstractVector} = nothing,
)
    # `allbut` is the mirror image of `cols`: keep the default hints-driven
    # reduction for every non-key column EXCEPT these. Both are selection
    # modes, so they are mutually exclusive -- an error, never precedence.
    cols !== nothing && allbut !== nothing && error(
        "agg: cols and allbut are mutually exclusive -- cols enumerates the " *
        "measures, allbut excludes from the default (all non-key columns)")
    keycols, dims = normalize_chain(chain)
    if !isempty(dims)
        df = applydims!(copyframe(df), dims; hints = hints)
    end
    for k in keycols   # fail here, not deep inside groupby
        hasproperty(df, k) || error("agg: no key column " * string(k) *
                                    didyoumean(k, sort(propertynames(df))))
    end
    if allbut === nothing
        entries = cols === nothing ? setdiff(propertynames(df), keycols) : cols
    else
        ab = tosyms(allbut)
        for c in ab
            hasproperty(df, c) || error("agg: allbut column " * string(c) *
                " does not exist" * didyoumean(c, sort(propertynames(df))))
            in(c, keycols) && error("agg: allbut excludes measures, but " *
                string(c) * " is a chain key -- remove it from the chain instead")
        end
        entries = setdiff(propertynames(df), keycols, ab)
    end
    measures = normalize_measures(df, entries, keycols, hints)
    gd = groupby(df, keycols; sort = false, skipmissing = false)
    combine(gd) do sdf
        # invokelatest: lifted aggregators live at a newer world age than this closure
        DataFrame([m.out => [aggrvalue(Base.invokelatest(m.func, sdf))] for m in measures]...)
    end
end

agg(df::AbstractDataFrame, key::Symbol; kwargs...) = agg(df, [key]; kwargs...)

# ------------------------------------------------------------- transforms --
# Curried forms return reusable callables, so pipelines compose:
#   df |> dim(chain) |> agg(keys)      (t2 ∘ t1)(df)

struct DimTransform
    specs::Tuple
    hints::AggrHints
    replace::Bool
end
(t::DimTransform)(df::AbstractDataFrame) =
    dim(df, t.specs...; hints = t.hints, replace = t.replace)

dim(chains::Union{Pair,AbstractVector}...; hints::AggrHints = AggrHints(),
    replace::Bool = false) = DimTransform(chains, hints, replace)

struct AggTransform
    chain::Any
    hints::AggrHints
    cols::Union{Nothing,Vector{Any}}
    allbut::Union{Nothing,Vector{Symbol}}
end
(t::AggTransform)(df::AbstractDataFrame) =
    agg(df, t.chain; hints = t.hints, cols = t.cols, allbut = t.allbut)

agg(chain::Union{AbstractVector,Symbol}; hints::AggrHints = AggrHints(),
    cols::Union{Nothing,AbstractVector} = nothing,
    allbut::Union{Nothing,Symbol,AbstractVector} = nothing) =
    AggTransform(chain, hints,
                 cols === nothing ? nothing : collect(Any, cols),
                 allbut === nothing ? nothing : tosyms(allbut))
