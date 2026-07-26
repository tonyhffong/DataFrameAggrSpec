# The AST -> closure COMPILER: the default-deny interpreter that turns a
# validated expression into a callable, with no eval anywhere on the path.
#
# Only the node kinds handled below exist in the untrusted language; anything
# else is rejected. The result is an ordinary closure at the current world
# age, so callers need no Base.invokelatest -- the property that makes the
# untrusted path cheap enough to run on a keystroke.

function colindex!(cols::Vector{Symbol}, c::Symbol)
    i = findfirst(==(c), cols)
    i === nothing ? (push!(cols, c); length(cols)) : i
end


# compile a node to a thunk `vals::Tuple -> value`, where vals are the column
# vectors in `cols` (first-encounter) order. Default-deny: only the node kinds
# below exist in the untrusted language.
function compile_node(ex, cols::Vector{Symbol})
    if isa(ex, Symbol)                       # bare identifier = column (incl. _)
        i = colindex!(cols, ex)
        return vals -> vals[i]
    elseif isa(ex, QuoteNode)                # :sym literal
        isa(ex.value, Symbol) ||
            error("unsupported quoted literal " * repr(ex.value))
        v = ex.value
        return vals -> v
    elseif isa(ex, Union{Number,AbstractString,Char})
        return vals -> ex
    elseif isa(ex, Expr) && ex.head == :vect
        ts = Function[compile_node(a, cols) for a in ex.args]
        return vals -> Base.vect((t(vals) for t in ts)...)
    elseif isa(ex, Expr) && (ex.head == :(&&) || ex.head == :(||))
        # && / || are control flow in Julia (their own heads, not :call), so
        # they cannot live in the registry -- translated structurally to PURE
        # elementwise and/or: both sides always evaluated, missing propagates
        # (Kleene). The payoff is precedence: they bind looser than
        # comparisons, so `a > 1 && b < 2` needs no parentheses.
        op = ex.head == :(&&) ? (&) : (|)
        lt = compile_node(ex.args[1], cols)
        rt = compile_node(ex.args[2], cols)
        return vals -> Base.broadcast(op, lt(vals), rt(vals))
    elseif isa(ex, Expr) && ismodifiershape(ex)
        # `a |> b` / `a ∘ b` reaching the compiler is NESTED (top-level
        # modifiers are peeled by peel_modifiers / gated by parseaggr first)
        return compile_grouped(ex, cols)
    elseif isa(ex, Expr) && ex.head == :call
        return compile_call(ex, cols)
    elseif isa(ex, Expr) && haskey(SafeRejections, ex.head)
        specerror("" * SafeRejections[ex.head] * " (in \"" * string(ex) * "\")";
                  code = :unsupported_syntax, token = ex.head)
    else
        specerror("unsupported syntax '" *
                  (isa(ex, Expr) ? string(ex.head) : string(typeof(ex))) *
                  "' in \"" * string(ex) * "\"";
                  code = :unsupported_syntax)
    end
end

function compile_call(ex::Expr, cols::Vector{Symbol})
    fname = ex.args[1]
    if !isa(fname, Symbol)
        if Base.Meta.isexpr(fname, :(.))
            # `spec.orderby(...)` -- the dotted modifier separator, which this
            # grammar deliberately does not have (design/glyph-choice.md).
            # Without this branch it reads as an ordinary qualified name and
            # the user is told about registerop!, which is not their problem.
            m = length(fname.args) == 2 && isa(fname.args[2], QuoteNode) ?
                fname.args[2].value : nothing
            isa(m, Symbol) && in(m, SafeModifiers) && specerror(
                "" * modifier_reminder(m) *
                ". The separator is '|>' or '∘', never '.'";
                code = :modifier_misuse, token = m)
            specerror("qualified names like '" * string(fname) *
                      "' are not allowed in untrusted specs; hosts can register the " *
                      "function under a plain name with registerop!";
                      code = :unsupported_syntax)
        end
        specerror("unsupported function name " * string(fname);
                  code = :unsupported_syntax)
    end
    op = get(SafeOps, fname, nothing)
    if op === nothing && startswith(string(fname), ".")
        op = get(SafeOps, Symbol(string(fname)[2:end]), nothing)
    end
    op === nothing && unknown_op_error(fname)
    pts = Function[]                     # positional thunks, in order
    kts = Pair{Symbol,Function}[]        # keyword thunks
    for a in ex.args[2:end]
        if Base.Meta.isexpr(a, :parameters)      # f(x; k = v) form
            for p in a.args
                Base.Meta.isexpr(p, :kw) && isa(p.args[1], Symbol) ||
                    error("'" * string(p) * "' is not a keyword " *
                          "option -- write options as 'name = value' " *
                          "(after ';' or ',')")
                push!(kts, p.args[1] => compile_node(p.args[2], cols))
            end
        elseif Base.Meta.isexpr(a, :kw)          # f(x, k = v) form
            isa(a.args[1], Symbol) ||
                error("'" * string(a) * "' is not a keyword option -- " *
                      "an option name must be a plain word, as in " *
                      "'rank(x, rev = true)'")
            push!(kts, a.args[1] => compile_node(a.args[2], cols))
        elseif isa(a, QuoteNode) && isa(a.value, Symbol)
            # The colon flip: in a trusted Expr `:col` IS the column, here a
            # bare word is. A positional :sym is therefore always the DataFrames
            # habit leaking through -- it would compile to a Symbol constant and
            # die at apply time with a MethodError naming neither the spec nor
            # the colon. (Symbols stay legal as option VALUES and inside a
            # literal array, both handled elsewhere.)
            # dropping the colon is a genuine drop-in fix
            specerror("':" * string(a.value) * "' is a Symbol literal, " *
                      "which is only an option VALUE here (boundedness = " *
                      ":boundedbelow). A column is a bare word -- write '" *
                      string(a.value) * "', without the colon.";
                      code = :symbol_literal, token = a.value, fix = a.value)
        else
            push!(pts, compile_node(a, cols))
        end
    end
    check_arity(fname, op, length(pts))
    check_kwargs(fname, op, Symbol[k for (k, _) in kts])
    if isempty(kts)
        return vals -> op((t(vals) for t in pts)...)
    else
        return vals -> op(
            (t(vals) for t in pts)...;
            Pair{Symbol,Any}[k => t(vals) for (k, t) in kts]...,
        )
    end
