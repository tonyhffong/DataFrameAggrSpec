# PARSING and structural rewriting: text -> Expr, then the structural passes
# that run before the compiler sees anything.
#
# `peel_modifiers` strips the postfix `|> orderby(...)` / `|> groupby(...)`
# metadata (interpreted structurally, never called) and `desugar_where!`
# injects where's default labels, which only the parser knows because they are
# the condition's own source text. Both rewrite the tree; neither evaluates it.

# A syntax error already knows exactly where it is: Julia's ParseError carries
# JuliaSyntax diagnostics with byte ranges. Lift the first one rather than
# re-deriving a span from a token there is none of. Defensive throughout -- this
# reaches into an internal shape, and a missing span is only a missing
# highlight.
function parse_span(err)
    try
        pe = isa(err, Base.Meta.ParseError) && hasproperty(err, :detail) ?
             err.detail : err
        hasproperty(pe, :diagnostics) || return nothing
        ds = pe.diagnostics
        isempty(ds) && return nothing
        r = Base.JuliaSyntax.byte_range(first(ds))
        isa(r, UnitRange{Int}) && !isempty(r) ? r : nothing
    catch
        nothing
    end
end


# Julia's own ParseError is a multi-line block with a caret diagram; the last
# line carries the actual diagnosis ("extra tokens after end of expression").
# Lift that out so the rejection stays one line, as a TUI needs.
function parse_detail(err)
    msg = isa(err, AbstractString) ? String(err) :
          isa(err, Base.Meta.ParseError) ? string(err.msg) :
          sprint(showerror, err)
    line = last(split(msg, '\n'))
    i = findlast("── ", line)
    i === nothing ? strip(line) : strip(line[(last(i)+1):end])
end

function safe_parse(s::AbstractString, kind::Symbol)
    ex = try
        Meta.parse(s)
    catch err
        detail = parse_detail(err)
        specerror("cannot parse \"" * s * "\"" *
                  (isempty(detail) ? "" : " -- " * detail);
                  code = :parse, span = parse_span(err))
    end
    ex === nothing && specerror(
        "empty spec -- a spec is a call over column names, e.g. " *
        (kind === :aggr ? "\"sum(_)\"" : "\"cumsum(sales)\"");
        code = :empty_spec)
    if isa(ex, Expr) && ex.head == :incomplete
        specerror("incomplete expression \"" * s *
                  "\" -- " * parse_detail(ex.args[1]); code = :parse)
    end
    if isa(ex, Expr) && ex.head == :toplevel
        specerror("one expression only (no ';') in \"" * s * "\"";
                  code = :parse)
    end
    ex
end

positional_args(ex::Expr) = [
    a for a in ex.args[2:end] if
    !(Base.Meta.isexpr(a, :kw) || Base.Meta.isexpr(a, :parameters))
]

simple_posarg(a) =
    isa(a, Symbol) ? a :
    Base.Meta.isexpr(a, :vect) && all(x -> isa(x, Symbol), a.args) ?
    Symbol[a.args...] : nothing

ismodifiercall(x) = Base.Meta.isexpr(x, :call) && in(x.args[1], SafeModifiers)
ismodifiershape(ex) =
    Base.Meta.isexpr(ex, :call, 3) && (ex.args[1] == :∘ || ex.args[1] == :|>)

