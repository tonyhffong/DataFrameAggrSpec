using DataFrameAggrSpec
using DataFrames
using CategoricalArrays
using Test

import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

# Per-operator tests for SAFE DIMENSION operators, mirroring
# docs/safe-dimension-operators.md. When a new dimension operator is added to
# the SafeOps registry, its tests belong here; the DSL machinery itself
# (grammar, rejections, integration, caching) is covered in test/safe.jl.

sddf() = DataFrame(
    County = ["C1", "C1", "C1", "C1", "C2", "C2"],
    District = ["d1", "d1", "d2", "d3", "d4", "d5"],
    TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
    EnrlTot = [100, 100, 50, 30, 80, 20],
)

@testset "group-relative and elementwise operators" begin
    @test dim"sales / sum(sales)".f([1.0, 3.0]) == [0.25, 0.75]   # share of group
    @test dim"sum(sales)".f([1.0, 3.0]) == 4.0                    # broadcast group total
    @test dim"cumsum(sales)".f([1, 2, 3]) == [1, 3, 6]
    @test dim"cumprod(g)".f([2, 3]) == [2, 6]
    @test isequal(dim"lag(x)".f([1, 2, 3]), [missing, 1, 2])
    @test isequal(dim"lead(x, 2)".f([1, 2, 3]), [3, missing, missing])
    @test dim"round(sales / sum(sales), digits = 2)".f([1.0, 2.0]) == [0.33, 0.67]
    @test dim"sales > mean(sales)".f([1.0, 3.0]) == [false, true]  # above-average flag
    @test dim"max(sales, 0)".f([-1.0, 2.0]) == [0.0, 2.0]          # elementwise clamp
end

@testset "discretize" begin
    q1 = dim"discretize(TestScr, quantiles=[.25,.5,.75])"
    q2 = dim"discretize(TestScr; quantiles=[.25,.5,.75])"
    @test q1.cols == [:TestScr] && q2.cols == [:TestScr]
    v = [1.0, 2.0, 3.0, 4.0]
    @test string.(q1.f(v)) == string.(q2.f(v))
    b = dim"discretize(x, [0, 10], boundedness = :boundedbelow)"
    @test string(b.f([5.0])[1]) == "1. [0,10)"
end

@testset "topnames" begin
    t = dim"topnames(District, TestScr, 5)"
    labels = t.f(["a", "b", "c"], [30.0, 10.0, 20.0])
    @test string.(labels) == ["1. a", "3. b", "2. c"]
    @test labels isa CategoricalArray

    # pivot-kind end-to-end within a chain (context = left of the chain)
    df = sddf()
    out = dim(df, [:County, :top1 => dim"topnames(District, TestScr, 1)"])
    @test string.(out.top1) == ["Others", "Others", "1. d2", "Others", "1. d4", "Others"]
end

@testset "quantiles" begin
    # verb semantics: label each element by its quantile bucket
    v = [1.0, 2.0, 3.0, 4.0]
    q = quantiles(v, [0.25, 0.5, 0.75], nothing)
    @test string.(q) == ["1. [0%, 25%)", "2. [25%, 50%)", "3. [50%, 75%)", "4. [75%, 100%]"]
    @test q isa CategoricalArrays.CategoricalArray

    # leftequal = false flips the interval closure
    q2 = quantiles(v, [0.25, 0.5, 0.75], nothing; leftequal = false)
    @test string(q2[1]) == "1. [0%, 25%]"
    @test string(q2[2]) == "2. (25%, 50%]"

    # prefix / suffix decorate the interval
    @test string(quantiles(v, [0.5], nothing; prefix = "scr")[1]) == "1. scr [0%, 50%)"
    @test string(quantiles(v, [0.5], nothing; suffix = "tile")[4]) == "2. [50%, 100%] tile"

    # non-integer percent boundary, missing passthrough
    @test string(quantiles(v, [0.125], nothing)[4]) == "2. [12.5%, 100%]"
    @test ismissing(quantiles([1.0, missing, 3.0], [0.5], nothing)[2])

    # validation
    @test_throws ErrorException quantiles(v, [0.5, 0.25], nothing)
    @test_throws ErrorException quantiles(v, [0.0, 0.5], nothing)
    @test_throws ErrorException quantiles(v, Float64[], nothing)

    # untrusted DSL: pivot kind inferred, 3rd-argument columns folded into `by`
    df = sddf()
    s = dim"quantiles(TestScr, [.25,.5,.75], [District])"
    @test s.posargs[3] == [:District]
    d = PivotDim(:qd, s)
    @test d.by == [:District]
    @test dependencies(d) == [:TestScr]

    # whole-frame: district TestScr sums [d1=30, d2=50, d3=30, d4=40, d5=10]
    out = dim(df, [d])
    @test string.(out.qd) == ["3. [50%, 75%)", "3. [50%, 75%)", "4. [75%, 100%]",
                              "3. [50%, 75%)", "4. [75%, 100%]", "1. [0%, 25%)"]

    # trusted Expr form takes the same fixup path
    d2 = PivotDim(:qd, :( quantiles(:TestScr, [.25, .5, .75], [:District]) ))
    @test d2.by == [:District]
    @test isequal(string.(dim(df, [d2]).qd), string.(out.qd))

    # in a chain: pivot kind + left context
    keycols, dims = DataFrameAggrSpec.normalize_chain(
        [:County, :qd => dim"quantiles(TestScr, [.5], [District])"])
    @test dims[1] isa PivotDim
    @test dims[1].by == [:District] && dims[1].context == [:County]

    # malformed 3rd argument
    @test_throws ErrorException PivotDim(:bad, dim"quantiles(TestScr, [.5], District)")
