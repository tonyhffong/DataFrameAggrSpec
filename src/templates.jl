# templates.jl -- PROACTIVE spec suggestion: the starter templates and
# completion vocabulary a host offers a user who is about to type a spec.
#
# This is the forward-looking half of the same job suggest.jl does backwards.
# `didyoumean` repairs a token the user ALREADY typed against the operator
# registry and the frame's columns; `spec_templates` proposes whole specs from
# the same vocabulary before a key is pressed, and `spec_vocabulary` feeds
# identifier completion in between. All three read the one authority on what
# the grammar accepts -- SafeOps -- so a `registerop!` is reflected everywhere
# rather than drifting against a catalogue hardcoded in a host.
#
# Deliberately UI-free, like the rest of the package: these are pure functions
# over (column types, target, data) -> Vector{String}. Decoration (a ✓/✗ glyph,
# truncation to a one-row hint, a dropdown) is the host's business. TermWin's
# newTwSpecEntry is the reference consumer, but nothing here knows about it.
#
# AGGR templates are written against `_` -- the aggregation target -- and never
# enumerate the frame's columns. An aggregation reduces exactly ONE column and
# the host always knows which one (a table's cursor sits on it), so a per-column
# catalogue would be N copies of one list where only the target's *type* differs.
# Context therefore FILTERS rather than names:
#
#   * the TARGET's type family picks the reducer set -- numeric -> sum/mean/std…,
#     text -> uniqvalue/strjoinuniq…, `Bool` -> the group flags rather than the
#     `Bool <: Number` reducers, date -> minimum/maximum/first/last.
#   * the frame's OTHER columns gate the shapes that need a second column: a
#     weighted mean needs something to weight by, `|> orderby(…)` an ordering
#     key. The second column keeps a GENERIC placeholder (`wt`, `date`, `year`)
#     for the user to edit -- the frame decides only whether the shape is worth
#     offering. Until the placeholder is replaced the spec fails `checkcols`
#     with a did-you-mean pointing at the real column, which is the fastest path
#     to the right name anyway.
#   * the DATA the host is looking at (the target column's values in the group
#     under the cursor) promotes the specs that answer what the values actually
#     look like: missings present -> the `skipmissing`/`coalesce` variants lead;
#     the column is constant or low-cardinality -> `uniqvalue`/`countuniq` lead;
#     a numeric column carrying negatives -> the sign predicates.
#
# DIM templates stay per-column: a dimension reads arbitrary columns by name and
# has no `_`, so there is no single target to write against.

# Coarse column families that drive which reducers/verbs are worth suggesting.
# `nonmissingtype` peels `Union{Missing,T}` so a nullable numeric still reads as
# numeric.
function _type_family(T::Type)
    U = nonmissingtype(T)
    U === Bool                               ? :bool :   # before :numeric (Bool <: Number)
    U <: Number                              ? :numeric :
    U <: Union{AbstractString,Symbol,AbstractChar} ? :text :
    U <: Dates.TimeType                      ? :date :
    :other
end

# Normalise the many ways a caller can hand us column types into an *ordered*
# vector of `Symbol => Type` pairs (order preserved so suggestions follow the
# frame's column order). Accepts a DataFrame, a Dict, or any iterable of pairs.
_normalize_coltypes(::Nothing) = nothing
_normalize_coltypes(df::AbstractDataFrame) =
    Pair{Symbol,Type}[n => eltype(df[!, n]) for n in propertynames(df)]
_normalize_coltypes(d::AbstractDict) =
    Pair{Symbol,Type}[Symbol(k) => v for (k, v) in d]
_normalize_coltypes(v) =
    Pair{Symbol,Type}[Symbol(first(p)) => last(p) for p in v]

# ---- aggr: the `_`-based catalogue ------------------------------------------

