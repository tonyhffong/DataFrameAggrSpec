using Test

@testset "DataFrameAggrSpec" begin
    @testset "verbs (uniqvalue/unionall/discretize/topnames/cut_categories)" begin
        include("dftests.jl")
    end
    @testset "aggregation-spec compiler" begin
        include("aggrspecs.jl")
    end
    @testset "AggrHints + aggregate" begin
        include("hints.jl")
    end
    @testset "window dimensions" begin
        include("dimensions.jl")
    end
    @testset "pivot dimensions" begin
        include("pivotdims.jl")
    end
    @testset "chains" begin
        include("chains.jl")
    end
    @testset "pipeline (pivottable + transforms)" begin
        include("pipeline.jl")
    end
    @testset "deprecated legacy API" begin
        include("deprecated.jl")
    end
end
