using DataFrameAggrSpec
using DataFrames
using Statistics
using Test

@testset "lag / lead" begin
    v = [1, 2, 3, 4]
    @test isequal(lag(v), [missing, 1, 2, 3])
    @test isequal(lag(v, 2), [missing, missing, 1, 2])
    @test lag(v, 1; default = 0) == [0, 1, 2, 3]
    @test isequal(lead(v), [2, 3, 4, missing])
    @test isequal(lead(v, -1), lag(v, 1))
    @test isequal(lag(v, -2), lead(v, 2))
end

@testset "WindowDim basics" begin
    df = DataFrame(
        region = ["E", "W", "E", "W", "W"],
        date = [2, 1, 1, 3, 2],
        sales = [10.0, 5.0, 20.0, 30.0, 15.0],
    )

    # broadcast group aggregate (scalar per partition)
    d = WindowDim(:rtotal, :( sum(:sales) ), by = :region)
    df2 = dim(df, d)
    @test df2.rtotal == [30.0, 50.0, 30.0, 50.0, 50.0]
    @test !hasproperty(df, :rtotal)            # original untouched
    @test dependencies(d) == [:sales]

    # relative-to-group (partition-length vector), broadcasting inside the spec
    df3 = dim(df, WindowDim(:share, :( :sales ./ sum(:sales) ), by = [:region]))
    @test df3.share ≈ [10 / 30, 5 / 50, 20 / 30, 30 / 50, 15 / 50]

    # z-score, nested calls
    df4 = dim(df, WindowDim(:z, :( (:sales .- mean(:sales)) ./ std(:sales) ), by = :region))
    @test df4.z[1] ≈ (10.0 - 15.0) / std([10.0, 20.0])

    # empty by = whole frame is one partition
    df5 = dim(df, WindowDim(:allshare, :( :sales ./ sum(:sales) )))
    @test df5.allshare ≈ df.sales ./ sum(df.sales)

    # String spec form
    df6 = dim(df, WindowDim(:rtotal, "sum(:sales)", by = "region"))
    @test df6.rtotal == df2.rtotal

    # Function spec form (receives the partition as an AbstractDataFrame)
    df7 = dim(df, WindowDim(:cnt, sdf -> nrow(sdf), by = :region))
    @test df7.cnt == [2, 3, 2, 3, 3]
end

@testset "WindowDim ordering" begin
    df = DataFrame(
        region = ["E", "W", "E", "W", "W"],
        date = [2, 1, 1, 3, 2],
        sales = [10.0, 5.0, 20.0, 30.0, 15.0],
    )

    # cumsum within region ordered by date; result scattered back to original rows
    df2 = dim(df, WindowDim(:cum, :( cumsum(:sales) ), by = :region, order = :date))
    # E by date: (date=1,20) then (date=2,10) -> cum 20,30 ; W: 5,20,50
    @test df2.cum == [30.0, 5.0, 20.0, 50.0, 20.0]

    # lag within region ordered by date
    df3 = dim(df, WindowDim(:prev, :( lag(:sales) ), by = :region, order = [:date]))
    @test isequal(df3.prev, [20.0, missing, missing, 15.0, 5.0])

    # descending order
    df4 = dim(df, WindowDim(:cumdesc, :( cumsum(:sales) ), by = :region,
                            order = [:date => :desc]))
    @test df4.cumdesc == [10.0, 50.0, 30.0, 30.0, 45.0]

    # multi-key order with mixed directions
    df5 = dim(df, WindowDim(:rank1, :( collect(1:length(:sales)) ), by = :region,
                            order = [:sales => :desc, :date => :asc]))
    @test df5.rank1 == [2, 3, 1, 1, 2]

    # string order entry
    df6 = dim(df, WindowDim(:prev2, :( lag(:sales) ), by = :region,
                            order = [":date => :desc"]))
    @test isequal(df6.prev2, [missing, 15.0, 10.0, missing, 30.0])
end

@testset "WindowDim edge cases" begin
    df = DataFrame(g = ["a", missing, "a", missing], x = [1.0, 2.0, 3.0, 4.0])

    # missing group keys form their own partition
    df2 = dim(df, WindowDim(:gt, :( sum(:x) ), by = :g))
    @test df2.gt == [4.0, 6.0, 4.0, 6.0]

    # wrong-length vector result errors with the dimension named
    err = try
        dim(df, WindowDim(:bad, :( collect(1:3) ), by = :g))
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("bad", err.msg)

    # name collision errors unless replace=true
    @test_throws ErrorException dim(df, WindowDim(:x, :( sum(:x) )))
    df3 = dim(df, WindowDim(:x, :( sum(:x) )); replace = true)
    @test df3.x == fill(10.0, 4)

    # chained dims: second references the first's output
    df4 = dim(df, WindowDim(:gt, :( sum(:x) ), by = :g),
                  WindowDim(:xfrac, :( :x ./ :gt )))
    @test df4.xfrac ≈ [0.25, 1 / 3, 0.75, 2 / 3]

    # dim! mutates in place; dim on a SubDataFrame materializes
    df5 = copy(df)
    dim!(df5, WindowDim(:gt, :( sum(:x) ), by = :g))
    @test hasproperty(df5, :gt)
    sub = view(df, df.x .> 1.5, :)   # rows (missing,2), (a,3), (missing,4)
    df6 = dim(sub, WindowDim(:gt, :( sum(:x) ), by = :g))
    @test df6.gt == [6.0, 3.0, 6.0]
end
