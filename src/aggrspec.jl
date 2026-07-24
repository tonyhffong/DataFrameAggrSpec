#=
@doc """
Facilities to help map GUI input / expression into a function that aggregates columns.
We would store that function and use it whenever we need to aggregate a column.

Three ways to instantiate the DataFrameAggr
* Symbol. e.g. `:mean`. It's lowered into `mean(:_)`. See below for the meaning of `:_`
* Expr. e.g. `:( mean(:_,:wcol) )`, `:( quantile( :_, 0.75 ) )`
   symbols (quoted) are interpreted as the named column.
   The underscore `:_` column is special -- it's interpreted on-the-fly as the column that
   needs to be aggregated. So multiple columns can use the same expression `mean(_,:wcol)` and
   they will all use the same weight (from `wcol`), but produces target specific mean.
* Function: (most likely lambda) e.g. `df -> quantile( df[!,:col], 0.5 )`. It is expected
   to generate either a value (typically a scalar consistent to the column type), or
   a 1-row, 1-col dataframe.
""" ->
=#

DataFrameAggrCache = Dict{Any,Function}()

defaultAggr(::Type) = :uniqvalue
defaultAggr(::Type{T}) where {T<:Real} = :sum
defaultAggr(::Type{Array{T,1}}) where {T} = :unionall

# AggrHints: how to aggregate each column, resolved col Symbol > eltype Type > default.
# Type entries match by subtyping (AbstractString => :uniqvalue covers String columns),
# scanned in insertion order so more specific types should be listed first.
struct AggrHints
    bycol::Dict{Symbol,Any}
    bytype::Vector{Pair{Type,Any}}
    default::Function   # Type -> spec
end

function AggrHints(pairs::Pair...; default::Function = defaultAggr)
    bycol = Dict{Symbol,Any}()
    bytype = Pair{Type,Any}[]
    for (k, v) in pairs
        if isa(v, AbstractString)
            v = parseaggr(v)   # Strings are UNTRUSTED: safe whitelist grammar
        end
        if isa(k, Symbol)
            bycol[k] = v
        elseif isa(k, Type)
            push!(bytype, k => v)
        else
            error("AggrHints: keys must be column Symbols or element Types, got " * string(k))
        end
    end
    AggrHints(bycol, bytype, default)
end

AggrHints(d::AbstractDict; default::Function = defaultAggr) =
    AggrHints((k => v for (k, v) in d)...; default = default)

function resolveaggr(h::AggrHints, col::Symbol, T::Type)
    haskey(h.bycol, col) && return h.bycol[col]
    # strip Missing before matching bytype/default -- a column that has ever
    # held a missing has eltype Union{Missing,S}, which is never <: Real /
    # <: AbstractString / etc, so without this every nullable column would
    # silently miss its bytype hint (and the Real => :sum default) and fall
    # to the generic :uniqvalue catch-all. Guarded to T === Missing exactly
    # (an all-missing column): nonmissingtype(Missing) is Union{}, which is
    # <: everything, so normalizing it would make an all-missing column
    # spuriously match the FIRST registered bytype entry regardless of
    # relevance -- leave that case to fall through to default(Missing) as before.
    T2 = T === Missing ? T : Base.nonmissingtype(T)
    for (K, v) in h.bytype
        T2 <: K && return v
    end
    h.default(T2)
end

# Normalize the lifted-aggregator return contract (scalar or 1x1 DataFrame) to a value.
aggrvalue(ret) = isa(ret, AbstractDataFrame) ? ret[1, 1] : ret

# Strings are UNTRUSTED: routed through the safe whitelist grammar (safe.jl).
# Trusted specs are Exprs, Symbols, or Functions -- forms that cannot arrive
# from a user's text field by accident. (parseaggr is defined later in the
# module; this body only runs at call time, so include order is fine.)
liftAggrSpecToFunc(c::Symbol, dfa::AbstractString) = liftAggrSpecToFunc(c, parseaggr(dfa))

function liftAggrSpecToFunc(c::Symbol, dfa::Union{Function,Symbol,Expr})
    if isa(dfa, Function)
        return dfa
    end
    if haskey(DataFrameAggrCache, (c, dfa))
        return DataFrameAggrCache[(c, dfa)]
    end
    # "mean" or "Module.aggrfunc"
    if isa(dfa, Symbol) ||
       isa(dfa, Expr) && dfa.head == :(.) && all(x->isa(x, Symbol), dfa.args)
        funnameouter = gensym("DFAggr")
        code = :(function $funnameouter(_df_::AbstractDataFrame) end)
        push!(code.args[2].args, Expr(:call, dfa, Expr(:ref, :_df_, :!, QuoteNode(c))))
        ret = eval(code)
    else # expr
        check_spec_call(dfa, "DataFrameAggr")

        # replace _ with _df_[!,$c], and then leverage replace_col_syms

        # before we do that, note that
        # (A) in DataFramesMeta, macro converts :x to Expr( :quote, :x ) but
        #     :( :x ) or parse( ":x" ) it is actually QuoteNode( :x ),
        #     so we need to do a little conversion in order to leverage that package
        cdfa = deepcopy(dfa)
        convertExpression!(cdfa, c)

        membernames = Dict{Symbol,Symbol}()
        cdfa = replace_col_syms(cdfa, membernames)
        funargs = map(x -> Expr(:ref, :_df_, :!, QuoteNode(x)), collect(keys(membernames)))
        funnameouter = gensym("DFAggr")
        funname = gensym()
        code = quote
            function $funnameouter(_df_::AbstractDataFrame)
                function $funname($(collect(values(membernames))...))
                    $cdfa
                end
                $funname($(funargs...))
            end
        end
        # Eval in Main so that module-qualified names in the user-supplied
        # expression (e.g. `StatsBase.mean(:_, :wcol)`) resolve against the
        # user's loaded packages rather than against TermWin's own imports.
        ret = Core.eval(Main, code)
    end
    DataFrameAggrCache[(c, dfa)] = ret
end
