using DataFrameAggrSpec
using DataFrames
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