end

# nested grouped reduction: `inner |> groupby(keys...)` (∘ works too) INSIDE a
# spec -- evaluate `inner` once per distinct key combination of the current
# rows and collect the results into a vector, one element per subgroup,
# SORTED BY KEY (first/last read as earliest/latest key). Composite
# aggregation: aggr"mean(sum(_) |> groupby(year))" sums within each year,
# then means across the years; stages nest recursively. This is COMPUTATIONAL
# grouping, distinct from the top-level dim-spec modifier (engine metadata,
# peeled by peel_modifiers before the compiler ever runs). Keys may be
# computed columns (groupby(yyyy(t))); a missing key forms its own subgroup
# (Dict isequal semantics). orderby cannot attach here -- subgroup order is
# the key sort.
function compile_grouped(ex::Expr, cols::Vector{Symbol})
    combinator, lhs, rhs = ex.args[1], ex.args[2], ex.args[3]
    if ismodifiershape(lhs)
        error("one modifier only in a nested grouped reduction -- " *
              "multi-key grouping is groupby(k1, k2, ...)")
    end
    if ismodifiercall(lhs)
        error("the modifier must follow the spec -- write " *
              "\"mean(sum(_) " * string(combinator) * " groupby(year))\"")
    end
    if !ismodifiercall(rhs)
        if isa(rhs, Symbol) && in(rhs, SafeModifiers)   # forgot the parens
            specerror("" * string(rhs) * " takes columns -- write " *
                      "\"spec " * string(combinator) * " " * string(rhs) *
                      "(col, ...)\""; code = :modifier_misuse, token = rhs)
        end
        tok = Base.Meta.isexpr(rhs, :call) && isa(rhs.args[1], Symbol) ?
              rhs.args[1] : isa(rhs, Symbol) ? rhs : nothing
        r = tok === nothing ? (hint = "", fix = nothing) : repair(tok, SafeModifiers)
        specerror("'" * string(combinator) * "' attaches a groupby " *
                  "modifier to a nested spec (\"mean(sum(_) " *
                  string(combinator) * " groupby(year))\"), got " *
                  string(rhs) * r.hint;
                  code = :modifier_misuse, token = tok, fix = r.fix)
    end
    if rhs.args[1] == :orderby
        specerror("orderby cannot attach to a nested grouped " *
                  "reduction -- subgroups are ordered by their groupby keys";
                  code = :modifier_misuse, token = :orderby)
    end
    it = compile_node(lhs, cols)   # inner first: cols in source order
    keyargs = Any[]
    for a in rhs.args[2:end]
        if Base.Meta.isexpr(a, :kw) || Base.Meta.isexpr(a, :parameters)
            error("groupby takes key columns, not keyword arguments")
        elseif Base.Meta.isexpr(a, :vect)
            append!(keyargs, a.args)     # groupby([a, b]) = groupby(a, b)
        else
            push!(keyargs, a)
        end
    end
    isempty(keyargs) && error("groupby needs at least one key column")
    for a in keyargs
        isa(a, Union{Number,AbstractString,Char,QuoteNode}) &&
            groupby_literal_error(a)
    end
    kts = Function[compile_node(a, cols) for a in keyargs]
    nk = length(kts)
    # The three diagnostics below are the ONLY ones in the untrusted DSL raised
    # at APPLY time rather than parse time -- they live in the returned closure,
    # where `with_spec_context` is long gone and can neither prefix nor tag
    # them. So they name the CONSTRUCT instead of an entry point. That is also
    # more honest than what they used to say: they carried a threaded
    # "parsedim: " prefix, which was a lie by the time they fired, parsing
    # having succeeded some time earlier.
    return function (vals)
        kvs = [kt(vals) for kt in kts]
        for kv in kvs
            isa(kv, AbstractVector) || specerror(
                "grouped reduction (|> groupby): a key must evaluate to a " *
                "column, got a single value"; code = :groupby_key)
        end
        n = length(kvs[1])
        all(length(kv) == n for kv in kvs) || specerror(
            "grouped reduction (|> groupby): key columns differ in length";
            code = :groupby_key)
        groups = Dict{Any,Vector{Int}}()
        for i = 1:n
            push!(get!(Vector{Int}, groups, ntuple(j -> kvs[j][i], nk)), i)
        end
        ks = try
            sort!(collect(keys(groups)))
        catch
            specerror("grouped reduction (|> groupby): keys must be mutually " *
                      "comparable to sort the subgroups -- got mixed key types";
                      code = :groupby_key)
        end
        [it(map(v -> view(v, groups[k]), vals)) for k in ks]
    end
end
