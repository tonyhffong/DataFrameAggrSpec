using DataFrameAggrSpec
using DataFrames
using Dates
using Statistics
using Test

# Per-operator tests for SAFE AGGREGATION operators, mirroring
# docs/safe-aggregation-operators.md. When a new aggregation operator is added
# to the SafeOps registry, its tests belong here; the DSL machinery itself
# (grammar, rejections, integration, caching) is covered in test/safe.jl.

@testset "reduction operators" begin
    v = [4.0, 1.0, 3.0, 2.0]
    @test aggr"sum".f(v) == 10.0
    @test aggr"prod(_)".f([2, 3]) == 6
    @test aggr"mean(_)".f(v) == 2.5
    @test aggr"median(_)".f(v) == 2.5
    @test aggr"std(_)".f(v) == Statistics.std(v)
    @test aggr"var(_)".f(v) == Statistics.var(v)
    @test aggr"quantile(_, 0.75)".f(v) == Statistics.quantile(v, 0.75)
    @test aggr"minimum(_)".f(v) == 1.0
    @test aggr"maximum(_)".f(v) == 4.0
    @test aggr"extrema(_)".f(v) == (1.0, 4.0)
    @test aggr"length(_)".f(v) == 4
    @test aggr"nrow".f(v) == 4
    @test aggr"count(_ > 2)".f(v) == 2
    @test aggr"first(_)".f(v) == 4.0
    @test aggr"last(_)".f(v) == 2.0
    @test aggr"sum(skipmissing(_))".f([1, missing, 2]) == 3
    @test aggr"uniqvalue(_)".f(["a", "a"]) == "a"
    @test ismissing(aggr"uniqvalue(_)".f(["a", "b"]))
    @test sort(aggr"unionall(_)".f([[1, 2], [2, 3]])) == [1, 2, 3]
end

@testset "arithmetic combinations" begin
    x = [1.0, 2.0, 3.0]
    w = [10.0, 20.0, 30.0]
    @test aggr"sum(_ * wt) / sum(wt)".f(x, w) ≈ sum(x .* w) / sum(w)  # weighted mean
    @test aggr"maximum(_) - minimum(_)".f(x) == 2.0                   # range
    @test aggr"count(_ > 100) / length(_)".f([50.0, 150.0]) == 0.5    # fraction above
    @test aggr"sum(abs(_))".f([-1.0, 2.0]) == 3.0                     # L1 mass
    @test aggr"std(_) / mean(_)".f(x) == Statistics.std(x) / 2.0      # coeff. of variation
end

@testset "ismissing / coalesce (aggregation side)" begin
    # replace: elementwise coalesce before reducing (vs skipmissing = drop)
    @test aggr"sum(coalesce(_, 0))".f([1.0, missing, 2.0]) == 3.0
    # flag: missing-count as a measure
    @test aggr"count(ismissing(_))".f([1, missing, missing]) == 2
    # scalar broadcast: patch the missing that uniqvalue returns on mixed groups
    @test aggr"coalesce(uniqvalue(_), \"mixed\")".f(["a", "b"]) == "mixed"
    @test aggr"coalesce(uniqvalue(_), \"mixed\")".f(["a", "a"]) == "a"
end

@testset "countuniq" begin
    # verb semantics: count-distinct, uniqvalue's kwargs
    @test countuniq([1, 2, 2, 3]) == 3
    @test countuniq(["a", "b", "a"]) == 2
    @test countuniq([1, missing, 1]) == 1                  # skipna default
    @test countuniq([1, missing, 1]; skipna = false) == 2  # missing counts as a value
    @test countuniq(String[]) == 0
    @test countuniq(["a", "", "b"]; skipempty = true) == 2

    # through the untrusted DSL, bare-name form included
    @test aggr"countuniq(_)".f(["a", "b", "a"]) == 2
    @test aggr"countuniq".f([1, 1, 2]) == 2

    # count distinct districts per county, as a hints spec
    df = DataFrame(County = ["C1", "C1", "C1", "C2"],
                   District = ["d1", "d1", "d2", "d3"])
    out = agg(df, :County; hints = AggrHints(:District => aggr"countuniq"))
    @test out.District == [2, 1]
end

