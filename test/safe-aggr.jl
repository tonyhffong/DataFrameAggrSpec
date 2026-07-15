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
