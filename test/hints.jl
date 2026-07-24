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

    # Union{Missing,T} columns -- the eltype DataFrames.jl actually gives any
    # column that has ever held a missing -- must resolve exactly like their
    # non-nullable T, both via bytype hints and via the generic default.
    # Before the fix, T <: K was checked on the raw (Missing-including) type,
    # so none of these ever matched and every nullable column silently fell
    # to the :uniqvalue catch-all.
    hn = AggrHints(:score => :( mean(:_) ), AbstractString => :uniqvalue)
    @test resolveaggr(hn, :score, Union{Missing,Float64}) == :( mean(:_) )   # bycol unaffected
    @test resolveaggr(hn, :city, Union{Missing,String}) == :uniqvalue        # bytype now matches
    @test resolveaggr(hn, :qty, Union{Missing,Int}) == :sum                  # default now matches

    # a pure Missing column (all-missing) must NOT spuriously match the
    # FIRST bytype entry just because Base.nonmissingtype(Missing) == Union{}
    # is <: everything -- it should behave exactly as before the fix.
    hboth = AggrHints(AbstractString => :uniqvalue, Real => :sum)
    @test resolveaggr(hboth, :allmiss, Missing) == :uniqvalue   # == default(Missing), not the AbstractString hint by luck
    @test resolveaggr(AggrHints(; default = _ -> :maximum), :allmiss, Missing) == :maximum
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

@testset "agg over a Union{Missing,T} column (no explicit hint)" begin
    # sales has ONE missing (region W); this is the ordinary eltype DataFrames
    # gives any column that has ever held a missing. Before the fix, the
    # default resolved to :uniqvalue instead of :sum for the whole column
    # (T <: Real failed on Union{Missing,Float64}), so EVERY region -- not
    # just the one with a real missing value -- silently came back missing.
    df = DataFrame(region = ["E", "E", "W", "W", "W"],
                   sales  = [1.0, 2.0, 3.0, missing, 5.0])
    out = agg(df, [:region])
    e = out[out.region .== "E", :]
    w = out[out.region .== "W", :]
    @test e.sales == [3.0]         # E has no missing at all -- must sum correctly
    @test ismissing(w.sales[1])    # W genuinely contains a missing -- Base sum propagates it

    # the README's own bytype idiom, against a nullable String column with an
    # actual missing AND a group with two distinct non-missing values
    df2 = DataFrame(county   = ["Alameda", "Alameda", "Placer", "Placer"],
                    district = ["A", "B", missing, "B"],
                    score    = [10.0, 20.0, 30.0, 40.0])
    h = AggrHints(AbstractString => aggr"strjoinuniq(_)")
    out2 = agg(df2, [:county]; hints = h)
    a = out2[out2.county .== "Alameda", :]
    p = out2[out2.county .== "Placer", :]
    @test a.district == ["A,B"]    # two distinct, no missing -- the hint must actually apply
    @test p.district == ["B"]      # one missing (skipped) + one real value
end

@testset "allbut (the mirror of cols)" begin
    df = DataFrame(
        region = ["E", "E", "W", "W", "W"],
        qty = [1, 2, 3, 4, 5],
        wt = [1.0, 3.0, 1.0, 1.0, 2.0],
        score = [10.0, 20.0, 30.0, 60.0, 30.0],
    )

    # default reductions minus the listed columns; entry order = column order
    out = agg(df, [:region]; allbut = [:wt])
    @test propertynames(out) == [:region, :qty, :score]
    @test isequal(out, agg(df, [:region]; cols = [:qty, :score]))

    # single-Symbol convenience
    @test isequal(agg(df, :region; allbut = :wt), out)

    # hints still drive the surviving columns
    h = AggrHints(:score => aggr"maximum(_)")
    outh = agg(df, :region; hints = h, allbut = [:qty, :wt])
    @test propertynames(outh) == [:region, :score]
    @test sort(outh.score) == [20.0, 60.0]

    # THE motivating case (design/middle-windowpivot-usecase.md): drop a
    # helper column that only existed to build a chain dimension
    sess = DataFrame(user = ["u1", "u1", "u1", "u1", "u2", "u2"],
                     t    = [0, 5, 60, 62, 0, 90],
                     gap  = [0, 5, 55, 2, 0, 90],
                     spend = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0])
    chain = [:user, :session => dim"cumsum(gap > 30) |> orderby(t)"]
    s = agg(sess, chain; hints = AggrHints(:spend => aggr"sum", :t => aggr"minimum"),
            allbut = [:gap])
    @test propertynames(s) == [:user, :session, :t, :spend]
    @test sort(s.spend) == [3.0, 12.0, 16.0, 32.0]

    # curried transform carries allbut
    tr = agg([:region]; allbut = :wt)
    @test isequal(df |> tr, out)

    # rejection matrix: selection modes are mutually exclusive; allbut columns
    # must exist (did-you-mean) and must not be chain keys
    @test_throws ErrorException agg(df, :region; cols = [:qty], allbut = [:wt])
    err = try
        agg(df, :region; allbut = [:qtty])
    catch e
        e
    end
    @test err isa ErrorException && occursin("did you mean 'qty'?", err.msg)
    @test_throws ErrorException agg(df, :region; allbut = [:region])
end

@testset "distinct key combinations (cols = [] / allbut excluding everything)" begin
    # Before the fix, an empty measure list made agg's `combine(gd) do sdf;
    # DataFrame(); end` collapse to ZERO rows (DataFrames.jl counts rows from
    # the per-group return shape; an empty return means "no rows for this
    # group," not "one row, no extra columns"). cols = [] / allbut excluding
    # every remaining column reads naturally as SELECT DISTINCT keys -- that's
    # what should come back: one row per distinct key combination.
    df = DataFrame(region = ["E", "E", "W", "W", "W"], sales = [1.0, 2.0, 3.0, 4.0, 5.0])

    out = agg(df, [:region]; cols = [])
    @test propertynames(out) == [:region]
    @test sort(out.region) == ["E", "W"]

    out2 = agg(df, [:region]; allbut = [:sales])
    @test isequal(out, out2)

    # a chain whose keys already cover every column in the frame -- the
    # default `cols = nothing` path resolves to an empty measure list too,
    # with no special kwarg needed to trigger it
    out3 = agg(df, [:region, :sales])
    @test propertynames(out3) == [:region, :sales]
    @test isequal(sort(out3, [:region, :sales]), sort(unique(df), [:region, :sales]))

    # a key column containing an actual missing value still gets its own
    # distinct row (matches the skipmissing=false groupby used elsewhere in agg)
    df2 = DataFrame(region = ["E", "E", missing, "W", "W"], sales = [1.0, 2.0, 3.0, 4.0, 5.0])
    out4 = agg(df2, [:region]; cols = [])
    @test nrow(out4) == 3
    @test any(ismissing, out4.region)
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
