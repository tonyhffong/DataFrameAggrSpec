# Chains: ordered pivot lists in which new dimensions are declared inline and
# partitioned by their LEFT CONTEXT -- every chain entry before them.
#
#   [:County,                                          # existing column
#    :top5d => :( topnames(:District, :TestScr, 5) ),  # new dim, context [:County]
#    :District,
#    :scoreq => :( discretize(:TestScr, quantiles=[.25,.5,.75]) )]
#                                    # new dim, context [:County, :top5d, :District]
#
# Entry forms:
#   Symbol / String                       -- existing column (pivot key)
#   name => spec  or  [name, spec]        -- declare a dimension (String-friendly)
#   (name => spec, name => spec, ...)     -- parallel siblings: same left context,
#                                            not in each other's context
#   an AbstractDimension                  -- used as-is; its name joins the context
#   spec: Expr / String / Function, or dimspec(...) to attach order / extra
#   grouping keys ("addgroupby") / an explicit kind.

# name-less dimension spec, named when it lands in a chain
struct DimSpec
    spec::Any                        # Expr or Function
    by::Vector{Symbol}               # extra grouping keys beyond the left context
    order::Vector{Pair{Symbol,Bool}}
    kind::Symbol                     # :auto | :window | :pivot
end

function dimspec(
    spec::Union{Expr,AbstractString,Function};
    by = Symbol[],
    order = Pair{Symbol,Bool}[],
    kind::Symbol = :auto,
)
    if isa(spec, AbstractString)
        spec = Meta.parse(spec)
    end
    if isa(spec, Expr)
        check_spec_call(spec, "dimspec")
    end
    in(kind, (:auto, :window, :pivot)) ||
        error("dimspec: kind must be :auto, :window or :pivot, got " * string(kind))
    DimSpec(spec, tosyms(by), normalize_order(order), kind)
end

# :auto kind: window, except a top-level `topnames` call (group classification)
autokind(spec) =
    isa(spec, Expr) && check_spec_call(spec, "dimension spec") == :topnames ? :pivot :
    :window

# build a concrete dimension for a chain declaration under a left context
function chain_dim(name::Symbol, payload, context::Vector{Symbol})
    if isa(payload, DimSpec)
        kind = payload.kind == :auto ? autokind(payload.spec) : payload.kind
        if kind == :pivot
            PivotDim(name, payload.spec; by = payload.by, context = context)
        else
            WindowDim(
                name,
                payload.spec;
                by = vcat(context, payload.by),
                order = payload.order,
            )
        end
    elseif isa(payload, Function)
        WindowDim(name, payload; by = context)
    elseif isa(payload, Expr) || isa(payload, AbstractString)
        ex = isa(payload, AbstractString) ? Meta.parse(payload) : payload
        if autokind(ex) == :pivot
            PivotDim(name, ex; context = context)  # topnames fixup supplies `by`
        else
            WindowDim(name, ex; by = context)
        end
    else
        error("chain: cannot interpret dimension spec " * string(payload))
    end
end

# normalize_chain: resolve a chain into pivot keys (in order) and the concrete
# dimensions to materialize (in application order)
function normalize_chain(chain::Union{AbstractVector,Tuple})
    keycols = Symbol[]
    dims = AbstractDimension[]
    for entry in chain
        chainentry!(keycols, dims, entry)
    end
    (keycols, dims)
end

isdeclaration(e) =
    isa(e, Pair) || (isa(e, AbstractVector) && length(e) == 2 &&
                     (isa(e[1], Symbol) || isa(e[1], AbstractString)))

declaration(e::Pair) = (Symbol(e.first), e.second)
declaration(e::AbstractVector) = (Symbol(e[1]), e[2])

function chainentry!(keycols::Vector{Symbol}, dims::Vector{AbstractDimension}, entry)
    if isa(entry, Symbol)
        push!(keycols, entry)
    elseif isa(entry, AbstractString)
        push!(keycols, Symbol(entry))
    elseif isa(entry, AbstractDimension)
        push!(dims, entry)
        push!(keycols, entry.name)
    elseif isa(entry, Tuple)   # parallel siblings under the same left context
        ctx = copy(keycols)
        names = Symbol[]
        for e in entry
            isdeclaration(e) ||
                error("chain: sibling entries must be name => spec pairs, got " * string(e))
            (n, payload) = declaration(e)
            push!(dims, chain_dim(n, payload, ctx))
            push!(names, n)
        end
        append!(keycols, names)
    elseif isdeclaration(entry)
        (n, payload) = declaration(entry)
        push!(dims, chain_dim(n, payload, copy(keycols)))
        push!(keycols, n)
    else
        error("chain: cannot interpret entry " * string(entry))
    end
end
