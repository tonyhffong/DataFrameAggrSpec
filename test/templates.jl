using DataFrameAggrSpec
using DataFrames
using Dates
using Statistics
using Test

# Tests for src/templates.jl -- the PROACTIVE half of spec suggestion.
#
# The load-bearing property is the last testset: every template this package
# offers must PARSE and then RUN against the column it was offered for. A
# suggestion that errors on the very column it was suggested for is worse than
# no suggestion, and that is easy to break silently by editing a string here or
# changing an operator's semantics in verbs.jl. Everything above it pins the
# narrowing rules that decide WHICH templates get offered.

const DFAS = DataFrameAggrSpec

@testset "aggr templates always target `_`, never a named column" begin
    df = DataFrame(region = ["E", "W"], sales = [1, 2], score = [10.0, 20.0])
    for t in (spec_templates(:aggr),
              spec_templates(:aggr; coltypes = df),
              spec_templates(:aggr; coltypes = df, target = :sales),
              spec_templates(:aggr; coltypes = df, target = :region,
                             targetdata = df.region))
        # every entry reduces the placeholder (or reads the group as a whole)…
        @test all(s -> occursin('_', s) || s in ("countuniq", "nrow"), t)
        # …and none names a column of the frame
        @test !any(s -> occursin("sales", s) || occursin("region", s) ||
                        occursin("score", s), t)
    end
end

@testset "target type picks the reducer set" begin
    df = DataFrame(region = ["E", "W"], sales = [1, 2], active = [true, false])

    num = spec_templates(:aggr; coltypes = df, target = :sales)
    @test "sum(_)" in num && "median(_)" in num && "std(_)" in num
    @test !("strjoinuniq(_)" in num)

    txt = spec_templates(:aggr; coltypes = df, target = :region)
    @test "uniqvalue(_)" in txt && "strjoinuniq(_)" in txt
    @test !("sum(_)" in txt) && !("std(_)" in txt)

    # a Bool target gets the group flags, not the `Bool <: Number` reducers
    bl = spec_templates(:aggr; coltypes = df, target = :active)
    @test "any(_)" in bl && "all(_)" in bl && "count(_)" in bl
    @test !("std(_)" in bl) && !("median(_)" in bl)

    # a date target gets the extrema/endpoint reducers
    dt = spec_templates(:aggr; targettype = Date)
    @test "minimum(_)" in dt && "maximum(_)" in dt && "last(_)" in dt
    @test !("sum(_)" in dt)

    # nullable numeric still reads as numeric (nonmissingtype peels the Union)
    dfm = DataFrame(x = Union{Missing,Int}[1, missing])
    @test "sum(_)" in spec_templates(:aggr; coltypes = dfm, target = :x)

    # targettype alone works, and targetdata's eltype is the last resort
    @test "median(_)" in spec_templates(:aggr; targettype = Float64)
    @test "uniqvalue(_)" in spec_templates(:aggr; targetdata = ["a", "b"])
end

@testset "sibling columns gate the two-column shapes" begin
    df = DataFrame(region = ["E", "W"], date = [Date(2026, 1, 1), Date(2026, 2, 1)],
                   sales = [1, 2], wt = [1.0, 2.0])
    t = spec_templates(:aggr; coltypes = df, target = :sales)
    # the placeholder name stays generic -- the frame decides offerability only
    @test "sum(_ * wt) / sum(wt)"    in t
    @test "last(_) |> orderby(date)" in t

    # a lone numeric column: nothing to weight by, nothing to order by
    t2 = spec_templates(:aggr; coltypes = DataFrame(sales = [1]), target = :sales)
    @test !any(s -> occursin("orderby", s), t2)
    @test !any(s -> occursin("wt", s), t2)

    # a text-only sibling can group but neither weight nor order
    t3 = spec_templates(:aggr; coltypes = DataFrame(region = ["E"], sales = [1]),
                        target = :sales)
    @test !any(s -> occursin("orderby", s), t3)
    @test !any(s -> occursin("sum(_ * wt)", s), t3)
    @test "mean(sum(_) |> groupby(year))" in t3

    # the `orderby` gate follows the PLACEHOLDER, not just orderability: the
    # template names `date`, so a numeric-only frame must not be offered it
    t4 = spec_templates(:aggr; coltypes = DataFrame(sales = [1], cost = [2.0]),
                        target = :sales)
    @test !any(s -> occursin("orderby", s), t4)
    @test "sum(_ * wt) / sum(wt)" in t4          # a numeric sibling still weights