# peel postfix modifiers off a dim spec: `spec ∘ modifier(...)` (or `|>`, the
# ASCII twin). Intent first, modifier after; modifiers are engine METADATA --
# interpreted structurally, never called. Returns (inner, order, by).
function peel_modifiers(ex)
    order = Pair{Symbol,Bool}[]
    by = Union{Symbol,GroupByKey}[]
    while ismodifiershape(ex)
        combinator, lhs, rhs = ex.args[1], ex.args[2], ex.args[3]
        if ismodifiercall(lhs)
            specerror("the modifier must follow the spec -- write " *
                      "\"spec " * string(combinator) * " " *
                      string(lhs.args[1]) * "(...)\"";
                      code = :modifier_misuse, token = lhs.args[1])
        end
        if !ismodifiercall(rhs)
            if isa(rhs, Symbol) && in(rhs, SafeModifiers)   # forgot the parens
                specerror("" * string(rhs) * " takes columns -- write " *
                          "\"spec " * string(combinator) * " " * string(rhs) *
                          "(col, ...)\""; code = :modifier_misuse, token = rhs)
            end
            tok = Base.Meta.isexpr(rhs, :call) && isa(rhs.args[1], Symbol) ?
                  rhs.args[1] : isa(rhs, Symbol) ? rhs : nothing
            # SQL's PARTITION BY vocabulary must not fall through to the
            # generic message below, which reads as "use groupby" -- the one
            # correction that runs and silently computes something else
            tok !== nothing && in(squash(tok), ForeignPartitionWords) &&
                specerror(partition_reminder(tok);
                          code = :foreign_spelling, token = tok)
            r = tok === nothing ? (hint = "", fix = nothing) :
                repair(tok, SafeModifiers)
            specerror("expected a modifier call (" *
                      join(string.(SafeModifiers), ", ") * ") after '" *
                      string(combinator) * "', got " * string(rhs) * r.hint;
                      code = :modifier_misuse, token = tok, fix = r.fix)
        end
        modname = rhs.args[1]
        args = rhs.args[2:end]
        if modname == :orderby
            isempty(order) || error("duplicate orderby modifier")
            isempty(args) && error("orderby needs at least one column")
            for a in args
                push!(order, orderentry_parsed(a))   # :col | col => :asc/:desc
            end
        else # :groupby -- bare columns/computed expressions (varargs), or one
             # [col, ...] array of PLAIN columns (unchanged; the array
             # spelling stays symbol-only -- mixing an expression into it
             # errors with a redirect rather than silently doing something
             # surprising)
            isempty(by) || error("duplicate groupby modifier")
            for a in args
                s = simple_posarg(a)
                if isa(s, Symbol)
                    push!(by, s)
                elseif isa(s, Vector{Symbol})
                    append!(by, s)
                elseif isa(a, Union{Number,AbstractString,Char,QuoteNode})
                    groupby_literal_error(a)
                elseif Base.Meta.isexpr(a, :vect)
                    error("groupby's [ ... ] array form only " *
                          "accepts plain column names -- write computed " *
                          "keys as separate arguments, e.g. groupby(col1, " *
                          "yyyymm(date))")
                else
                    # a computed key, e.g. groupby(yyyymm(date)) -- compiled
                    # exactly like a nested composite-aggregation groupby
                    # key (compile_grouped), materialized as a real column
                    # before DataFrames.groupby at evaluation time
                    kcols = Symbol[]
                    kf = compile_node(a, kcols)
                    push!(by, GroupByKey(gensym(:bykey), kf, kcols))
                end
            end
            isempty(by) && error("groupby needs at least one column")
        end
        ex = lhs
    end
    (ex, order, by)
end


# where's default labels are the condition's SOURCE TEXT, which only the
# compiler knows (the verb just sees a Bool vector) -- inject
# `true_label = "<condition>"` into any where(...) call that does not spell
# its own (false_label then derives from true_label inside the verb, see
# verbs.jl). Every where call passes through here, so the arity check lives
# here too. Trusted-Expr specs get no such injection: their authors pass
# true_label explicitly.
function desugar_where!(ex)
    isa(ex, Expr) || return ex
    if ex.head == :call && ex.args[1] == :where
        pos = positional_args(ex)
        length(pos) == 1 || error(
            "where takes exactly one Boolean condition, plus " *
            "optional labels -- where(cond) or " *
            "where(cond, true_label = \"...\", false_label = \"...\")",
        )
        haslabel = any(ex.args[2:end]) do a
            Base.Meta.isexpr(a, :kw) && a.args[1] == :true_label ||
                Base.Meta.isexpr(a, :parameters) && any(
                    p -> Base.Meta.isexpr(p, :kw) && p.args[1] == :true_label,
                    a.args,
                )
        end
        haslabel || push!(ex.args, Expr(:kw, :true_label, string(pos[1])))
    end
    for a in ex.args
        desugar_where!(a)
    end
    ex
end

# top-level && / || make a legal spec shape too: `a > 1` is already a valid
# Bool-column spec, so its compound form must be as well. :comparison passes
# the shape gate only to reach compile_node's tailored rejection ("combine
# single comparisons with &&") instead of a generic shape error.
iscondshape(ex) =
    isa(ex, Expr) && (ex.head == :(&&) || ex.head == :(||) || ex.head == :comparison)