@testset "Boolean measures (&&, ||, where)" begin
    # a Bool-valued measure from compound reductions -- top-level && is legal
    @test aggr"sum(_) > 100 && length(_) > 2".f([50.0, 60.0, 70.0]) == true
    @test aggr"sum(_) > 100 && length(_) > 2".f([200.0]) == false

    # where as a group-level flag measure, label = the condition text
    @test aggr"where(sum(_) > 100)".f([60.0, 70.0]) == "sum(_) > 100"
    @test aggr"where(sum(_) > 100, true_label = \"big\")".f([1.0]) == "Not big"

    # in a grouped aggregation: group sums x=3, y=7
    df = DataFrame(g = ["x", "x", "y"], v = [1.0, 2.0, 7.0])
    out = agg(df, :g; hints = AggrHints(:v => aggr"where(sum(_) > 5)"),
              cols = [:v => aggr"where(sum(_) > 5)" => :big])
    @test out.big == ["Not sum(_) > 5", "sum(_) > 5"]
end

@testset "composite aggregation (nested groupby)" begin
    # panel: district populations, snapshots over years; yearly sums 30, 30, 30
    pop  = [10.0, 20.0, 5.0, 25.0, 8.0, 22.0]
    year = [2020, 2020, 2021, 2021, 2022, 2022]
    @test aggr"mean(sum(_) |> groupby(year))".f(pop, year) == 30.0
    @test aggr"mean(sum(_) ∘ groupby(year))".f(pop, year) == 30.0  # glyph twin
    @test aggr"length(sum(_) |> groupby(year))".f(pop, year) == 3  # n subgroups

    # subgroups are sorted by key: first/last = earliest/latest year,
    # regardless of row order
    v  = [30.0, 2.0, 1.0]
    yr = [2022, 2020, 2021]
    @test aggr"first(sum(_) |> groupby(year))".f(v, yr) == 2.0     # 2020
    @test aggr"last(sum(_) |> groupby(year))".f(v, yr) == 30.0     # 2022
    @test aggr"maximum(sum(_) |> groupby(year))".f(v, yr) == 30.0

    # the inner spec is a full spec: weighted mean per year, then spread
    w = [1.0, 3.0, 1.0, 1.0, 2.0, 2.0]
    wm(x, ww) = sum(x .* ww) / sum(ww)
    expected = [wm(pop[1:2], w[1:2]), wm(pop[3:4], w[3:4]), wm(pop[5:6], w[5:6])]
    @test aggr"maximum(sum(_ * w) / sum(w) |> groupby(year))".f(pop, w, year) ≈
          maximum(expected)

    # multi-key: state x year, both spellings
    st = ["a", "a", "a", "b", "b", "b"]
    y2 = [2020, 2020, 2021, 2020, 2021, 2021]
    @test aggr"length(sum(_) |> groupby(state, year))".f(pop, st, y2) == 4
    @test aggr"length(sum(_) |> groupby([state, year]))".f(pop, st, y2) == 4

    # computed key: bucket a raw date column by calendar year on the fly
    t = [Date(2020, 1, 1), Date(2020, 6, 1), Date(2021, 3, 1)]
    x = [1.0, 2.0, 4.0]
    @test aggr"mean(sum(_) |> groupby(yyyy(t)))".f(x, t) == (3.0 + 4.0) / 2

    # missing key forms its own subgroup (sorted last)
    ym = [2020, 2020, missing]
    @test aggr"length(sum(_) |> groupby(year))".f(x, ym) == 2
    @test aggr"last(sum(_) |> groupby(year))".f(x, ym) == 4.0      # the missing group

    # stages nest: mean county total per year, then max across years
    cty = ["c1", "c1", "c2", "c1", "c2", "c2"]
    y3  = [2020, 2020, 2020, 2021, 2021, 2021]
    p3  = [1.0, 2.0, 9.0, 4.0, 3.0, 3.0]
    # 2020: county totals 3, 9 -> mean 6;  2021: totals 4, 6 -> mean 5
    @test aggr"maximum(mean(sum(_) |> groupby(county)) |> groupby(year))".f(
        p3, cty, y3) == 6.0

    # end-to-end through agg: average yearly total per county
    df = DataFrame(
        county = ["c1", "c1", "c1", "c2", "c2"],
        year   = [2020, 2020, 2021, 2020, 2021],
        pop    = [10.0, 20.0, 40.0, 5.0, 15.0],
    )
    out = agg(df, :county;
              hints = AggrHints(:pop => aggr"mean(sum(_) |> groupby(year))"),
              cols = [:pop])
    @test out.pop == [35.0, 10.0]   # c1: (30 + 40)/2;  c2: (5 + 15)/2

    # column bookkeeping: nested keys are real column references
    s = aggr"mean(sum(_) |> groupby(year))"
    @test s.cols == [:_, :year]                       # source order
    @test checkcols(s, [:pop, :year]) === s
    @test_throws ErrorException checkcols(s, [:pop])  # year missing

    # mixed key types cannot sort: a curated error, not a raw MethodError
    err = try
        aggr"mean(sum(_) |> groupby(k))".f([1.0, 2.0, 3.0], Any[1, "a", 2])
        nothing
    catch e
        e
    end
    @test err isa ErrorException && occursin("mutually comparable", err.msg)
