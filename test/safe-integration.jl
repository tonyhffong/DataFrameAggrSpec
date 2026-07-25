using DataFrameAggrSpec
using DataFrames
using Statistics
using StatsBase
using Test

import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

# Safe specs wired into the REST of the package: AggrHints, WindowDim/PivotDim,
# chains, dimspec, the trust rule at every public door, and host extension via
# registerop! / registerclassifier!.

@testset "integration with hints / dims / chains" begin
    df = DataFrame(
        County = ["C1", "C1", "C1", "C1", "C2", "C2"],
        District = ["d1", "d1", "d2", "d3", "d4", "d5"],
        TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
        EnrlTot = [100, 100, 50, 30, 80, 20],
    )

    # AggrHints with a safe spec matches the trusted-Expr result
    h_safe = AggrHints(:TestScr => aggr"sum(_ * EnrlTot) / sum(EnrlTot)")
    h_expr = AggrHints(:TestScr => :( sum(:_ .* :EnrlTot) / sum(:EnrlTot) ))
    @test agg(df, :County; hints = h_safe, cols = [:TestScr]).TestScr ==
          agg(df, :County; hints = h_expr, cols = [:TestScr]).TestScr

    # lifted safe spec is a plain closure -- callable without invokelatest
    f = liftAggrSpecToFunc(:TestScr, parseaggr("mean(_)"))
    @test f(df) == Statistics.mean(df.TestScr)

    # WindowDim from a safe spec, with ordering
    # C1 in EnrlTot order: d3(30,scr30), d2(50,scr50), d1(100,scr10), d1(100,scr20)
    d = WindowDim(:cum, dim"cumsum(TestScr)"; by = :County, order = :EnrlTot)
    @test dependencies(d) == [:TestScr, :EnrlTot]   # spec refs ∪ order columns
    @test dim(df, [d]).cum == [90.0, 110.0, 80.0, 30.0, 50.0, 10.0]

    # chain: safe pivot dim == trusted pivot dim, kind/fixup/context inferred
    safe_chain = [:County, :top1 => dim"topnames(District, TestScr, 1)"]
    (keycols, dims) = DataFrameAggrSpec.normalize_chain(safe_chain)
    @test dims[1] isa PivotDim
    @test dims[1].by == [:District] && dims[1].context == [:County]
    out_safe = agg(df, safe_chain)
    out_expr = agg(df, [:County, :top1 => :( topnames(:District, :TestScr, 1) )])
    @test isequal(string.(out_safe.top1), string.(out_expr.top1))
    @test isequal(out_safe.TestScr, out_expr.TestScr)

    # dimspec wrapping a safe spec (order / explicit kind)
    df2 = dim(df, [:County, :prev => dimspec(dim"lag(TestScr)"; order = :EnrlTot)])
    @test isequal(df2.prev, [50.0, 10.0, 30.0, missing, 10.0, missing])
    df3 = dim(df, [:County, :size => dimspec(dim"discretize(EnrlTot, [35, 60])";
                                             by = :District, kind = :pivot)])
    @test string(df3.size[1]) == "3. 60+"

    # direct constructors accept safe specs (kind inference is chains' job)
    @test PivotDim(:t, dim"topnames(District, TestScr, 2)") isa PivotDim
    @test WindowDim(:s, dim"TestScr / sum(TestScr)", by = :County) isa WindowDim

    # THE trust rule: plain Strings are untrusted everywhere in the new API,
    # so hostile user input cannot reach eval through any of these doors
    @test_throws ErrorException dim(df, [:County, :evil => "Core.eval(Main, :(run(`ls`)))"])
    @test_throws ErrorException WindowDim(:evil, "open(\"/etc/passwd\")")
    @test_throws ErrorException AggrHints(:TestScr => "Base.exit()")
    @test_throws ErrorException liftAggrSpecToFunc(:TestScr, "run(`ls`)")

    # String specs still work -- through the safe grammar (bare identifiers)
    ws = WindowDim(:t, "sum(TestScr)")
    @test ws.refs == [:TestScr]
    f2 = liftAggrSpecToFunc(:TestScr, "mean(_)")
    @test f2(df) == Statistics.mean(df.TestScr)

    # registerop! extension: custom op, then the StatsBase Weights recipe
    registerop!(:double, x -> 2 .* x)
    @test dim"double(TestScr)".f([1.0, 2.0]) == [2.0, 4.0]

    # a host can register its own CLASSIFIER verb: pivot kind + by-fixup inferred
    registerop!(:tophalf,
        (name, measure) -> [m > Statistics.median(measure) ? "top" : "bottom"
                            for m in measure])
    registerclassifier!(:tophalf, 1)
    (kc, ds) = DataFrameAggrSpec.normalize_chain(
        [:County, :half => dim"tophalf(District, TestScr)"])
    @test ds[1] isa PivotDim
    @test ds[1].by == [:District] && ds[1].context == [:County]
    # per County, district TestScr sums: C1 [d1=30, d2=50, d3=30] (median 30),
    # C2 [d4=40, d5=10] (median 25)
    hf = dim(df, [:County, :half => dim"tophalf(District, TestScr)"])
    @test hf.half == ["bottom", "bottom", "top", "bottom", "top", "bottom"]
    registerop!(:Weights, StatsBase.Weights)
    wm = parseaggr("mean(_, Weights(EnrlTot))")
    g = liftAggrSpecToFunc(:TestScr, wm)
    @test g(df) == StatsBase.mean(df.TestScr, StatsBase.Weights(df.EnrlTot))
end
