using DataFrameAggrSpec
using DataFrames
using CategoricalArrays
using Dates
using Test

import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

# County C1: districts d1 (2 rows), d2, d3 ; County C2: d4, d5
pddf() = DataFrame(
    County = ["C1", "C1", "C1", "C1", "C2", "C2"],
    District = ["d1", "d1", "d2", "d3", "d4", "d5"],
    TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
    EnrlTot = [100, 100, 50, 30, 80, 20],
)

@testset "PivotDim construction" begin
    d = PivotDim(:top2, :( topnames(:District, :TestScr, 2) ))
    @test d.by == [:District]                 # topnames name column auto-added
    @test dependencies(d) == [:TestScr]

    d2 = PivotDim(:sz, "discretize(EnrlTot, [35, 60])", by = :District, context = :County)
    @test d2.by == [:District]
    @test d2.context == [:County]
    @test dependencies(d2) == [:EnrlTot]

    @test_throws ErrorException PivotDim(:bad, :( discretize(:EnrlTot, [35]) ))

    # group ordering (0.8.4): in-string orderby lands in `order`, its columns
    # join the dependencies
    d3 = PivotDim(:p, "cumsum(TestScr) |> groupby(District) |> orderby(TestScr => :desc)")
    @test d3.by == [:District]
    @test d3.order == [:TestScr => true]
    @test dependencies(d3) == [:TestScr]
end

@testset "PivotDim evaluation" begin
    df = pddf()

    # classify districts by their summed TestScr, whole frame (no context)
    # district sums: d1=30, d2=50, d3=30, d4=40, d5=10 -> top2: d2, d4
    df2 = dim(df, [PivotDim(:top2, :( topnames(:District, :TestScr, 2) ))])
    @test df2.top2 == ["Others", "Others", "1. d2", "Others", "2. d4", "Others"]
    @test df2.top2 isa CategoricalArray

    # same classification per County (context partitioning)
    # C1: d2=50 -> 1, d1=30 & d3=30 tie -> both 2 ; C2: d4 -> 1, d5 -> 2
    df3 = dim(df, [PivotDim(:ctop, :( topnames(:District, :TestScr, 2) ),
                            context = :County)])
    @test df3.ctop == ["2. d1", "2. d1", "1. d2", "2. d3", "1. d4", "2. d5"]
    @test df3.ctop isa CategoricalArray
    @test issorted(unique(sort(df3.ctop)))    # rank prefixes keep lexical order sane

    # discretize over group aggregates (EnrlTot sums: d1=200, d2=50, d3=30, d4=80, d5=20)
    df4 = dim(df, [PivotDim(:size, :( discretize(:EnrlTot, [35, 60]) ), by = :District)])
    @test df4.size == ["3. 60+", "3. 60+", "2. 35…59", "1. ≤34", "3. 60+", "1. ≤34"]

    # hints drive the dependency aggregation: mean instead of default sum
    # district means: d1=15, d2=50, d3=30, d4=40, d5=10 -> top2: d2, d4
    df5 = dim(df, [PivotDim(:top2m, :( topnames(:District, :TestScr, 2) ))];
              hints = AggrHints(:TestScr => :( sum(:_) / length(:_) )))
    @test df5.top2m == ["Others", "Others", "1. d2", "Others", "2. d4", "Others"]
end

@testset "classifier composability over categorical columns" begin
    # categorical source column (what CSV.read(...; pool=true) produces)
    df = pddf()
    df.District = categorical(df.District)
    df2 = dim(df, [:top2 => dim"topnames(District, TestScr, 2)"])
    @test df2.top2 == ["Others", "Others", "1. d2", "Others", "2. d4", "Others"]

    # classifier over a classifier's output: PivotDim labels are categorical,
    # and must feed a later topnames as its name column
    dfa = dim(pddf(), [:ctop => dim"topnames(County, TestScr, 2)"])
    @test dfa.ctop isa CategoricalArray                # the composability hazard
    dfb = dim(dfa, [:cc => dim"topnames(ctop, TestScr, 1)"])
    # ctop group sums: "1. C1" = 110, "2. C2" = 50 -> top1 is "1. C1"
    @test dfb.cc ==
          ["1. 1. C1", "1. 1. C1", "1. 1. C1", "1. 1. C1", "Others", "Others"]
end

@testset "groupby modifier with a computed key composes with orderby (finding #3)" begin
    # cumsum |> groupby(computed) |> orderby(dep) -- the Pareto idiom, but
    # grouping on yyyymm(date) instead of an existing column. Confirms the
    # gensym-materialized grouping path composes correctly with pivot
    # `orderby`'s group-level sort + inverse-perm scatter-back.
    df = DataFrame(
        date  = Date.(2024, [1, 1, 2, 2, 3], 1),
        sales = [10.0, 20.0, 5.0, 15.0, 100.0],
    )
    out = dim(df, [:cum => dim"cumsum(sales) |> groupby(yyyymm(date)) |> orderby(sales => :desc)"])
    # bucket sums: 202401=30, 202402=20, 202403=100 -> desc order 202403,202401,202402
    # cumsum over that order: 202403->100, 202401->130, 202402->150
    @test out.cum == [130.0, 130.0, 150.0, 150.0, 100.0]
end

@testset "dependency aggregation on a Union{Missing,T} measure column" begin
    # PivotDim's dependency aggregation goes through resolveaggr exactly like
    # agg does. TestScr here has the ordinary eltype a column gets once it's
    # ever held a missing (no actual missing values needed to trigger the
    # bug -- every district has two DISTINCT values, which is enough for the
    # old :uniqvalue mis-dispatch to collapse every district to missing).
    # Before the fix this didn't just misrank -- topnames crashed with
    # `UndefVarError: T not defined in static parameter matching`, because
    # its `where T<:Real` signature can't bind T against an all-Missing
    # vector.
    df = DataFrame(
        County   = ["C1", "C1", "C1", "C1", "C2", "C2", "C2", "C2"],
        District = ["d1", "d1", "d2", "d2", "d3", "d3", "d4", "d4"],
        TestScr  = Union{Missing,Float64}[10.0, 20.0, 50.0, 55.0, 30.0, 35.0, 40.0, 45.0],
    )
    out = dim(df, [:top2 => dim"topnames(District, TestScr, 2)"])
    # district sums: d1=30, d2=105, d3=65, d4=85 -> top2: d2, d4
    @test out.top2 ==
          ["Others", "Others", "1. d2", "1. d2", "Others", "Others", "2. d4", "2. d4"]
end