end

@testset "orderby modifier (behavior)" begin
    df = DataFrame(region = ["E", "E", "W", "W", "W"],
                   date   = [1, 2, 1, 2, 3],
                   sales  = [10.0, 20.0, 5.0, 15.0, 30.0])

    # in-string orderby ≡ dimspec(...; order = ...)
    a = dim(df, [:region, :cum => dim"cumsum(sales) |> orderby(date)"])
    b = dim(df, [:region, :cum => dimspec(dim"cumsum(sales)"; order = :date)])
    @test a.cum == b.cum == [10.0, 30.0, 5.0, 20.0, 50.0]

    # ∘ spelling + descending direction
    c = dim(df, [:region, :cum2 => dim"cumsum(sales) ∘ orderby(date => :desc)"])
    @test c.cum2 == [30.0, 20.0, 50.0, 45.0, 30.0]

    # THE motivating case: ordering expressible from a pure-string config chain
    d = dim(df, ["region", ["cum", "cumsum(sales) |> orderby(date)"]])
    @test d.cum == a.cum

    # conflict between in-string orderby and dimspec order is an error
    @test_throws ErrorException dim(df, [:region,
        :x => dimspec(dim"cumsum(sales) |> orderby(date)"; order = :sales)])

    # pivot kind rejects orderby (classifies group aggregates; nothing to sort)
    @test_throws ErrorException DataFrameAggrSpec.normalize_chain(
        [:bad => dim"topnames(region, sales, 2) |> orderby(date)"])

    # the orderby columns count as dependencies
    (_, dims) = DataFrameAggrSpec.normalize_chain(
        [:region, :cum => dim"cumsum(sales) |> orderby(date)"])
    @test dependencies(dims[1]) == [:sales, :date]
end

@testset "quantiles with empty grouping = row-level window" begin
    # an empty (or omitted) 3rd argument ranks rows INDIVIDUALLY into buckets
    df0 = DataFrame(x = [1.0, 2.0, 3.0, 4.0])
    out = dim(df0, :q => dim"quantiles(x, [.25,.5,.75], [])")
    @test string.(out.q) ==
          ["1. [0%, 25%)", "2. [25%, 50%)", "3. [50%, 75%)", "4. [75%, 100%]"]

    # omitted 3rd argument behaves the same
    out2 = dim(df0, :q => dim"quantiles(x, [.25,.5,.75])")
    @test string.(out2.q) == string.(out.q)

    # kind inference: window, partitioned by the chain's left context
    keycols, dims = DataFrameAggrSpec.normalize_chain(
        [:County, :rq => dim"quantiles(TestScr, [.5], [])"])
    @test dims[1] isa WindowDim
    @test dims[1].by == [:County]

    # per-county row bucketing: C1 scores [10,20,50,30] (median 25),
    # C2 scores [40,10] (median 25)
    df = sddf()
    out3 = dim(df, [:County, :rq => dim"quantiles(TestScr, [.5], [])"])
    @test string.(out3.rq) == ["1. [0%, 50%)", "1. [0%, 50%)", "2. [50%, 100%]",
                               "2. [50%, 100%]", "2. [50%, 100%]", "1. [0%, 50%)"]

    # trusted Expr form infers window kind the same way
    keycols2, dims2 = DataFrameAggrSpec.normalize_chain(
        [:County, :rq => :( quantiles(:TestScr, [.5], []) )])
    @test dims2[1] isa WindowDim && dims2[1].by == [:County]

    # a present-but-malformed 3rd argument still errors (pivot intent assumed)
    @test_throws ErrorException DataFrameAggrSpec.normalize_chain(
        [:bad => dim"quantiles(TestScr, [.5], District)"])
end
