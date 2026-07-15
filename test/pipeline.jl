using DataFrameAggrSpec
using DataFrames
using StatsBase
using Test

pldf() = DataFrame(
    County = ["C1", "C1", "C1", "C1", "C2", "C2"],
    District = ["d1", "d1", "d2", "d3", "d4", "d5"],
    TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
    EnrlTot = [100, 100, 50, 30, 80, 20],
)

@testset "agg eager" begin
    df = pldf()
    chain = [:County, :top1 => :( topnames(:District, :TestScr, 1) )]
    out = agg(df, chain)

    @test names(out)[1:2] == ["County", "top1"]
    @test nrow(out) == 4    # (C1,Others) (C1,"1. d2") (C2,"1. d4") (C2,Others)
    c1others = out[(out.County .== "C1") .& (string.(out.top1) .== "Others"), :]
    @test c1others.TestScr == [60.0]        # default Real aggregation = :sum
    @test c1others.EnrlTot == [230]
    @test ismissing(c1others.District[1])   # d1,d1,d3 -> uniqvalue -> missing
    c1top = out[(out.County .== "C1") .& (string.(out.top1) .== "1. d2"), :]
    @test c1top.District == ["d2"]

    # pure-key chain = plain hints-driven groupby/agg
    out2 = agg(df, [:County];
                      hints = AggrHints(:TestScr =>
                          :( StatsBase.mean(:_, StatsBase.Weights(:EnrlTot)) )))
    c1 = out2[out2.County .== "C1", :]
    @test c1.TestScr ≈ [StatsBase.mean([10.0, 20.0, 50.0, 30.0],
                                       StatsBase.Weights([100, 100, 50, 30]))]

    # single-Symbol key convenience
    @test agg(df, :County).EnrlTot == [280, 100]
end

@testset "curried transforms + composition" begin
    df = pldf()
    chain = [:County, :top1 => :( topnames(:District, :TestScr, 1) )]

    # |> pipeline
    out = df |> agg(chain)
    @test isequal(out, agg(df, chain))

    # dim transform then pivot transform (etot: per-County enrollment total,
    # constant within group, carried through aggregation via :uniqvalue)
    h = AggrHints(:etot => :uniqvalue)
    out2 = df |> dim([:County, :etot => :( sum(:EnrlTot) )]) |> agg([:County]; hints = h)
    @test out2.etot == [280, 100]

    # ∘ composition of transforms (right-to-left)
    t = agg([:County]; hints = h) ∘ dim([:County, :etot => :( sum(:EnrlTot) )])
    @test isequal(t(df), out2)

    # single-pair transform applied via |>
    @test (df |> dim(:etot => :( sum(:EnrlTot) ))).etot == fill(380, 6)

    # transform reuse across frames
    tt = dim([:County, :cshare => :( :EnrlTot ./ sum(:EnrlTot) )])
    a = tt(df)
    b = tt(df[1:4, :])   # C1 rows only; same County total 280
    @test a.cshare[1] ≈ 100 / 280
    @test b.cshare[1] ≈ 100 / 280

    # SubDataFrame input
    sub = view(df, df.County .== "C1", :)
    outsub = sub |> agg([:District])
    @test nrow(outsub) == 3
end
