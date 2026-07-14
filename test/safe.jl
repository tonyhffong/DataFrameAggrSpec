using DataFrameAggrSpec
using DataFrames
using CategoricalArrays
using Statistics
using StatsBase
using Test

import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

@testset "grammar acceptance" begin
    # calls below are DIRECT (no invokelatest): the untrusted path never evals

    s = aggr"sum(_)"
    @test s isa SafeAggrSpec
    @test s.cols == [:_]
    @test s.f([1, 2, 3]) == 6

    # bare registered name lowers to sum(_)
    s2 = aggr"sum"
    @test s2.cols == [:_] && s2.fname == :sum

    # arithmetic between columns and nested calls; cols = first-encounter order
    w = aggr"sum(_ * wt) / sum(wt)"
    @test w.cols == [:_, :wt]
    @test w.f([1.0, 2.0, 3.0], [10.0, 20.0, 30.0]) ≈
          sum([1.0, 2.0, 3.0] .* [10.0, 20.0, 30.0]) / 60.0

    # operator sugar: implicit multiply, unary minus, dotted alias, unicode op
    @test dim"2x".f([1, 2]) == [2, 4]
    @test dim"-x".f([1, 2]) == [-1, -2]
    @test dim"a .+ b".f([1], [2]) == dim"a + b".f([1], [2])
    @test dim"x ≤ 3".f([2, 5]) == [true, false]

    # kwargs in both syntactic forms, with :sym literal values
    k1 = dim"discretize(x, [0, 10], boundedness = :boundedbelow)"
    k2 = dim"discretize(x, [0, 10]; boundedness = :boundedbelow)"
    @test string(k1.f([5.0])[1]) == string(k2.f([5.0])[1]) == "1. [0,10)"

    # positional-arg metadata for the pivot-kind fixups
    t = dim"topnames(District, TestScr, 5)"
    @test t.fname == :topnames
    @test t.posargs == [:District, :TestScr, nothing]   # literals simplify to nothing
    @test t.cols == [:District, :TestScr]

    # mixed literal/column array
    @test dim"discretize(x, [0, cap])".cols == [:x, :cap]

    # per-operator behavior tests live in test/safe-aggr.jl / test/safe-dim.jl
end

@testset "modifiers (parse level)" begin
    # intent first, modifier after; ∘ and |> are synonyms
    s1 = dim"cumsum(sales) ∘ orderby(date)"
    s2 = dim"cumsum(sales) |> orderby(date)"
    @test s1.order == [:date => false]
    @test s2.order == [:date => false]
    @test s1.fname == :cumsum && s1.cols == [:sales]   # metadata = the INNER spec
    @test s2.f([1, 2, 3]) == [1, 3, 6]                 # kernel = the inner spec

    # direction and multi-key forms
    @test dim"lag(sales) |> orderby(date => :desc)".order == [:date => true]
    @test dim"cumsum(sales) |> orderby(region, date)".order ==
          [:region => false, :date => false]

    # groupby: varargs, array form, ∘ spelling -- marks pivot grouping
    g1 = dim"discretize(EnrlTot, [35]) |> groupby(District)"
    g2 = dim"discretize(EnrlTot, [35]) ∘ groupby([District, County])"
    @test g1.by == [:District]
    @test g2.by == [:District, :County]
    @test g1.fname == :discretize && g1.cols == [:EnrlTot]
    @test dim"mean(TestScr) |> groupby(District, County)".by == [:District, :County]

    # both modifiers parse together (kind conflict is a construction-time error)
    gb = dim"discretize(x, [1]) |> groupby(g) |> orderby(d)"
    @test gb.by == [:g] && gb.order == [:d => false]

    modreject(f, s, needle) = begin
        err = try
            f(s)
            nothing
        catch e
            e
        end
        err isa ErrorException && occursin(needle, err.msg)
    end
    @test modreject(parsedim, "cumsum(sales) |> orderby(date) |> orderby(x)",
                    "duplicate orderby")
    @test modreject(parsedim, "orderby(date) |> cumsum(sales)",
                    "must follow the spec")
    @test modreject(parsedim, "cumsum(sales) |> orderby()",
                    "at least one column")
    @test modreject(parsedim, "cumsum(sales) |> foo(x)",
                    "expected a modifier call")
    @test modreject(parsedim, "sum(a |> b)", "unknown function")   # nested, not peeled
    @test modreject(parseaggr, "sum(_) |> orderby(date)",
                    "dimension-spec features")
    @test modreject(parsedim, "mean(x) |> groupby(a) |> groupby(b)",
                    "duplicate groupby")
    @test modreject(parsedim, "mean(x) |> groupby()", "at least one column")
    @test modreject(parsedim, "mean(x) |> groupby([])", "at least one column")
    @test modreject(parsedim, "mean(x) |> groupby(3)", "column names")
    @test modreject(parseaggr, "sum(_) |> groupby(g)", "dimension-spec features")
    @test_throws ErrorException registerop!(:orderby, identity)   # reserved names
    @test_throws ErrorException registerop!(:groupby, identity)