# Reducers worth offering for a target column of each family, most-likely-first.
const _AGGR_BY_FAMILY = Dict{Symbol,Vector{String}}(
    :numeric => ["sum(_)", "mean(_)", "median(_)", "minimum(_)", "maximum(_)",
                 "std(_)", "quantile(_, .25)",
                 "count(_ > 0)",
                 "count(_ in [1, 2, 5])",  # membership: `in`/`∈`/`∉` beat a chain of `||`
                 "any(_ > 0)",             # group-level flag: at least one row clears the bar
                 "all(_ > 0)"],            # group-level flag: every row does
    # `Bool <: Number`, so the numeric reducers technically apply -- but the
    # group-level flags are what a Bool column is actually asked for.
    :bool    => ["any(_)", "all(_)", "count(_)", "sum(_)"],
    :text    => ["uniqvalue(_)", "strjoinuniq(_)", "first(_)", "last(_)",
                 "count(_ in [\"a\", \"b\"])"],
    :date    => ["minimum(_)", "maximum(_)", "first(_)", "last(_)"],
    :other   => ["uniqvalue(_)", "first(_)", "last(_)"],
)

# Family order used when the target is unknown -- the generic list is every
# family's reducers with all the gates below opened.
const _AGGR_FAMILY_ORDER = (:numeric, :bool, :text, :date, :other)

# Shapes that reference a SECOND column, gated on the frame having one to offer.
# The name shown stays a placeholder the user edits.
const _AGGR_WEIGHTED  = ["sum(_ * wt) / sum(wt)",            # weighted mean
                         "wmeanfallback(_, [wt1, wt2, 1])"]  # cascading weights (1 = unweighted fallback)
const _AGGR_ORDERED   = ["last(_) |> orderby(date)",         # latest value (the arg-max spelling)
                         "first(_) |> orderby(date)"]        # earliest -- `orderby` sorts the group first
const _AGGR_COMPOSITE = ["mean(sum(_) |> groupby(year))",    # per-year totals, then averaged
                         "last(sum(_) |> groupby(year))"]    # the latest year's total

# Read the group as a whole rather than the target's values, so always offerable.
const _AGGR_TAIL = ["uniqvalue(_)", "countuniq", "nrow"]

# Forms that ERROR -- not merely return `missing` -- on a column that contains a
# `missing`: a predicate under `count` lands a `Missing` in boolean context, and
# `quantile` refuses outright. When the target can be missing these are SWAPPED
# for their in-grammar safe spellings rather than listed alongside them: offering
# a template that throws on the very column being aggregated is worse than not
# offering it. (`sum`/`mean`/`median`/`any` propagate `missing` instead of
# throwing, so they stay -- the `skipmissing` variants lead the list anyway.)
const _AGGR_MISSING_SAFE = Dict{String,String}(
    "quantile(_, .25)"           => "quantile(skipmissing(_), .25)",
    "count(_ > 0)"               => "count(coalesce(_ > 0, false))",
    "count(_ in [1, 2, 5])"      => "count(coalesce(_ in [1, 2, 5], false))",
    "count(_ in [\"a\", \"b\"])" => "count(coalesce(_ in [\"a\", \"b\"], false))",
    "count(_)"                   => "count(coalesce(_, false))",
    "any(_)"                     => "any(coalesce(_, false))",
    "all(_)"                     => "all(coalesce(_, true))",
)

# The missing-handling variants for a family. `uniqvalue`/`strjoinuniq`/
# `countuniq` already drop missings themselves, so the non-numeric families only
# gain the "how many are actually there" count.
function _aggr_missing_variants(fam)
    numericish = fam === nothing || fam === :numeric || fam === :bool
    out = String[]
    numericish && append!(out, ["sum(skipmissing(_))", "mean(skipmissing(_))",
                                "sum(coalesce(_, 0))"])
    (fam === nothing || !numericish) && push!(out, "first(skipmissing(_))")
    push!(out, "count(!ismissing(_))")
    out
end

# What the frame's OTHER columns make offerable. Every flag is about a SHAPE, not
# a name -- the template keeps its generic placeholder either way. No column
# information at all means "don't filter".
function _aggr_context(coltypes, target)
    coltypes === nothing && return (weight = true, order = true, group = true)
    weight = order = group = false
    for (c, T) in coltypes
        c === target && continue
        group = true                  # any other column can serve as a group key
        fam = _type_family(T)
        if fam === :numeric
            weight = true
            order  = true
        elseif fam === :date
            order = true
        end
    end
    (weight = weight, order = order, group = group)
