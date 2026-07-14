function unionall(x::AbstractVector)
    t = eltype(eltype(x))
    s = Set{t}()
    for el in skipmissing(x)
        push!(s, el...)
    end
    collect(s)
end

function uniqvalue(x::AbstractVector; skipna::Bool = true, skipempty::Bool = false)
    work = skipna ? collect(skipmissing(x)) : collect(x)
    if skipempty && eltype(work) <: AbstractString
        filter!(!isempty, work)
    end
    lvls = unique(work)
    length(lvls) == 1 ? lvls[1] : missing
end

function cut_categories(
    ::Type{S},
    breaks::Vector{T};
    boundedness = :unbounded,
    leftequal = true, # t1 <= x < t2 or t1 < x <= t2?
    absolute = false, # t1 <= |x| < t2?
    rank = true, # add a rank to the string output for easier sorting?
    ranksep = ". ", # "1. t1 <= x < t2"?
    label = "", # if not compact, what label do we use for x?
    compact = (label==""), # <t1, [t1,t2), t2+. Further shortened for integer intervals with length=1
    reverse = false, # reverse the rank from the largest first?
    # the following format the boundary numbers
    # see Formatting.jl
    prefix = "",
    suffix = "",
    scale = 1,
    precision = -1,
    commas = false,
    stripzeros = (precision==-1),
    parens = false,
    mixedfraction = false,
    autoscale = :none,
    conversion = "",
) where {S<:Real,T<:Real}
    n = length(breaks)
    breakstrs = String[]
    function formatter(x)
        prefix *
        format(
            x*scale,
            precision = precision,
            commas = commas,
            stripzeros = stripzeros,
            parens = parens,
            mixedfraction = mixedfraction,
            autoscale = autoscale,
            conversion = conversion,
        ) *
        suffix
    end
    for b in breaks
        push!(breakstrs, formatter(b))
    end
    if boundedness == :unbounded
        ncategories = n + 1
    elseif boundedness == :bounded
        ncategories = n-1
    else
        ncategories = n
    end
    pool = Vector{String}(undef, ncategories)
    if rank
        rankwidth = length(string(ncategories))
    end
    if !rank
        rankprefixfunc = _->""
    elseif reverse
        rankprefixfunc = j -> format(n+2-j, width = rankwidth) * ranksep
    else
        rankprefixfunc = j -> format(j, width = rankwidth) * ranksep
    end
    if compact
        if S <: Integer && T <: Integer && scale == 1
            # we use 1...5, 6, 7...10, 11+etc.
            if leftequal
                breakminus1strs = String[]
                for b in breaks
                    push!(breakminus1strs, formatter(b-1))
                end
                poolindexshift = -1
                if boundedness in [:unbounded, :boundedabove]
                    pool[1] = rankprefixfunc(1) * "≤" * breakminus1strs[1]
                    poolindexshift = 0
                end
                for i = 2:n
                    if breaks[i-1] == breaks[i]-1
                        pool[i+poolindexshift] =
                            rankprefixfunc(i+poolindexshift)*breakstrs[i-1]
                    else
                        pool[i+poolindexshift] =
                            rankprefixfunc(i+poolindexshift)*breakstrs[i-1]*"…"*breakminus1strs[i]
                    end
                end
                if boundedness in [:unbounded, :boundedbelow]
                    pool[n+1+poolindexshift] =
                        rankprefixfunc(n+1+poolindexshift)*breakstrs[n]*"+"
                end
            else
                breakplus1strs = String[]
                for b in breaks
                    push!(breakminus1strs, formatter(b+1))
                end
                poolindexshift = -1
                if boundedness in [:unbounded, :boundedabove]
                    pool[1] = rankprefixfunc(1) * "≤ " * breakstrs[1]
                    poolindexshift = 0
                end
                for i = 2:n
                    if breaks[i-1]+1 == breaks[i]
                        pool[i+poolindexshift] =
                            rankprefixfunc(i+poolindexshift)*breakstrs[i]
                    else
                        pool[i+poolindexshift] =
                            rankprefixfunc(i+poolindexshift)*breakplus1strs[i-1]*"…"*breakstrs[i]
                    end
                end
                if boundedness in [:unbounded, :boundedbelow]
                    pool[n+1+poolindexshift] =
                        rankprefixfunc(n+1+poolindexshift)*breakplus1strs[n]*"+"
                end
            end
        else # by the way, we don't show absolute in compact
            if leftequal
                brackL = "["
                brackR = ")"
                compareL = "<"
                compareR = "≥"
            else
                brackL = "("
                brackR = "]"
                compareL = "≤"
                compareR = ">"
            end
            poolindexshift = -1
            if boundedness in [:unbounded, :boundedabove]
                pool[1] = rankprefixfunc(1) * compareL * breakstrs[1]
                poolindexshift = 0
            end
            for i = 2:n
                if i == 2 && boundedness in [:boundedbelow, :bounded]
                    pool[i+poolindexshift] =
                        rankprefixfunc(i+poolindexshift) *
                        "[" *
                        breakstrs[i-1] *
                        "," *
                        breakstrs[i] *
                        brackR
                elseif i == n && boundedness in [:boundedabove, :bounded]
                    pool[i+poolindexshift] =
                        rankprefixfunc(i+poolindexshift) *
                        brackL *
                        breakstrs[i-1] *
                        "," *
                        breakstrs[i] *
                        "]"
                else
                    pool[i+poolindexshift] =
                        rankprefixfunc(i+poolindexshift) *
                        brackL *
                        breakstrs[i-1] *
                        "," *
                        breakstrs[i] *
                        brackR
                end
            end
            if boundedness in [:unbounded, :boundedbelow]
                pool[n+1+poolindexshift] =
                    rankprefixfunc(n+1+poolindexshift) * compareR * breakstrs[n]
            end
        end
    else
        if absolute
            label2 = "|"*label*"|"
        else
            label2 = label
        end
        if leftequal
            compareL = " ≤ "
            compareR = " < "
        else
            compareL = " < "
            compareR = " ≤ "
        end
        poolindexshift = -1
        if boundedness in [:unbounded, :boundedabove]
            pool[1] = rankprefixfunc(1) * label2 * compareR * breakstrs[1]
            poolindexshift = 0
        end
        for i = 2:n
            if i == 2 && boundedness in [:boundedbelow, :bounded]
                pool[i+poolindexshift] =
                    rankprefixfunc(i+poolindexshift) *
                    breakstrs[i-1] *
                    " ≤ " *
                    label2 *
                    compareR *
                    breakstrs[i]
            elseif i == n && boundedness in [:boundedabove, :bounded]
                pool[i+poolindexshift] =
                    rankprefixfunc(i+poolindexshift) *
                    breakstrs[i-1] *
                    compareL *
                    label2 *
                    " ≤ " *
                    breakstrs[i]
            else
                pool[i+poolindexshift] =
                    rankprefixfunc(i+poolindexshift) *
                    breakstrs[i-1] *
                    compareL *
                    label2 *
                    compareR *
                    breakstrs[i]
            end
        end
        if boundedness in [:unbounded, :boundedbelow]
            pool[n+1+poolindexshift] =
                rankprefixfunc(n+1+poolindexshift) * breakstrs[n] * compareL * label2
        end
    end
    return pool