end

@testset "observed data promotes the specs that match the values" begin
    df = DataFrame(sales = [1, 2, 3], region = ["E", "W", "E"])

    # missings present -> the skipmissing/coalesce variants LEAD
    withm = spec_templates(:aggr; coltypes = df, target = :sales,
                           targetdata = Union{Missing,Int}[1, missing, 3])
    @test withm[1] == "sum(skipmissing(_))"
    @test "count(!ismissing(_))" in withm
    # …and the forms that would THROW on a missing are swapped, not listed
    @test "quantile(skipmissing(_), .25)" in withm
    @test !("quantile(_, .25)" in withm)
    @test !("count(_ > 0)" in withm)

    # seeing the actual rows beats the declared type: a nullable column with no
    # missing in THIS group keeps the plain spellings
    nom = spec_templates(:aggr; coltypes = df, target = :sales,
                         targetdata = Union{Missing,Int}[1, 2, 3])
    @test nom[1] == "sum(_)"
    @test "quantile(_, .25)" in nom
    @test !any(s -> occursin("skipmissing", s), nom)

    # …and with no data at all the declared type still earns the variants
    typeonly = spec_templates(:aggr; coltypes = df, target = :sales,
                              targettype = Union{Missing,Int})
    @test "sum(skipmissing(_))" in typeonly

    # constant across the group -> uniqvalue leads
    const_ = spec_templates(:aggr; coltypes = df, target = :sales,
                            targetdata = fill(7, 40))
    @test const_[1] == "uniqvalue(_)"

    # low cardinality -> uniqvalue/countuniq lead
    low = spec_templates(:aggr; coltypes = df, target = :sales,
                         targetdata = repeat([1, 2, 3], 20))
    @test low[1] == "uniqvalue(_)" && "countuniq" in low[1:3]

    # negatives -> the sign predicates lead
    neg = spec_templates(:aggr; coltypes = df, target = :sales,
                         targetdata = collect(-50:50))
    @test "count(_ > 0)" in neg[1:2] && "any(_ < 0)" in neg[1:2]

    # an empty group carries no information -- same list as no data at all
    @test spec_templates(:aggr; coltypes = df, target = :sales, targetdata = Int[]) ==
          spec_templates(:aggr; coltypes = df, target = :sales)

    # scanning is capped, so a huge group stays cheap and still classifies
    big = spec_templates(:aggr; coltypes = df, target = :sales,
                         targetdata = fill(3, DFAS._AGGR_SCAN_LIMIT * 2))
    @test big[1] == "uniqvalue(_)"
end

