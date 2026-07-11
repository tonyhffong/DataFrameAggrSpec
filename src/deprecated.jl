struct CalcPivot
    spec::Expr
    by::Array{Symbol,1}
    CalcPivot(x::String, by::Array{Symbol,1} = Symbol[]) = CalcPivot(Meta.parse(x), by)
    CalcPivot(x::String, by::Symbol) = CalcPivot(Meta.parse(x), Symbol[by])
    function CalcPivot(x::Expr, by::Symbol)
        CalcPivot(x, Symbol[by])
    end
    function CalcPivot(ex::Expr, by::Array{Symbol,1} = Symbol[])
        fname = check_spec_call(ex, "CalcPivot")

        if fname == :topnames # ensure we have the name in "by"
            # expect the first argument is a QuoteNode, or Expr( :quote, symbol )
            if isa(ex.args[2], QuoteNode)
                name_col = ex.args[2].value
            elseif Base.Meta.isexpr(ex.args[2], :quote)
                name_col = ex.args[2].args[1]
            else
                throw("topnames: 1st argument expects a symbol (name column)")
            end
            if !in(name_col, by)
                new(ex, Symbol[by..., name_col])
            else
                new(ex, by)
            end
        else
            new(ex, by)
        end
    end
end

CalcPivotFuncCache = Dict{Any,Function}()
CalcPivotAggrDepCache = Dict{Any,Array{Symbol,1}}()

# DEPRECATED shim, kept for TermWin until its migration to the dimension engine.
# Legacy contract preserved exactly:
#   * non-empty `by` -> f(df, c::Symbol; kwargs...) returning a one-row-per-group
#     DataFrame carrying the `by` columns plus result column `c`; the caller
#     joins it back onto rows. `kwargs` supply the aggregation spec for every
#     dependency column (the list is published in CalcPivotAggrDepCache[(ex, by)]).
#   * empty `by` -> f(df) returning a row-aligned vector; column creation is
#     left to the caller.
# New code should use PivotDim / WindowDim + dim/dim! instead: they return
# row-aligned columns directly, take an AggrHints, and expose dependencies(d)
# rather than the side-effect cache.

function liftCalcPivotToFunc(ex::Expr, by::Array{Symbol,1})
    if haskey(CalcPivotFuncCache, (ex, by))
        return CalcPivotFuncCache[(ex, by)]
    end

    kernelf, cols = window_kernel(ex)

    if !isempty(by) # micro split-apply-combine
        aggregates = setdiff(cols, by)
        CalcPivotAggrDepCache[(ex, by)] = aggregates
        ret = function (_df_::AbstractDataFrame, c::Symbol; kwargs...)
            aggrfuncs = Dict{Symbol,Function}()
            for (aggrc, spec) in kwargs
                # this would throw if spec is not compliant, as usual
                aggrfuncs[aggrc] = liftAggrSpecToFunc(aggrc, spec)
            end
            gd = groupby(_df_, by; sort = false, skipmissing = false)
            # one row per group: `by` columns take the group value, dependency
            # columns are aggregated with the caller-supplied specs (a missing
            # kwarg throws here, as it always did)
            colvals = Dict{Symbol,Any}()
            for col in union(by, cols)
                if col in by
                    colvals[col] = [first(g[!, col]) for g in gd]
                else
                    # invokelatest: lifted aggregators live at a newer world age
                    colvals[col] =
                        [aggrvalue(Base.invokelatest(aggrfuncs[col], g)) for g in gd]
                end
            end
            vals = Base.invokelatest(kernelf, Any[colvals[col] for col in cols]...)
            out = DataFrame([k => colvals[k] for k in by]...)
            out[!, c] = vals
            out # This has all the "by" columns and the result, named by c
            # combine is done by the caller
        end
    else # much simpler, we are doing line-by-line apply.
        # Common use case: a simple bucketing, or a line by line ranking.
        CalcPivotAggrDepCache[(ex, by)] = Symbol[]
        ret = function (_df_::AbstractDataFrame)
            Base.invokelatest(kernelf, Any[_df_[!, col] for col in cols]...)
            # the creation of column is done by the caller
        end
    end
    CalcPivotFuncCache[(ex, by)] = ret
end
