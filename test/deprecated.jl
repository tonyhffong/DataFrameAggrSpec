using DataFrameAggrSpec
using DataFrames
using CategoricalArrays
using Test

import DataFrameAggrSpec: CalcPivotAggrDepCache, CalcPivotFuncCache
import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

depdf() = DataFrame(
    County = ["C1", "C1", "C1", "C1", "C2", "C2"],
    District = ["d1", "d1", "d2", "d3", "d4", "d5"],
    TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
    EnrlTot = [100, 100, 50, 30, 80, 20],
)

@testset "CalcPivot construction (legacy)" begin
    cp = CalcPivot("topnames(:District, :TestScr, 5)")
    @test cp.spec == :( topnames(:District, :TestScr, 5) )
    @test cp.by == [:District]                    # name column auto-added
    cp2 = CalcPivot(:( discretize(:TestScr, [15.0]) ), :County)
    @test cp2.by == [:County]
    @test_throws ErrorException CalcPivot(:( push!(:a, 1) ))
end

@testset "liftCalcPivotToFunc legacy contract" begin
    df = depdf()

    # non-empty by: per-group frame with by cols + result column, dep cache populated
    spec = :( topnames(:District, :TestScr, 2) )
    f = liftCalcPivotToFunc(spec, [:District])
    @test CalcPivotAggrDepCache[(spec, [:District])] == [:TestScr]
    @test liftCalcPivotToFunc(spec, [:District]) === f    # cache hit

    ret = Base.invokelatest(f, df, :top2; TestScr = :sum)
    @test names(ret) == ["District", "top2"]
    @test nrow(ret) == 5
    joined = leftjoin(df, ret, on = :District)
    @test string.(joined.top2) ==
          ["Others", "Others", "1. d2", "Others", "2. d4", "Others"]

    # missing aggregation kwarg throws, as it always did
    @test_throws KeyError Base.invokelatest(f, df, :top2)

    # a by column the spec never references still lands in the output frame
    spec2 = :( discretize(:EnrlTot, [35, 60]) )
    f2 = liftCalcPivotToFunc(spec2, [:District])
    ret2 = Base.invokelatest(f2, df, :size; EnrlTot = :sum)
    @test names(ret2) == ["District", "size"]
    @test string(ret2.size[ret2.District .== "d2"][1]) == "2. 35…59"

    # empty by: row-aligned vector, caller creates the column
    spec3 = :( discretize(:TestScr, [15.0, 35.0]) )
    f3 = liftCalcPivotToFunc(spec3, Symbol[])
    v = Base.invokelatest(f3, df)
    @test length(v) == nrow(df)
    @test CalcPivotAggrDepCache[(spec3, Symbol[])] == Symbol[]
end

@testset "^ escaping in specs" begin
    df = depdf()
    # ^(:sym) keeps :sym a plain Symbol (kwarg value), not a column reference
    spec = :( discretize(:EnrlTot, [35]; boundedness = ^(:boundedbelow)) )
    d = PivotDim(:bucket, spec; by = :District)
    @test dependencies(d) == [:EnrlTot]
    df2 = dim(df, [d])
    # district EnrlTot sums: d1=200 d2=50 d3=30 d4=80 d5=20; below 35 -> missing
    @test string(df2.bucket[1]) == "1. 35+"
    @test ismissing(df2.bucket[4])

    # same spec through the legacy path
    f = liftCalcPivotToFunc(spec, [:District])
    ret = Base.invokelatest(f, df, :bucket; EnrlTot = :sum)
    @test string(ret.bucket[ret.District .== "d1"][1]) == "1. 35+"
end