end

# How many values we look at, and how many distinct ones we track, before giving
# up: the host may be sitting on a root node whose "group" is the whole frame,
# and this runs on a user keystroke.
const _AGGR_SCAN_LIMIT = 20_000
const _AGGR_CARD_LIMIT = 64

# What the target column's values actually look like -- the rows an aggregation
# typed right now would reduce. `nothing` when the host passed no data (or an
# empty group), in which case the promotions fall back to what the column's
# declared type alone can say.
function _aggr_datafacts(data)
    data === nothing && return nothing
    hasmissing = false
    negatives  = false
    seen       = Set{Any}()
    overcard   = false
    n          = 0
    for v in Iterators.take(data, _AGGR_SCAN_LIMIT)
        n += 1
        if v === missing
            hasmissing = true
            continue
        end
        if !overcard
            push!(seen, v)
            length(seen) > _AGGR_CARD_LIMIT && (overcard = true)
        end
        v isa Real && !(v isa Bool) && v < 0 && (negatives = true)
    end
    n == 0 && return nothing
    nuniq = overcard ? nothing : length(seen)
    (n          = n,
     hasmissing = hasmissing,
     negatives  = negatives,
     constant   = nuniq !== nothing && nuniq <= 1,
     lowcard    = nuniq !== nothing && 0 < nuniq <= 12 && 2 * nuniq < n)
end

# Build the aggr list for one target column. `targettype` picks the reducer set,
# `coltypes` gates the two-column shapes, `data` does the promoting. Every
# argument is optional -- with all of them `nothing` this is the generic
# catalogue (`_AGGR_TEMPLATES`).
function _aggr_templates_for(coltypes, target, targettype, data)
    fam   = targettype === nothing ? nothing : _type_family(targettype)
    ctx   = _aggr_context(coltypes, target)
    facts = _aggr_datafacts(data)

    # The type says `missing` is possible; the data says it is actually there.
    # Only the latter earns a spot at the TOP of the list.
    admits   = targettype === nothing || targettype !== nonmissingtype(targettype)
    observed = facts !== nothing && facts.hasmissing
    mvars    = (observed || (facts === nothing && admits)) ?
               _aggr_missing_variants(fam) : String[]

    lead = String[]                        # what the observed data argues for
    observed && append!(lead, mvars)
    if facts !== nothing
        if facts.constant
            push!(lead, "uniqvalue(_)")    # one value across the whole group
        elseif facts.lowcard
            append!(lead, ["uniqvalue(_)", "countuniq", "strjoinuniq(_)"])
        end
        facts.negatives && append!(lead, ["count(_ > 0)", "any(_ < 0)"])
    end

    body = String[]
    for f in (fam === nothing ? _AGGR_FAMILY_ORDER : (fam,))
        append!(body, get(_AGGR_BY_FAMILY, f, String[]))
    end
    observed || append!(body, mvars)
    numericish = fam === nothing || fam === :numeric || fam === :bool
    numericish && ctx.weight && append!(body, _AGGR_WEIGHTED)
    ctx.order              && append!(body, _AGGR_ORDERED)
    numericish && ctx.group && append!(body, _AGGR_COMPOSITE)
    append!(body, _AGGR_TAIL)

    out = append!(lead, body)
    # a missing-capable target gets the safe spelling of the throwing forms
    isempty(mvars) || map!(t -> get(_AGGR_MISSING_SAFE, t, t), out, out)
    unique!(out)
end

# The list when nothing about the target is known: every family's reducers with
# all the gates open.
const _AGGR_TEMPLATES = _aggr_templates_for(nothing, nothing, nothing, nothing)

# ---- dim: the per-column catalogue ------------------------------------------

