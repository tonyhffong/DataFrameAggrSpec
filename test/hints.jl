using DataFrameAggrSpec
using DataFrames
using Test

@testset "AggrHints resolution" begin
    h = AggrHints(:score => :( mean(:_) ), AbstractString => :uniqvalue)
    # column hint wins
    @test resolveaggr(h, :score, Float64) == :( mean(:_) )
    # eltype hint next (subtype match)
    @test resolveaggr(h, :city, String) == :uniqvalue
    # default last
    @test resolveaggr(h, :qty, Int) == :sum
    @test resolveaggr(h, :tags, Vector{String}) == :unionall
    @test resolveaggr(h, :misc, Any) == :uniqvalue

    # first matching Type entry wins (insertion order)
    h2 = AggrHints(Integer => :maximum, Real => :sum)
    @test resolveaggr(h2, :n, Int) == :maximum
    @test resolveaggr(h2, :x, Float64) == :sum

    # custom default
    h3 = AggrHints(; default = _ -> :maximum)
    @test resolveaggr(h3, :n, Int) == :maximum

    # ingest a TermWin-style Dict{Any,Any}; String values become SAFE specs
    h4 = AggrHints(Dict{Any,Any}(:qty => "sum", AbstractString => :uniqvalue))
    @test resolveaggr(h4, :qty, Int) == parseaggr("sum")
    @test resolveaggr(h4, :qty, Int) isa SafeAggrSpec
    @test resolveaggr(h4, :city, String) == :uniqvalue

    @test_throws ErrorException AggrHints("qty" => :sum)
end

@testset "aggregate" begin
    df = DataFrame(
        region = ["E", "E", "W", "W", "W"],
        city = ["ny", "ny", "sf", "sf", "sf"],
        qty = [1, 2, 3, 4, 5],
        wt = [1.0, 3.0, 1.0, 1.0, 2.0],
        score = [10.0, 20.0, 30.0, 60.0, 30.0],
    )

    # defaults: Real -> :sum, String -> :uniqvalue
    out = aggregate(df, [:region])
    @test nrow(out) == 2
    e = out[out.region .== "E", :]
    @test e.qty == [3]
    @test e.city == ["ny"]

    # hints: weighted mean Expr with :_ target, string spec, eltype hint
    h = AggrHints(:score => :( sum(:_ .* :wt) / sum(:wt) ), :wt => "sum")
    out2 = aggregate(df, :region; hints = h, cols = [:score, :wt])
    w = out2[out2.region .== "W", :]
    @test w.score ≈ [(30.0 + 60.0 + 30.0 * 2) / 4.0]
    @test w.wt == [4.0]

    # multi-key grouping
    out3 = aggregate(df, [:region, :city])
    @test nrow(out3) == 2

    # aggrvalue normalizes the scalar / 1x1-DataFrame contract
    @test aggrvalue(3) == 3
    @test aggrvalue(DataFrame(a = [7])) == 7
end
