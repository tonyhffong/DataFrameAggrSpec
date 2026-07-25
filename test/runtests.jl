using Test

@testset "DataFrameAggrSpec" begin
    @testset "verbs (uniqvalue/unionall/discretize/topnames/cut_categories)" begin
        include("dftests.jl")
    end
    @testset "aggregation-spec compiler" begin
        include("aggrspecs.jl")
    end
    @testset "AggrHints + agg" begin
        include("hints.jl")
    end
    @testset "safe DSL grammar / errors / caches" begin
        include("safe-grammar.jl")
    end
    @testset "safe DSL modifiers (orderby / groupby)" begin
        include("safe-modifiers.jl")
    end
    @testset "safe aggregation operators" begin
        include("safe-aggr.jl")
    end
    @testset "safe dimension operators" begin
        include("safe-dim.jl")
    end
    @testset "safe DSL integration (hints / dims / chains)" begin
        include("safe-integration.jl")
    end
    @testset "spec suggestion (templates / vocabulary / summary)" begin
        include("templates.jl")
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
    @testset "pipeline (agg + transforms)" begin
        include("pipeline.jl")
    end
end
