using Test

@testset "DataFrameAggrSpec" begin
    @testset "verbs (uniqvalue/unionall/discretize/topnames/cut_categories)" begin
        include("dftests.jl")
    end
    @testset "aggregation-spec compiler" begin
        include("aggrspecs.jl")
    end
end
