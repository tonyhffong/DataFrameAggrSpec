using DataFrameAggrSpec
using DataFrames
using Statistics
using StatsBase
using Test

import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

# Safe specs wired into the REST of the package: AggrHints, WindowDim/PivotDim,
# chains, dimspec, the trust rule at every public door, and host extension via
# registerop! / registerclassifier!.

# Top level on purpose: the cache-invalidation testset ADDS a method to this
# function to check that a registered NAMED function tracks its method table
# (the host iteration loop). A definition inside the testset would be a local,
# not a second method. Adding rather than overwriting keeps the suite free of
# "Method definition overwritten" warnings, and is the same property -- it is
# also what a package load does to an operator's method table.
methoditer(x::Int) = "m1"

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
    @test_throws SpecError dim(df, [:County, :evil => "Core.eval(Main, :(run(`ls`)))"])
    @test_throws SpecError WindowDim(:evil, "open(\"/etc/passwd\")")
    @test_throws SpecError AggrHints(:TestScr => "Base.exit()")
    @test_throws SpecError liftAggrSpecToFunc(:TestScr, "run(`ls`)")

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
    # REPLACING an operator invalidates the caches automatically. Without this,
    # a parsed spec keeps running the OLD function -- it holds a closure over
    # the operator as it was, and the agg path caches a second layer beyond the
    # parsed spec. Silent wrong answers, in exactly the loop a host uses to
    # develop an operator.
    registerop!(:ver, x -> "v1"; shape = :reduce)
    @test parseaggr("ver(_)").f([1, 2]) == "v1"
    registerop!(:ver, x -> "v2"; shape = :reduce)
    @test parseaggr("ver(_)").f([1, 2]) == "v2"
    # ... including through the agg path, which SafeSpecCache alone would miss
    vdf = DataFrame(g = ["a", "a"], v = [1.0, 2.0])
    registerop!(:va, x -> "a1"; shape = :reduce)
    @test agg(vdf, [:g]; hints = AggrHints(:v => aggr"va(_)")).v == ["a1"]
    registerop!(:va, x -> "a2"; shape = :reduce)
    @test agg(vdf, [:g]; hints = AggrHints(:v => aggr"va(_)")).v == ["a2"]
    # a failed registration changes nothing, so it must not invalidate either
    @test_throws ErrorException registerop!(:va, identity; shape = :redcue)
    @test agg(vdf, [:g]; hints = AggrHints(:v => aggr"va(_)")).v == ["a2"]

    # redefining a METHOD on a registered named function needs no
    # re-registration and no invalidation: the registry stores the GENERIC
    # FUNCTION, not a snapshot, so dispatch picks the new method up. This is
    # the host iteration loop docs/extending-the-grammar.md recommends, so it
    # is pinned. Asserted through invokelatest rather than a direct call: at
    # a REPL the world advances between statements and the direct call sees
    # the new method too, but inside this testset body that would be pinning
    # world-age behaviour rather than the registry's.
    registerop!(:methoditer, methoditer; shape = :reduce)
    @test DataFrameAggrSpec.SafeOps[:methoditer] === methoditer
    @test parseaggr("methoditer(_)").f(1) == "m1"
    @test_throws MethodError parseaggr("methoditer(_)").f("s")
    @eval methoditer(x::String) = "m2"            # widen the method table
    @test Base.invokelatest(parseaggr("methoditer(_)").f, "s") == "m2"
    @test Base.invokelatest(parseaggr("methoditer(_)").f, 1) == "m1"

    # clearcaches! by hand: for host state a registration cannot see. Dropping
    # pure memos must never change an answer.
    before = dim(df, [:County, :cum => dim"cumsum(TestScr)"]).cum
    @test clearcaches!() === nothing
    @test dim(df, [:County, :cum => dim"cumsum(TestScr)"]).cum == before

    registerop!(:Weights, StatsBase.Weights)
    wm = parseaggr("mean(_, Weights(EnrlTot))")
    g = liftAggrSpecToFunc(:TestScr, wm)
    @test g(df) == StatsBase.mean(df.TestScr, StatsBase.Weights(df.EnrlTot))
end