end

# boundedness:
#    unbounded    gives n+1 categories for n breaks.
#    boundedbelow gives n   categories for n breaks. Values below min will be missing
#    boundedabove gives n   categories for n breaks. Values above max will be missing
#    bounded      gives n-1 categories for n breaks. Values below min or above max will be missing
function discretize(
    x::AbstractArray{<:Union{S,Missing},1},
    breaks::Vector{T};
    boundedness = :unbounded,
    bucketstrs = String[], # if provided, all of below will be ignored. length must be length(breaks)+1
    leftequal = true, # t1 <= x < t2 or t1 < x <= t2?
    absolute = false, # t1 <= |x| < t2?
    rank = true, # add a rank to the string output for easier sorting?
    ranksep = ". ", # "1. t1 <= x < t2"?
    label = "", # if not compact, what label do we use for x?
    compact = (label==""), # <t1, [t1,t2), t2+. Further shortened for integer intervals with length=1
    reverse = false, # reverse the rank from the largest first?
    # the following format the boundary numbers
    # see Formatting.jl
    prefix = "",
    suffix = "",
    scale = 1,
    precision = -1,
    commas = false,
    stripzeros = (precision==-1),
    parens = false,
    mixedfraction = false,
    autoscale = :none,
    conversion = "",
) where {S<:Real,T<:Real}
    if !issorted(breaks)
        sort!(breaks)
    end
    refs = fill(UInt32(0), length(x))
    n = length(breaks)
    if absolute
        x2 = abs.(x)
    else
        x2 = x
    end

    if boundedness == :unbounded
        below_min_mult = 1
        above_max_mult = 1
        ref_shift = 1
        ncategories = length(breaks) + 1
    elseif boundedness == :boundedbelow
        below_min_mult = 0
        above_max_mult = 1
        ref_shift = 0
        ncategories = length(breaks)
    elseif boundedness == :boundedabove
        below_min_mult = 1
        above_max_mult = 0
        ref_shift = 1
        ncategories = length(breaks)
    elseif boundedness == :bounded
        below_min_mult = 0
        above_max_mult = 0
        ref_shift = 0
        ncategories = length(breaks) - 1
    end

    if ncategories < 1
        error("Too few categories. Change boundedness or add breaks")
    end

    if leftequal
        for i = 1:length(x)
            if ismissing(x[i])
                refs[i] = 0
            elseif x2[i] < breaks[1]
                refs[i] = below_min_mult
            elseif x2[i] > breaks[end]
                refs[i] = (n+ref_shift) * above_max_mult
            elseif x2[i] == breaks[end]
                if boundedness in [:bounded, :boundedabove]
                    refs[i] = ncategories
                else
                    refs[i] = n+ref_shift
                end
            else
                refs[i] = searchsortedlast(breaks, x2[i]) + ref_shift
            end
        end
    else
        for i = 1:length(x)
            if ismissing(x[i])
                refs[i] = 0
            elseif x2[i] < breaks[1]
                refs[i] = below_min_mult
            elseif x2[i] > breaks[end]
                refs[i] = (n+ref_shift) * above_max_mult
            else
                refs[i] = searchsortedfirst(breaks, x2[i])
            end
        end
    end

    if length(bucketstrs) != 0
        if length(bucketstrs) != ncategories
            error(
                "bucketstrs expected to have size " *
                string(ncategories) *
                ". Got " *
                string(length(bucketstrs)),
            )
        end
        if maximum(refs) > ncategories
            maxref = maximum(refs)
            s =
                "ncategories < max refs \n maxref=" *
                string(maxref) *
                "\n ncategories=" *
                string(ncategories)
            s *= "\n buckets = " * string(bucketstrs)
            idx = findfirst(isequal(maxref), refs)
            s *= "\n Example x = " * string(x2[idx])
            s *= "\n breaks" * string(breaks)
            error(s)
        end
        return CategoricalArray(
            Union{Missing,String}[
                refs[i] == 0 ? missing : String(bucketstrs[refs[i]]) for i = 1:length(refs)
            ],
        )
    end
    pool = cut_categories(
        S,
        breaks,
        boundedness = boundedness,
        leftequal = leftequal,
        absolute = absolute,
        rank = rank,
        ranksep = ranksep,
        label = label,
        compact = compact,
        reverse = reverse,
        prefix = prefix,
        suffix = suffix,
        scale = scale,
        precision = precision,
        commas = commas,
        stripzeros = stripzeros,
        parens = parens,
        mixedfraction = mixedfraction,
        autoscale = autoscale,
        conversion = conversion,
    )

    CategoricalArray(
        Union{Missing,String}[
            refs[i] == 0 ? missing : pool[refs[i]] for i = 1:length(refs)
        ],
    )