end

@testset "wmeanfallback" begin
    x  = [1.0, 2.0, 3.0]
    z  = [0.0, 0.0, 0.0]      # sums to zero -- unusable
    m  = [10.0, missing, 30.0]  # sum is missing -- unusable, but must not crash
    sz = [10.0, 20.0, 30.0]

    # verb semantics: direct calls
    @test wmeanfallback(x, [sz]) ≈ sum(x .* sz) / sum(sz)
    @test wmeanfallback(x, [z, sz]) ≈ sum(x .* sz) / sum(sz)   # first fails, second wins
    @test wmeanfallback(x, [m, sz]) ≈ sum(x .* sz) / sum(sz)   # missing weight-sum skipped too
    @test wmeanfallback(x, [z, 1]) ≈ sum(x) / length(x)        # literal weight = unweighted mean
    @test ismissing(wmeanfallback(x, [z]))                     # every candidate fails
    @test_throws ErrorException wmeanfallback(x, Float64[])    # no candidates at all

    # through the untrusted DSL, first-encounter arg order: _, z, sz
    @test aggr"wmeanfallback(_, [z, sz])".f(x, z, sz) ≈ sum(x .* sz) / sum(sz)
    @test ismissing(aggr"wmeanfallback(_, [z])".f(x, z))

    # as a grouped hints spec
    df = DataFrame(
        g = ["a", "a", "b", "b"],
        v = [1.0, 2.0, 10.0, 20.0],
        Size = [0.0, 0.0, 1.0, 3.0],
        Suitability = [2.0, 4.0, 5.0, 5.0],
    )
    spec = aggr"wmeanfallback(_, [Size, Suitability, 1])"
    out = agg(df, :g; hints = AggrHints(:v => spec))
    @test out.v[1] ≈ (2 * 1.0 + 4 * 2.0) / (2 + 4)     # group a: Size sums to 0, falls to Suitability
    @test out.v[2] ≈ (1 * 10.0 + 3 * 20.0) / (1 + 3)   # group b: Size usable
end

@testset "strjoinuniq" begin
    # verb semantics: unique, non-missing, stringified, sorted, joined, capped
    @test strjoinuniq(["b", "a", "b", missing]) == "a,b"
    @test strjoinuniq([2, 1, 2]) == "1,2"
    @test strjoinuniq(["b", "a"], "; ") == "a; b"
    @test strjoinuniq(Union{String,Missing}[missing, missing]) == ""
    long = strjoinuniq(["district" * string(i) for i = 1:50], ",", 20)
    @test length(long) == 20 && endswith(long, "…")
    @test strjoinuniq(["abc"], ",", 3) == "abc"          # exactly at the limit

    # through the untrusted DSL, defaults and explicit args
    @test aggr"strjoinuniq(_)".f(["b", "a", "b"]) == "a,b"
    s = parseaggr("strjoinuniq(_, \"; \", 5)")
    @test s.f(["bb", "aa", "cc"]) == "aa; …"

    # as an AggrHints spec in a grouped aggregation
    df = DataFrame(g = ["x", "x", "y"], name = ["b", "a", "c"])
    out = agg(df, :g; hints = AggrHints(:name => aggr"strjoinuniq(_)"))
    @test out.name == ["a,b", "c"]
end