@testset "type-sensitive dim templates" begin
    df = DataFrame(region = ["E", "W"],
                   date   = [Date(2026, 1, 1), Date(2026, 2, 1)],
                   sales  = [1, 2])
    t = spec_templates(:dim; coltypes = df)

    @test "discretize(sales, [0, 20, 40, 60, 80, 100])" in t
    @test "quantiles(sales, ngroups = 4)"  in t   # count is a KEYWORD, not arg 2
    @test "cumsum(sales) |> orderby(date)" in t   # ordered by the date column
    @test "topnames(region, sales, 5)"     in t   # text col + numeric measure

    # ranking: per-column `rank`, the tie shapes once on the measure column,
    # `ordinalrank` paired with an order (the one shape that needs one)
    @test "rank(sales, rev = true)"             in t
    @test "denserank(sales)"                    in t
    @test "tiedrank(sales)"                     in t
    @test "ordinalrank(sales) |> orderby(date)" in t
    @test "rank(sales) |> groupby(region)"      in t   # rank the GROUPS
    # a pivot dim CLASSIFIES groups, so only vector->vector verbs belong under
    # `groupby` -- a reducer would return one scalar where the engine wants one
    # label per group
    @test "quantiles(sales, ngroups = 4) |> groupby(region)" in t
    @test !any(s -> occursin("mean(sales) |> groupby", s), t)

    # date columns get the calendar buckets + a computed groupby key
    @test "yyyymm(date)" in t
    @test "yyyyq(date)"  in t
    @test "cumsum(sales) |> groupby(yyyymm(date))" in t

    # a Bool column flags rather than bins
    b = spec_templates(:dim; coltypes = DataFrame(region = ["E", "W"],
                                                  sales = [1, 2],
                                                  active = [true, false]))
    @test "where(active)" in b
    # under `groupby` the Bool arrives aggregated to a per-group COUNT, so the
    # "any true in this group" test is `> 0` -- `any(active)` would get Ints
    @test "where(active > 0) |> groupby(region)" in b
    @test !any(s -> occursin("discretize(active", s), b)

    # :dim ignores the aggr-only target context
    @test spec_templates(:dim; coltypes = df, target = :sales,
                         targetdata = df.sales) == t
end

@testset "coltypes accepts a frame, a dict, or pairs; order preserved" begin
    d = DFAS._normalize_coltypes(Dict(:a => Int, :b => String))
    @test Set(d) == Set([:a => Int, :b => String])
    p = DFAS._normalize_coltypes([:x => Float64, :y => Symbol])
    @test p == [:x => Float64, :y => Symbol]      # iteration order kept
    @test DFAS._normalize_coltypes(nothing) === nothing
    # a frame follows its own column order
    @test first.(DFAS._normalize_coltypes(DataFrame(z = [1], a = ["x"]))) == [:z, :a]
end

@testset "spec_vocabulary" begin
    v = spec_vocabulary(:aggr; columns = [:sales, :region])
    @test "sales" in v && "region" in v
    @test "sum" in v && "strjoinuniq" in v
    @test v == sort(v) && allunique(v)             # sorted + deduplicated
    @test !any(s -> occursin("+", s) || occursin("=", s), v)  # no operator glyphs
    # BOTH modifiers are legal in BOTH kinds, so both are completable in both:
    # an aggr spec takes a top-level orderby and a nested groupby, and
    # spec_templates(:aggr) hands out text containing each
    for k in (:aggr, :dim)
        @test "orderby" in spec_vocabulary(k) && "groupby" in spec_vocabulary(k)
    end
    # every listed operation name is offered
    @test all(o -> !DFAS.isidenttoken(string(o)) || string(o) in v, listops())
    @test_throws ErrorException spec_vocabulary(:bogus)
end

@testset "templates and vocabulary agree on every identifier" begin
    # G5 (design/user-guidance.md): what the proactive half OFFERS, the
    # proactive half must also be able to COMPLETE. A template naming an
    # identifier absent from the vocabulary is how `orderby` went missing for
    # :aggr -- the `?` dropdown handed out text Tab could not finish.
    df = DataFrame(region = ["E", "W"], date = [Date(2026, 1, 1), Date(2026, 2, 1)],
                   sales = [1, 2], wt = [1.0, 2.0])
    for (kind, ct) in ((:aggr, df), (:aggr, nothing), (:dim, df), (:dim, nothing))
        vocab = Set(spec_vocabulary(kind))
        for t in spec_templates(kind; coltypes = ct)
            for w in eachmatch(r"[A-Za-z_][A-Za-z0-9_]*(?=\s*\()", t)
                # placeholder column names are not vocabulary; call positions are
                @test w.match in vocab
            end
        end
    end
end