end

# quantile-based auto-breaks
# weighted quantile is not implemented
# use scale=100.0, suffix="%", to express the quantiles in percentages
function discretize(
    x::AbstractArray{S,1};
    quantiles = Float64[],
    ngroups::Int = 4,
    kwargs...,
) where {S<:Real}
    if length(quantiles) != 0
        if any(x -> x < 0.0 || x > 1.0, quantiles)
            error("illegal quantile numbers outside [0,1]")
        end
        if !issorted(quantiles)
            sort!(quantiles)
        end
        if quantiles[1] != 0.0
            insert!(quantiles, 1, 0.0)
        end

        if quantiles[end] != 1.0
            push!(quantiles, 1.0)
        end
        bucketstrs = cut_categories(Float64, quantiles; boundedness = :bounded, kwargs...)
        discretize(
            x,
            quantile(x, quantiles);
            bucketstrs = bucketstrs,
            boundedness = :bounded,
            kwargs...,
        )
    else
        qs = collect(0:ngroups) ./ ngroups
        bucketstrs = cut_categories(Float64, qs; boundedness = :bounded, kwargs...)
        discretize(
            x,
            quantile(x, qs);
            bucketstrs = bucketstrs,
            boundedness = :bounded,
            kwargs...,
        )
    end
end

# names are expected to be unique
# n is the maximum rank number to report. Actual outcome may depend on existence of a tie, and dense option
function topnames(
    name::AbstractArray{S,1},
    measure::AbstractArray{T,1},
    n::Int;
    absolute = false,
    ranksep = ". ",
    dense = true, # if there is a tie in the 2nd place, do we do "1,2,2,4", or "1,2,2,3"
    tol = 0,  # if absolute, what is the smallest contribution that we would consider
    others = "Others",
    parens = false, # put parentheses around names with negative measure?
) where {S<:AbstractString,T<:Real}

    if absolute
        df = DataFrame(name = name, measure = measure, absmeasure = abs.(measure))
        if tol > 0 # filter out too small names
            dfsorted = sort(
                df[df.absmeasure .>= tol, :],
                [:absmeasure, :measure],
                rev = [true, true],
            )
        else
            dfsorted = sort(df, [:absmeasure, :measure], rev = [true, true])
        end
    else
        df = DataFrame(name = name, measure = measure)
        dfsorted = sort(df, [:measure], rev = [true])
    end

    rankcount = 1
    rankwidth = length(string(n))
    nr = nrow(dfsorted)

    if !absolute
        pool = String[]
        refs = fill(UInt32(0), nr)
        lastval = zero(T)
        lastrank = 0
        for r = 1:nr
            if ismissing(dfsorted[r, :measure])
                continue
            else
                val = dfsorted[r, :measure]
                if lastrank != 0 && lastval == val # tie
                    push!(
                        pool,
                        format(lastrank, width = rankwidth) * ranksep * dfsorted[r, :name],
                    )
                    refs[r] = length(pool)
                    if !dense
                        rankcount += 1
                    end
                elseif rankcount > n
                    break
                else
                    push!(
                        pool,
                        format(rankcount, width = rankwidth) * ranksep * dfsorted[r, :name],
                    )
                    lastrank = rankcount
                    lastval = val
                    refs[r] = length(pool)
                    rankcount += 1
                end
            end
        end
        dfsorted[!, :rankstr] =
            Union{Missing,String}[refs[r] == 0 ? missing : pool[refs[r]] for r = 1:nr]
        rankdict = Dict{String,Union{String,Missing}}(
            dfsorted[r, :name] => dfsorted[r, :rankstr] for r = 1:nr
        )
        jdf_rankstr = Union{String,Missing}[get(rankdict, n, missing) for n in name]
    else
        rankedflag = fill(false, nr)
        lastval = zero(T)
        lastrank = 0
        for r = 1:nr
            if ismissing(dfsorted[r, :measure])
                continue
            else
                val = dfsorted[r, :measure]
                if lastrank != 0 && lastval == val # tie
                    rankedflag[r] = true
                    if !dense
                        rankcount += 1
                    end
                elseif rankcount > n
                    break
                else
                    rankedflag[r] = true
                    lastrank = rankcount
                    lastval = val
                    rankcount += 1
                end
            end
        end
        dfsorted[!, :rankedflag] = rankedflag
        dfsorted2 = sort(dfsorted, [:measure], rev = [true])
        rankstr = Union{Missing,String}[missing for _ = 1:nr]
        rankcount = 1
        lastval = zero(T)
        lastrank = 0
        for r = 1:nr
            if ismissing(dfsorted2[r, :measure])
                continue
            elseif dfsorted2[r, :rankedflag]
                val = dfsorted2[r, :measure]
                if lastrank != 0 && lastval == val # tie
                    if parens && val < 0
                        rankstr[r] =
                            format(lastrank, width = rankwidth) *
                            ranksep *
                            "(" *
                            dfsorted2[r, :name] *
                            ")"
                    else
                        rankstr[r] =
                            format(lastrank, width = rankwidth) *
                            ranksep *
                            dfsorted2[r, :name]
                    end
                    if !dense
                        rankcount += 1
                    end
                elseif rankcount > n
                    break
                else
                    if parens && val < 0
                        rankstr[r] =
                            format(rankcount, width = rankwidth) *
                            ranksep *
                            "(" *
                            dfsorted2[r, :name] *
                            ")"
                    else
                        rankstr[r] =
                            format(rankcount, width = rankwidth) *
                            ranksep *
                            dfsorted2[r, :name]
                    end
                    lastrank = rankcount
                    lastval = val
                    rankcount += 1
                end
            end
        end
        dfsorted2[!, :rankstr] = rankstr
        rankdict = Dict{String,Union{String,Missing}}(
            dfsorted2[r, :name] => dfsorted2[r, :rankstr] for r = 1:nrow(dfsorted2)
        )
        jdf_rankstr = Union{String,Missing}[get(rankdict, n, missing) for n in name]
    end

    # replace missing with "others"
    CategoricalArray([ismissing(x) ? others : x for x in jdf_rankstr])
