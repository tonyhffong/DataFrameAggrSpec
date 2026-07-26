# STATIC CHECKS: everything decided at parse time, before a single row is
# touched, from the registry alone.
#
# Two families, one principle. Signature checks (arity, keyword names) read the
# registered function's own method table; shape checks read the declared
# operator shape and propagate it through the expression. Both exist to move a
# failure that would otherwise surface as a raw MethodError from inside a
# group-by -- naming neither the spec nor the mistake -- forward to the point
# where the user is still looking at the text they typed.
#
# The principle both obey is G13 (design/user-guidance.md): a check that lacks
# its input stays SILENT rather than guessing. check_arity fires only when no
# method could accept the count, check_kwargs bails out entirely on a
# `kwargs...` method, and :unknown is absorbing in shape inference. A check
# that is confidently wrong is worse than one that is absent, because the user
# cannot appeal it.

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

function check_arity(fname::Symbol, op, n::Int)
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
    specerror("'" * string(fname) * "' takes " * expected *
              (lo == 1 && hi == 1 ? " positional argument, got " :
               " positional arguments, got ") * string(n) * hint *
              ". (Options go in keyword form: f(x, opt = value).)";
              code = :arity, token = fname)
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

function check_kwargs(fname::Symbol, op, kws::Vector{Symbol})
    isempty(kws) && return nothing
    accepted = op_kwargs(op)
    accepted === nothing && return nothing
    for k in kws
        in(k, accepted) && continue
        isempty(accepted) && specerror(
            "'" * string(fname) * "' takes no keyword options, got '" *
            string(k) * "'"; code = :unknown_kwarg, token = k)
        r = repair(k, accepted)
        specerror("'" * string(fname) * "' has no keyword option '" *
                  string(k) * "'" * r.hint * ". Accepted: " *
                  join(accepted, ", ");
                  code = :unknown_kwarg, token = k, fix = r.fix)
    end
    nothing
end


# ---- shape inference --------------------------------------------------------
# What a whole spec EXPRESSION returns, relative to the rows it is handed:
#
#   :scalar      one value       sum(_), mean(x) / std(x), a literal
#   :rowwise     one per row     cumsum(x), x > 1, sales / sum(sales)
#   :collection  many, unaligned skipmissing(x), [a, b], a nested grouped
#                                reduction (one element per KEY, not per row)
#   :unknown     give up         anything touching an undeclared operator
#
# Composition is the point: the top-level NAME is not enough. `sum(_ * wt) /
# sum(wt)` is a division -- elementwise -- yet reduces, because both operands
# do. `sales / sum(sales)` is the same division and does not. Only propagating
# through the tree tells them apart, which is why this is an inference rather
# than a lookup.
#
# :unknown is absorbing on purpose. One undeclared host verb anywhere in the
# expression turns the whole answer into "no opinion", and every check below
# then stays silent -- the same bail-out check_kwargs makes when it meets a
# `kwargs...` method.
function shape_of(ex)
    isa(ex, Symbol) && return ex === :_ ? :rowwise : :rowwise   # column or target
    isa(ex, QuoteNode) && return :scalar
    isa(ex, Union{Number,AbstractString,Char,Bool}) && return :scalar
    isa(ex, Expr) || return :unknown
    ex.head === :vect && return :collection
    (ex.head === :(&&) || ex.head === :(||) || ex.head === :comparison) &&
        return combine_shapes(map(shape_of, ex.args))
    # a nested `inner |> groupby(keys)` yields one element per KEY
    ismodifiershape(ex) && return :collection
    ex.head === :call || return :unknown
    fname = ex.args[1]
    isa(fname, Symbol) || return :unknown
    s = opshape(fname)
    s === :reduce && return :scalar
    s === :map && return :rowwise
    s === :filter && return :collection
    s === :unknown && return :unknown
    combine_shapes([shape_of(a) for a in positional_args(ex)])   # :elementwise
end

# an elementwise call is as "wide" as its widest argument, and one :unknown
# poisons the result
combine_shapes(ss) =
    isempty(ss) ? :scalar :
    any(==(:unknown), ss) ? :unknown :
    any(==(:collection), ss) ? :collection :
    any(==(:rowwise), ss) ? :rowwise : :scalar

# Which call actually collapsed the rows? The TOP-LEVEL name is usually the
# wrong one to blame: in `where(any(flag))` the top is `where` (elementwise,
# innocent) and the culprit is `any` one level down. Descend through
# elementwise calls to name the reduction the user has to reconsider, since
# that is the token they must edit.
function reducing_culprit(ex)
    isa(ex, Expr) || return nothing
    if ex.head === :call && isa(ex.args[1], Symbol)
        opshape(ex.args[1]) === :reduce && return ex.args[1]
        opshape(ex.args[1]) === :elementwise || return nothing
    elseif !(ex.head === :(&&) || ex.head === :(||) || ex.head === :comparison)
        return nothing
    end
    args = ex.head === :call ? positional_args(ex) : ex.args
    for a in args
        c = reducing_culprit(a)
        c === nothing || return c
    end
    nothing
end

# The mirror of reducing_culprit, for the aggregation side: what stopped this
# spec collapsing to one value? A bare column read row by row, or a :map/:filter
# verb that preserves them. Descend only through branches that are NOT already
# scalar -- `sum(a) + qtty` should blame `qtty`, not `sum`.
function unreduced_culprit(ex)
    isa(ex, Symbol) && return ex
    isa(ex, Expr) || return nothing
    local args
    if ex.head === :call && isa(ex.args[1], Symbol)
        s = opshape(ex.args[1])
        (s === :map || s === :filter) && return ex.args[1]
        s === :elementwise || return nothing        # :reduce/:unknown stop here
        args = positional_args(ex)
    elseif ex.head === :(&&) || ex.head === :(||) || ex.head === :comparison
        args = ex.args
    else
        return nothing
    end
    for a in args
        shape_of(a) === :scalar && continue         # this branch already reduced
        c = unreduced_culprit(a)
        c === nothing || return c
    end
    nothing
end

# A :map verb handed nothing but scalars has nothing to map over. This is how
# `where(any(flag)) |> groupby(region)` used to reach the engine and die with a
# raw `TypeError: non-boolean (Int64) used in boolean context` -- and it is
# decidable here because every :map verb rejects a scalar argument outright.
# Silent unless EVERY positional argument is definitively scalar.
function check_mapshape(fname::Symbol, ex::Expr)
    opshape(fname) === :map || return nothing
    args = positional_args(ex)
    isempty(args) && return nothing
    all(a -> shape_of(a) === :scalar, args) || return nothing
    specerror("'" * string(fname) * "' works down a column, but every " *
              "argument here is a single value -- name the column it should " *
              "run over, e.g. '" * string(fname) * "(sales)'";
              code = :shape, token = fname)
end
