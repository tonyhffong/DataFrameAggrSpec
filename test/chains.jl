using DataFrameAggrSpec
using DataFrames
using Test

import DataFrameAggrSpec: normalize_chain

@testset "normalize_chain" begin
    # left context accumulates across mixed entries
    chain = [
        :County,
        :top5d => :( topnames(:District, :TestScr, 5) ),
        :District,
        :scoreq => :( discretize(:TestScr, [10.0, 20.0]) ),
    ]
    keycols, dims = normalize_chain(chain)
    @test keycols == [:County, :top5d, :District, :scoreq]
    @test length(dims) == 2

    top5d = dims[1]
    @test top5d isa PivotDim              # topnames defaults to pivot kind
    @test top5d.context == [:County]
    @test top5d.by == [:District]         # topnames name-column fixup

    scoreq = dims[2]
    @test scoreq isa WindowDim            # bare specs default to window kind
    @test scoreq.by == [:County, :top5d, :District]

    # pure-key chain declares nothing
    @test normalize_chain([:a, :b]) == ([:a, :b], DataFrameAggrSpec.AbstractDimension[])

    # nested-vector + string form (GUI/config path; strings use the safe grammar)
    keycols2, dims2 = normalize_chain(
        ["County", ["top5d", "topnames(District, TestScr, 5)"], "District"])
    @test keycols2 == [:County, :top5d, :District]
    @test dims2[1] isa PivotDim
    @test dims2[1].context == [:County]

    # sibling tuple: same context, not in each other's context
    keycols3, dims3 = normalize_chain(
        [:region, (:share => :( :sales ./ sum(:sales) ),
                   :cum => dimspec(:( cumsum(:sales) ), order = :date))])
    @test keycols3 == [:region, :share, :cum]
    @test dims3[1].by == [:region] && dims3[2].by == [:region]
    @test dims3[2].order == [:date => false]

    # dimspec: explicit kind + extra grouping keys ("addgroupby")
    keycols4, dims4 = normalize_chain(
        [:County, :size => dimspec(:( discretize(:EnrlTot, [35, 60]) ),
                                   by = :District, kind = :pivot)])
    d4 = dims4[1]
    @test d4 isa PivotDim
    @test d4.context == [:County] && d4.by == [:District]
    @test dependencies(d4) == [:EnrlTot]

    # a prebuilt dimension participates and joins the context
    w = WindowDim(:z, :( :x .- sum(:x) ), by = :g)
    keycols5, dims5 = normalize_chain([:g, w, :zbin => :( discretize(:z, [0.0]) )])
    @test keycols5 == [:g, :z, :zbin]
    @test dims5[2].by == [:g, :z]

    @test_throws ErrorException normalize_chain([1.5])
    @test_throws ErrorException dimspec(:( sum(:x) ); kind = :nope)
end

@testset "dim/dim! with chains" begin
    df = DataFrame(
        County = ["C1", "C1", "C1", "C1", "C2", "C2"],
        District = ["d1", "d1", "d2", "d3", "d4", "d5"],
        TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
        EnrlTot = [100, 100, 50, 30, 80, 20],
    )

    # chain with a pivot dim scoped by left context, then a window dim under it
    df2 = dim(df, [:County,
                   :top1 => :( topnames(:District, :TestScr, 1) ),
                   :dshare => :( :EnrlTot ./ sum(:EnrlTot) )])
    # per County: C1 top1 = d2 (50); C2 top1 = d4 (40)
    @test df2.top1 == ["Others", "Others", "1. d2", "Others", "1. d4", "Others"]
    # dshare partitions by [:County, :top1]: C1-Others = rows 1,2,4 (enrl 100+100+30)
    @test df2.dshare[1] ≈ 100 / 230
    @test df2.dshare[3] == 1.0

    # a bare pair works as a one-dimension chain
    df3 = dim(df, :ctot => :( sum(:EnrlTot) ))
    @test df3.ctot == fill(380, 6)

    # a chain that declares nothing is an error for dim!
    @test_throws ErrorException dim(df, [:County, :District])

    # string chain end-to-end
    df4 = dim(df, ["County", ["top1", "topnames(District, TestScr, 1)"]])
    @test string.(df4.top1) == string.(df2.top1)
end

@testset "interlacing trusted and untrusted dims in one chain" begin
    df = DataFrame(
        County = ["C1", "C1", "C1", "C1", "C2", "C2"],
        District = ["d1", "d1", "d2", "d3", "d4", "d5"],
        TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
        EnrlTot = [100, 100, 50, 30, 80, 20],
    )

    # a safe (user-typed) pivot dim, then a sibling tuple mixing a trusted Expr
    # window dim with a safe+ordered one -- all under the same left context
    chain = [:County,
             :top1 => dim"topnames(District, TestScr, 1)",
             (:share => :( :TestScr ./ sum(:TestScr) ),
              :cum   => dimspec(dim"cumsum(EnrlTot)"; order = :TestScr))]

    keycols, dims = normalize_chain(chain)
    @test keycols == [:County, :top1, :share, :cum]
    @test dims[1] isa PivotDim && dims[1].spec isa SafeDimSpec
    @test dims[2] isa WindowDim && dims[2].spec isa Expr
    @test dims[3] isa WindowDim && dims[3].spec isa SafeDimSpec
    # siblings share the context without scoping each other
    @test dims[2].by == [:County, :top1]
    @test dims[3].by == [:County, :top1]

    dfm = dim(df, chain)
    # partitions by (County, top1): C1-Others = rows 1,2,4 ; singletons elsewhere
    @test dfm.share ≈ [10 / 60, 20 / 60, 1.0, 30 / 60, 1.0, 1.0]
    @test dfm.cum == [100, 200, 50, 230, 80, 20]

    # pivottable over a mixed chain: trusted flag under a safe pivot key
    out = pivottable(df, [:County,
                          :top1 => dim"topnames(District, TestScr, 1)",
                          :flag => :( :TestScr .> 25.0 )];
                     hints = AggrHints(:TestScr => :sum))
    @test nrow(out) == 5
    c1of = out[(out.County .== "C1") .& (string.(out.top1) .== "Others") .&
               .!out.flag, :]
    @test c1of.TestScr == [30.0]   # rows 1,2 (TestScr 10 + 20)
end