# Fallback dim templates when the caller gives no column information; the sample
# column names are meant to be edited to the real ones.
const _DIM_TEMPLATES = String[
    "cumsum(sales) |> orderby(date)",       # running total within a partition
    "cumsum(sales) |> groupby(yyyymm(date))",  # computed groupby key: reset each month
    "lag(sales) |> orderby(date)",          # previous row's value
    "lead(sales) |> orderby(date)",         # next row's value
    "discretize(score, [0, 20, 40, 60, 80, 100])",  # labeled bins
    "topnames(name, sales, 5)",             # top-5 by measure, rest -> "Others"
    "quantiles(score, ngroups=4)",          # quartile bucket
    "rank(sales, rev = true)",              # 1 = biggest; ties share, then skip
    "denserank(sales)",                     # ties share, no gaps
    "tiedrank(sales)",                      # ties share their average rank
    "ordinalrank(sales) |> orderby(date)",  # no ties -- needs an order to be defined
    "rank(sales) |> groupby(district)",     # rank the GROUPS by their total
    "where(profit > 0) |> groupby(business)",  # per-group predicate flag
    "where(district in [\"d1\", \"d2\"])",  # membership flag (`∈`/`∉` also accepted)
    "yyyymm(date)",                         # date -> "YYYYMM" period bucket
    "yyyy(date)",                           # date -> "YYYY" year bucket
    "yyyyq(date)",                          # date -> "YYYYQn" quarter bucket
    "yymm(date)",                           # date -> "YYMM" period bucket
    "yyq(date)",                            # date -> "YYQn" quarter bucket
]

# Per-column, type-appropriate DIM verbs: numeric columns get binning, ranking
# and running windows (ordered by the first date/other column), text columns get
# top-N and grouped means (measured by the first numeric column, when there is
# one), date columns get the calendar buckets, `Bool` columns get `where`. The
# tie-shape variants of ranking (`denserank`/`tiedrank`/`ordinalrank`) and the
# grouped rank are demonstrated once on the measure column rather than repeated
# per column -- this is a starting point, not a catalogue.
function _dim_templates_for(coltypes)
    nums  = Symbol[c for (c, T) in coltypes if _type_family(T) === :numeric]
    texts = Symbol[c for (c, T) in coltypes if _type_family(T) === :text]
    dates = Symbol[c for (c, T) in coltypes if _type_family(T) === :date]
    bools = Symbol[c for (c, T) in coltypes if _type_family(T) === :bool]
    order = !isempty(dates) ? first(dates) : (length(nums) > 1 ? nums[1] : nothing)
    measure = isempty(nums) ? nothing : first(nums)
    out = String[]
    for c in nums
        push!(out, "discretize($c, [0, 20, 40, 60, 80, 100])")
        push!(out, "quantiles($c, 4)")
        push!(out, "rank($c, rev = true)")          # 1 = biggest
        if order !== nothing && order != c
            push!(out, "cumsum($c) |> orderby($order)")
            push!(out, "lag($c) |> orderby($order)")
        end
    end
    for c in texts
        measure !== nothing && push!(out, "topnames($c, $measure, 5)")
        measure !== nothing && push!(out, "mean($measure) |> groupby($c)")
        measure !== nothing && push!(out, "rank($measure) |> groupby($c)")  # rank the groups
    end
    for c in dates
        append!(out, ["yyyymm($c)", "yyyy($c)", "yyyyq($c)", "yymm($c)"])
        measure !== nothing && push!(out, "cumsum($measure) |> groupby(yyyymm($c))")
    end
    for c in bools
        push!(out, "where($c)")
        isempty(texts) || push!(out, "where(any($c)) |> groupby($(first(texts)))")
    end
    if measure !== nothing
        # the tie shapes, once -- `ordinalrank` is the one that needs an order
        append!(out, ["denserank($measure)", "tiedrank($measure)"])
        order !== nothing && order != measure &&
            push!(out, "ordinalrank($measure) |> orderby($order)")
    end
    isempty(out) ? copy(_DIM_TEMPLATES) : unique!(out)
end

# ---- public API -------------------------------------------------------------