end

@testset "rejection matrix" begin
    reject(s, needle) = begin
        err = try
            parsedim(s)
            nothing
        catch e
            e
        end
        err isa ErrorException && occursin(needle, err.msg)
    end

    @test reject("Core.eval(Main, x)", "qualified names")
    @test reject("run(`ls`)", "unknown function 'run'")
    @test reject("f{Int}(x)", "unsupported function name")
    @test reject("df[1, 1]", "function call")            # top-level :ref fails shape check
    @test reject("sum(df[1, 1])", "indexing")            # nested :ref gets tailored message
    @test reject("sum(x -> x)", "anonymous functions")
    @test reject("sum(a && b)", "&&")
    @test reject("sum(a < b < c)", "chained comparisons")
    @test reject("sum([i for i in x])", "comprehensions")
    @test reject("a; b", "one expression only")
    @test reject("sum(x...)", "splatting")
    @test reject("push!(x, 1)", "unknown function 'push!'")
    @test reject("sum(_)", "'_' is the aggregation target")
    @test reject("", "empty spec")

    # unknown-function error is actionable: lists ops and mentions registerop!
    err = try
        parseaggr("foo(_)")
    catch e
        e
    end
    @test occursin("registerop!", err.msg) && occursin("topnames", err.msg)

    # interpolation cannot reach the compiler via raw string macros, and the
    # :$ / :string heads are rejected anyway
    @test reject("sum(\$x)", "interpolation")
    err2 = try
        parseaggr("sum")   # ok
        parseaggr("nope")  # bare unregistered name
    catch e
        e
    end
    @test occursin("unknown function 'nope'", err2.msg)

    # registerop! guards its namespace invariants
    @test_throws ErrorException registerop!(Symbol("Base.run"), identity)
    @test_throws ErrorException registerop!(:push!, push!)
end

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
    @test aggregate(df, :County; hints = h_safe, cols = [:TestScr]).TestScr ==
          aggregate(df, :County; hints = h_expr, cols = [:TestScr]).TestScr

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
    out_safe = pivottable(df, safe_chain)
    out_expr = pivottable(df, [:County, :top1 => :( topnames(:District, :TestScr, 1) )])
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

@testset "operator docs stay in sync with the registry" begin
    # every SHIPPED operator must be documented (backticked) in one of the two
    # operator documents; host-registered extras (registerop!) are exempt via
    # the DefaultSafeOps snapshot taken at module load
    docdir = joinpath(dirname(@__DIR__), "docs")
    text =
        read(joinpath(docdir, "safe-aggregation-operators.md"), String) *
        read(joinpath(docdir, "safe-dimension-operators.md"), String)
    for op in DataFrameAggrSpec.DefaultSafeOps
        s = string(op)
        startswith(s, ".") && continue   # dotted aliases documented with their base op
        @test occursin("`" * s * "`", text)
    end
end

@testset "cache / equality / show" begin
    @test parseaggr("sum(_)") === parseaggr("sum(_)")     # SafeSpecCache identity
    @test parseaggr(" sum(_) ") == parseaggr("sum(_)")    # strip-insensitive ==
    @test hash(aggr"sum(_)") == hash(parseaggr("sum(_)"))
    @test parsedim("cumsum(x)") === dim"cumsum(x)"

    f1 = liftAggrSpecToFunc(:zz, aggr"sum(_)")
    f2 = liftAggrSpecToFunc(:zz, parseaggr("sum(_)"))
    @test f1 === f2                                       # DataFrameAggrCache hit

    @test repr(aggr"sum(_)") == "aggr\"sum(_)\""
    @test repr(dim"cumsum(x)") == "dim\"cumsum(x)\""
end
