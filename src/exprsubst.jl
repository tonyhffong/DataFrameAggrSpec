# replace_col_syms: walk an expression and replace :col (QuoteNode or Expr(:quote,:col))
# with a gensym variable; populate membernames with col->gensym mapping
function replace_col_syms(ex, membernames::Dict)
    if isa(ex, QuoteNode) && isa(ex.value, Symbol)
        sym = ex.value
        if !haskey(membernames, sym)
            membernames[sym] = gensym(string(sym))
        end
        return membernames[sym]
    elseif isa(ex, Expr) &&
           ex.head == :quote &&
           length(ex.args) == 1 &&
           isa(ex.args[1], Symbol)
        sym = ex.args[1]
        if !haskey(membernames, sym)
            membernames[sym] = gensym(string(sym))
        end
        return membernames[sym]
    elseif isa(ex, Expr) && ex.head == :(.)
        # Member access like `StatsBase.mean` parses as
        # Expr(:(.), :StatsBase, QuoteNode(:mean)). The QuoteNode here is a
        # field name, NOT a column reference, so leave the whole expression
        # alone. Same treatment for deeper chains like `A.B.C`.
        return ex
    elseif isa(ex, Expr) && ex.head == :call && length(ex.args) == 2 && ex.args[1] == :^
        # DataFramesMeta-style escape: `^(:sym)` means "keep :sym a Symbol,
        # not a column reference" -- e.g. `discretize(:x, [0,1]; boundedness = ^(:boundedbelow))`
        return ex.args[2]
    elseif isa(ex, Expr)
        return Expr(ex.head, [replace_col_syms(a, membernames) for a in ex.args]...)
    else
        return ex
    end
end

# used by aggregation lifting and calcpivot lifting
function convertExpression!(ex::Expr, column_ctx::Symbol = Symbol(""))
    # Do not descend into member-access expressions like `StatsBase.mean`
    # (Expr(:(.), :StatsBase, QuoteNode(:mean))). Their QuoteNode argument
    # is a field name, not a column reference, and rewriting it would
    # confuse `replace_col_syms` into treating `:mean` as a column.
    if ex.head == :(.)
        return
    end
    for i = 1:length(ex.args)
        a = ex.args[i]
        if isa(a, QuoteNode)
            if a.value == :_ && column_ctx != Symbol("")
                ex.args[i] = Expr(:quote, column_ctx)
            else
                ex.args[i] = Expr(:quote, a.value)
            end
        elseif isa(a, Expr)
            # propagate the target-column context so a nested `:_`
            # (e.g. `sum(:_ .* :wt)`) is substituted too
            convertExpression!(a, column_ctx)
        end
    end
end

# check_spec_call: shared guards for a runtime spec expression. Must be a plain
# function call with a simple (or module-dotted) non-mutating name. These guards
# keep trusted-author specs honest -- they are NOT a sandbox (see module header).
# Returns the function name.
function check_spec_call(ex::Expr, what::AbstractString)
    if !Base.Meta.isexpr(ex, :call)
        error(string(ex) * " does not look like an aggregator function")
    end
    fname = ex.args[1]
    if Base.Meta.isexpr(fname, :curly)
        error(what * ": curly not supported")
    elseif !isa(fname, Symbol) && !Base.Meta.isexpr(fname, :(.))
        error(what * ": only simple function name please")
    end
    if occursin("!", string(fname))
        error(string(fname) * " seems to have side effects")
    end
    fname
end

# referenced_columns: the column Symbols a spec expression refers to
# (:_ excluded unless a target context was substituted beforehand)
function referenced_columns(ex::Expr)
    cex = deepcopy(ex)
    convertExpression!(cex)
    membernames = Dict{Symbol,Symbol}()
    replace_col_syms(cex, membernames)
    collect(keys(membernames))
end