end

function describe(io::IO, dv::AbstractVector)
    show(io, DataFrames.describe(DataFrame(x = dv)))
    println(io)
end

# lag / lead: shift a vector by n slots, filling vacated slots with `default`.
# Intended for order-based window dimensions (previous/next sibling row).
function lag(v::AbstractVector, n::Integer = 1; default = missing)
    n < 0 && return lead(v, -n; default = default)
    [i > n ? v[i-n] : default for i = 1:length(v)]
end

function lead(v::AbstractVector, n::Integer = 1; default = missing)
    n < 0 && return lag(v, -n; default = default)
    len = length(v)
    [i + n <= len ? v[i+n] : default for i = 1:len]
end

# strjoinuniq: the unique non-missing values as strings, sorted and joined with
# `sep`, capped at `limit` characters (a trailing "…" marks truncation).
# Intended for concise group displays, e.g. the districts inside a county cell.
function strjoinuniq(x::AbstractVector, sep::AbstractString = ",", limit::Integer = 128)
    vals = sort!(unique(string(v) for v in skipmissing(x)))
    s = join(vals, sep)
    length(s) <= limit ? s : first(s, max(limit - 1, 0)) * "…"
end

# percent label for a quantile boundary: 0.25 -> "25%", 0.125 -> "12.5%"
function pctstr(x::Real)
    v = x * 100
    r = round(v)
    (abs(v - r) < 1e-9 ? string(Int(r)) : string(v)) * "%"