"""
    spec_templates(kind::Symbol; coltypes=nothing, target=nothing,
                   targettype=nothing, targetdata=nothing) -> Vector{String}

Starter spec strings for `kind` (`:aggr` or `:dim`) — what a host offers a user
who is about to type a spec but does not remember the grammar. Every entry is
valid input to [`parseaggr`](@ref) / [`parsedim`](@ref).

**`:aggr`** templates always reduce `_`, the aggregation target, and never name
the target column. Context narrows the list rather than expanding it:

* `target` / `targettype` — the column being aggregated. Its type family picks
  the reducer set (numeric → `sum`/`mean`/`std`/…, text →
  `uniqvalue`/`strjoinuniq`/…, `Bool` → the group flags `any`/`all`/`count`,
  date → `minimum`/`maximum`/`first`/`last`). `targettype` defaults to `target`'s
  entry in `coltypes`, then to `eltype(targetdata)`.
* `coltypes` — the rest of the frame, which gates the shapes needing a *second*
  column: `sum(_ * wt) / sum(wt)` only when some other column is numeric,
  `last(_) |> orderby(date)` only when there is an ordering key. Those keep the
  generic `wt`/`date`/`year` placeholder names for the user to edit — they will
  not pass [`checkcols`](@ref) until replaced, which is deliberate: the
  did-you-mean repair then names the real column.
* `targetdata` — the target column's values in the group the user is looking at.
  Their shape promotes entries to the front: missings present → the
  `skipmissing`/`coalesce` variants, a constant or low-cardinality column →
  `uniqvalue`/`countuniq`, negatives in a numeric column → the sign predicates.
  Seeing real values also *overrides* the declared type — a `Union{Missing,T}`
  column with no missing in this group keeps the plain spellings. Scanned lazily
  and capped, so passing a large group is cheap.

Forms that would **throw** on a missing (`quantile(_, .25)`, `count(_ > 0)`,
`count(_)`) are swapped for their safe spellings, not listed alongside them,
whenever the target can be missing.

**`:dim`** templates are per-column and type-matched (a dimension reads arbitrary
columns by name and has no `_`): binning/window verbs go to numeric columns,
top-N and grouped means to text columns, calendar buckets to dates, `where` to
`Bool`s. `target`/`targettype`/`targetdata` are ignored for `:dim`.

`coltypes` may be an `AbstractDataFrame` (column → `eltype`), a `Dict{Symbol,Type}`,
or any iterable of `Symbol => Type` pairs; order is preserved.

The returned order is a suggestion ranking, most-likely-first. A host that wants
its own ordering should sort the result rather than expect a stable sequence.

```julia
spec_templates(:aggr; coltypes = df, target = :sales, targetdata = df.sales)
spec_templates(:dim;  coltypes = df)
```

See also [`spec_vocabulary`](@ref) for identifier completion.
"""
function spec_templates(kind::Symbol; coltypes = nothing, target = nothing,
                        targettype = nothing, targetdata = nothing)
    ct = _normalize_coltypes(coltypes)
    if kind === :aggr
        tt = _resolve_targettype(ct, target, targettype, targetdata)
        ct === nothing && tt === nothing && targetdata === nothing &&
            return copy(_AGGR_TEMPLATES)
        _aggr_templates_for(ct, target, tt, targetdata)
    elseif kind === :dim
        ct === nothing ? copy(_DIM_TEMPLATES) : _dim_templates_for(ct)
    else
        error("spec_templates: kind must be :aggr or :dim, got $(repr(kind))")
    end
end

# The target column's type, from whichever source the caller supplied: explicit
# `targettype`, else its `coltypes` entry, else the data's eltype.
function _resolve_targettype(ct, target, targettype, targetdata)
    targettype === nothing || return targettype
    if target !== nothing && ct !== nothing
        i = findfirst(p -> first(p) === target, ct)
        i === nothing || return last(ct[i])
    end
    targetdata === nothing ? nothing : eltype(targetdata)
end

"""
    spec_columns(coltypes) -> Union{Nothing,Vector{Symbol}}

The column names named by a `coltypes` argument (an `AbstractDataFrame`, a
`Dict{Symbol,Type}`, or an iterable of `Symbol => Type` pairs), in order;
`nothing` for `nothing`.

A host that already has `coltypes` for [`spec_templates`](@ref) gets the
`columns` list [`checkcols`](@ref) and [`spec_vocabulary`](@ref) want from the
same argument, rather than deriving it a second way.
"""
spec_columns(coltypes) =
    (ct = _normalize_coltypes(coltypes)) === nothing ? nothing :
    Symbol[first(p) for p in ct]

