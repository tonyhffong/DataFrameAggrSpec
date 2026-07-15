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

@testset "agg" begin
    df = DataFrame(
        region = ["E", "E", "W", "W", "W"],
        city = ["ny", "ny", "sf", "sf", "sf"],
        qty = [1, 2, 3, 4, 5],
        wt = [1.0, 3.0, 1.0, 1.0, 2.0],
        score = [10.0, 20.0, 30.0, 60.0, 30.0],
    )

    # defaults: Real -> :sum, String -> :uniqvalue
    out = agg(df, [:region])
    @test nrow(out) == 2
    e = out[out.region .== "E", :]
    @test e.qty == [3]
    @test e.city == ["ny"]

    # hints: weighted mean Expr with :_ target, string spec, eltype hint
    h = AggrHints(:score => :( sum(:_ .* :wt) / sum(:wt) ), :wt => "sum")
    out2 = agg(df, :region; hints = h, cols = [:score, :wt])
    w = out2[out2.region .== "W", :]
    @test w.score ≈ [(30.0 + 60.0 + 30.0 * 2) / 4.0]
    @test w.wt == [4.0]

    # multi-key grouping
    out3 = agg(df, [:region, :city])
    @test nrow(out3) == 2

    # aggrvalue normalizes the scalar / 1x1-DataFrame contract
    @test aggrvalue(3) == 3
    @test aggrvalue(DataFrame(a = [7])) == 7
end

@testset "named measures" begin
    df = DataFrame(
        region = ["E", "E", "W", "W", "W"],
        qty = [1, 2, 3, 4, 5],
        wt = [1.0, 3.0, 1.0, 1.0, 2.0],
        score = [10.0, 20.0, 30.0, 60.0, 30.0],
    )

    # same column reduced twice under distinct names (safe string + trusted
    # Expr), mixed with a bare hint-resolved entry; output order = entry order
    out = agg(df, [:region]; cols = [
        :score => "mean(_)" => :score_avg,
        :score => :( maximum(:_) ) => :score_max,
        :qty,
    ])
    @test propertynames(out) == [:region, :score_avg, :score_max, :qty]
    e = out[out.region .== "E", :]
    w = out[out.region .== "W", :]
    @test e.score_avg == [15.0] && e.score_max == [20.0] && e.qty == [3]
    @test w.score_avg == [40.0] && w.score_max == [60.0] && w.qty == [12]

    # two-element form: inline spec override, output keeps the source name
    out2 = agg(df, :region; cols = [:qty => "maximum(_)"])
    @test sort(out2.qty) == [2, 5]

    # Symbol, Function, and SafeAggrSpec specs in the named form; `_`/`:_`
    # binds to the source column and sibling columns stay reachable
    out3 = agg(df, :region; cols = [
        :qty => :maximum => :qty_max,
        :score => (sdf -> sum(sdf.score)) => :score_sum,
        :score => :( sum(:_ .* :wt) / sum(:wt) ) => :score_wavg,
        :wt => aggr"sum(_)" => :wt_tot,
    ])
    w3 = out3[out3.region .== "W", :]
    @test w3.qty_max == [5]
    @test w3.score_sum == [120.0]
    @test w3.score_wavg ≈ [(30.0 + 60.0 + 30.0 * 2) / 4.0]
    @test w3.wt_tot == [4.0]

    # measures ride along chains with computed dimensions
    out4 = agg(df, [:region, :big => :( :qty .> 2 )];
               cols = [:score => "mean(_)" => :avg])
    @test propertynames(out4) == [:region, :big, :avg]
    @test nrow(out4) == 2   # E rows are all qty <= 2, W rows all qty > 2
    @test sort(out4.avg) == [15.0, 40.0]

    # curried transform carries measure entries
    t = agg([:region]; cols = [:score => "mean(_)" => :avg, :qty])
    @test isequal(df |> t,
                  agg(df, [:region]; cols = [:score => "mean(_)" => :avg, :qty]))

    # rejection matrix
    @test_throws ErrorException agg(df, :region;
        cols = [:qty => :sum => :x, :score => :sum => :x])     # duplicate output
    @test_throws ErrorException agg(df, :region;
        cols = [:qty => :sum => :region])                      # collides with key
    @test_throws ErrorException agg(df, :region;
        cols = [:nope => :sum => :x])                          # unknown source
    @test_throws ErrorException agg(df, :region;
        cols = ["score" => :sum])                              # non-Symbol source
    @test_throws ErrorException agg(df, :region;
        cols = [:qty => :sum => "x"])                          # non-Symbol out name
    @test_throws ErrorException agg(df, :region; cols = [42])  # not an entry at all
end