@testset "specsummary / specfields" begin
    a = parseaggr("sum(_ * wt) / sum(wt)")
    @test occursin("reduce via", specsummary(a))
    @test Dict(specfields(a))["columns"] == "_, wt"

    w = parsedim("cumsum(x) |> orderby(d)")
    @test occursin("ordered by d", specsummary(w))
    @test occursin("window kind", Dict(specfields(w))["order by"])
    @test !haskey(Dict(specfields(w)), "group by")

    p = parsedim("mean(x) |> groupby(g)")
    @test occursin("pivot by g", specsummary(p))
    @test occursin("pivot kind", Dict(specfields(p))["group by"])

    # a plain dim spec is a window with nothing to report
    @test occursin("window", specsummary(parsedim("discretize(x, [0, 1])")))

    # G6: the echo must distinguish specs the ENGINE distinguishes. An aggr
    # spec's top-level orderby decides which row `first`/`last` return, so
    # dropping it would confirm back a spec the user did not type.
    ao = parseaggr("first(_) |> orderby(d)")
    @test specsummary(ao) != specsummary(parseaggr("first(_)"))
    @test occursin("ordered by d", specsummary(ao))
    @test occursin("d", Dict(specfields(ao))["order by"])
    @test !haskey(Dict(specfields(parseaggr("first(_)"))), "order by")

    # …and so does a sort DIRECTION, on both sides
    @test occursin("d => :desc", specsummary(parseaggr("last(_) |> orderby(d => :desc)")))
    @test occursin("d => :desc", specsummary(parsedim("lag(x) |> orderby(d => :desc)")))
    @test specsummary(parsedim("lag(x) |> orderby(d)")) !=
          specsummary(parsedim("lag(x) |> orderby(d => :desc)"))
end

@testset "kind must be :aggr or :dim" begin
    @test_throws ErrorException spec_templates(:bogus)
end

@testset "every offered template parses AND runs on its target column" begin
    # the placeholder names are real columns here, so each template can be
    # lifted and applied end to end -- a template that throws on the very column
    # it was suggested for is worse than no suggestion
    df = DataFrame(region = ["E", "W", "E", "W"],
                   date   = Date(2026, 1, 1):Day(1):Date(2026, 1, 4),
                   year   = [2026, 2026, 2025, 2025],
                   sales  = [10, -3, 7, 22],
                   wt     = [1.0, 2.0, 3.0, 4.0],
                   wt1    = [1.0, 0.0, 1.0, 1.0],
                   wt2    = [2.0, 2.0, 2.0, 2.0],
                   score  = Union{Missing,Float64}[1.0, missing, 3.0, missing],
                   tag    = Union{Missing,String}["a", missing, "b", "a"],
                   flag   = Union{Missing,Bool}[true, missing, false, true],
                   active = [true, false, true, true])
    cols = propertynames(df)

    for c in cols, data in (df[!, c], nothing)
        for s in spec_templates(:aggr; coltypes = df, target = c, targetdata = data)
            spec = parseaggr(s; columns = cols)
            @test spec isa SafeAggrSpec
            @test (liftAggrSpecToFunc(c, spec)(df); true)
        end
    end

    # dim templates parse, validate against the frame they were built from, and
    # RUN on it -- the derived list names that frame's real columns, so there is
    # nothing stopping the same end-to-end check the aggr loop gets. (Parsing
    # alone would miss a template that is grammatical but throws in the engine,
    # e.g. a verb/modifier pairing the kind inference rejects.)
    for s in spec_templates(:dim; coltypes = df)
        spec = parsedim(s; columns = cols)
        @test spec isa SafeDimSpec
        @test dim(df, [:out => spec]) isa AbstractDataFrame
    end
    # the no-coltypes fallback list is written against placeholder column names
    # (`name`/`profit`/`district`/`business`/`score`), so it can only be parsed
    for s in spec_templates(:dim)
        @test parsedim(s) isa SafeDimSpec
    end
end