"""
    spec_coltype(coltypes, col::Symbol) -> Union{Nothing,Type}

The declared type of `col` in a `coltypes` argument, or `nothing` when it names
no such column. The lookup [`spec_templates`](@ref) does internally to resolve
`targettype` from `target`, exposed for hosts that want to label the target
(`"_ = sales::Float64"`).
"""
function spec_coltype(coltypes, col::Symbol)
    ct = _normalize_coltypes(coltypes)
    ct === nothing && return nothing
    i = findfirst(p -> first(p) === col, ct)
    i === nothing ? nothing : last(ct[i])
end

"""
    spec_vocabulary(kind::Symbol; columns=nothing) -> Vector{String}

Every identifier a spec of this `kind` may legally name: the whitelisted
operation names ([`listops`](@ref)) plus `columns`, plus the `orderby`/`groupby`
modifiers for `:dim`. Sorted and deduplicated.

The vocabulary for identifier (Tab) completion — the proactive counterpart to
the did-you-mean repair [`checkcols`](@ref) and the parser apply after the fact.
Operator glyphs (`+`, `==`, `≠`) are excluded: they are not identifier-
completable, and a host typically reaches them through a LaTeX-style `\\name`
expansion instead.

```julia
vocab = spec_vocabulary(:aggr; columns = propertynames(df))
filter(startswith("str"), vocab)      # -> ["strjoinuniq"]
```
"""
function spec_vocabulary(kind::Symbol; columns = nothing)
    kind in (:aggr, :dim) ||
        error("spec_vocabulary: kind must be :aggr or :dim, got $(repr(kind))")
    ops = String[string(o) for o in listops() if isletter(first(string(o)))]
    kind === :dim && append!(ops, String[string(m) for m in SafeModifiers])
    cols = columns === nothing ? String[] : String[string(c) for c in columns]
    sort!(unique!(vcat(cols, ops)))
end

"""
    specsummary(spec::Union{SafeAggrSpec,SafeDimSpec}) -> String

One-line structural description of a parsed spec — what it reduces or computes,
and (for a dim spec) which kind it inferred. For a host echoing back what the
text the user just typed actually means.

```julia
specsummary(aggr"sum(_ * wt) / sum(wt)")   # "reduce via /   [cols: _, wt]"
specsummary(dim"cumsum(x) |> orderby(d)")  # "cumsum   [ordered by d]"
```

See also [`specfields`](@ref) for the same information as labelled pairs.
"""
function specsummary(s::SafeAggrSpec)
    cols = join(string.(s.cols), ", ")
    "reduce via $(s.fname)   [cols: $(isempty(cols) ? "—" : cols)]"
end

function specsummary(s::SafeDimSpec)
    tags = String[]
    isempty(s.by)    || push!(tags, "pivot by " * join(string.(s.by), ", "))
    isempty(s.order) || push!(tags, "ordered by " *
                              join(string.(first.(s.order)), ", "))
    isempty(tags) && push!(tags, "window")
    "$(s.fname)   [" * join(tags, "; ") * "]"
end

"""
    specfields(spec::Union{SafeAggrSpec,SafeDimSpec}) -> Vector{Pair{String,String}}

The structure of a parsed spec as `label => value` pairs, for a host that wants
to lay the fields out itself (aligned columns, a table, a detail pane) rather
than take the one-line [`specsummary`](@ref). Only the fields that carry
information for this spec are present: a dim spec reports `group by` only when
it has a `groupby` (pivot kind) and `order by` only when it has an `orderby`
(window kind).
"""
function specfields(s::SafeAggrSpec)
    Pair{String,String}["function" => string(s.fname),
                        "columns"  => join(string.(s.cols), ", ")]
end

function specfields(s::SafeDimSpec)
    out = Pair{String,String}["function" => string(s.fname),
                              "columns"  => join(string.(s.cols), ", ")]
    isempty(s.by)    || push!(out, "group by" =>
        join(string.(s.by), ", ") * "   (pivot kind)")
    isempty(s.order) || push!(out, "order by" =>
        join(string.(first.(s.order)), ", ") * "   (window kind)")
    out
end