end

# quantiles: label each element by the quantile bucket it falls into, with the
# thresholds computed from the vector itself. `qs` are the INNER boundaries --
# 0 and 1 are implied, so qs = [.25, .5, .75] yields four buckets:
#   1. [0%, 25%)   2. [25%, 50%)   3. [50%, 75%)   4. [75%, 100%]
# (leftequal = false flips to "[0%, 25%]", "(25%, 50%]", ...). `prefix` /
# `suffix` decorate the interval: "1. <prefix> [0%, 25%) <suffix>".
# In a dim spec, bare use buckets rows individually (window kind); grouping is
# declared via the universal modifier --
#   dim"quantiles(TestScr, [.25,.5,.75]) |> groupby(District)"
# groups by District, aggregates TestScr per district (per AggrHints), and
# buckets the districts (Julia-side: dimspec(...; by=:District, kind=:pivot)).
function quantiles(
    measure::AbstractVector,
    qs::AbstractVector{<:Real};
    leftequal::Bool = true,
    prefix::AbstractString = "",
    suffix::AbstractString = "",
)
    isempty(qs) && error("quantiles: need at least one quantile boundary")
    all(diff(collect(Float64, qs)) .> 0) ||
        error("quantiles: boundaries must be strictly increasing")
    (first(qs) > 0.0 && last(qs) < 1.0) ||
        error("quantiles: boundaries must be strictly inside (0, 1) -- 0 and 1 are implied")

    n = length(qs) + 1
    bounds = [0.0; collect(Float64, qs); 1.0]
    rankwidth = length(string(n))
    pool = Vector{String}(undef, n)
    for i = 1:n
        lo = pctstr(bounds[i])
        hi = pctstr(bounds[i+1])
        iv = if leftequal
            i == n ? "[" * lo * ", " * hi * "]" : "[" * lo * ", " * hi * ")"
        else
            i == 1 ? "[" * lo * ", " * hi * "]" : "(" * lo * ", " * hi * "]"
        end
        pool[i] =
            format(i, width = rankwidth) * ". " *
            (isempty(prefix) ? "" : prefix * " ") * iv *
            (isempty(suffix) ? "" : " " * suffix)
    end

    clean = collect(skipmissing(measure))
    if isempty(clean)
        return CategoricalArray(Union{Missing,String}[missing for _ in measure])
    end
    thr = quantile(clean, collect(Float64, qs))
    labels = Union{Missing,String}[
        ismissing(v) ? missing :
        pool[leftequal ? searchsortedlast(thr, v) + 1 : max(searchsortedfirst(thr, v), 1)]
        for v in measure
    ]
    CategoricalArray(labels)
end
