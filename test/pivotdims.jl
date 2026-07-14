using DataFrameAggrSpec
using DataFrames
using CategoricalArrays
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
