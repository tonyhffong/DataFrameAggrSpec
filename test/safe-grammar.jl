using DataFrameAggrSpec
using DataFrames
using Test

# The untrusted DSL MACHINERY: what the grammar accepts, what it rejects, how
# good the errors are, and the caches. Nothing here is operator-specific.
#   operator vocabulary  -> test/safe-aggr.jl, test/safe-dim.jl
#   orderby/groupby      -> test/safe-modifiers.jl
#   hints/dims/chains    -> test/safe-integration.jl

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
    # & / | are not registered: the error redirects to the && / || translation
    @test reject("(a > 1) & (b < 2)", "combine conditions with '&&'")
    @test reject("(a > 1) .| (b < 2)", "combine conditions with '||'")
    @test reject("sum(a < b < c)", "chained comparisons")
    @test reject("sum(a < b < c)", "&&")   # ... and teaches the && spelling
    @test reject("8 < sales < 25", "&&")   # top-level form gets the same lesson
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

@testset "every shipped operator has a test" begin
    # The sibling of the docs rule below, one level down: every shipped
    # operator must be NAMED by a @testset in one of the two per-operator
    # files (table-driven families name theirs in the table's first column,
    # which becomes a nested @testset). This is what makes "where is the
    # example for X" answerable by grep, and it turns "added an operator,
    # forgot the test" into a failure instead of a silent gap.
    testdir = @__DIR__
    text =
        read(joinpath(testdir, "safe-aggr.jl"), String) *
        read(joinpath(testdir, "safe-dim.jl"), String)
    for op in DataFrameAggrSpec.DefaultSafeOps
        s = string(op)
        startswith(s, ".") && continue   # dotted aliases share their base op's test
        @test occursin("\"" * s * "\"", text)
    end
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

@testset "helpful errors" begin
    # message-matching helper: thunk must throw an ErrorException whose
    # message contains the needle
    msg(f, needle) = begin
        err = try
            f()
            nothing
        catch e
            e
        end
        err isa ErrorException && occursin(needle, err.msg)
    end

    # operator typos repair against the whitelist (OSA: transposition = 1 edit)
    @test msg(() -> parseaggr("maen(_)"), "did you mean 'mean'?")
    @test msg(() -> parseaggr("sum(qty) / coutn(qty)"), "did you mean 'count'?")
    @test msg(() -> parsedim("cumsmu(sales)"), "did you mean 'cumsum'?")
    @test msg(() -> parseaggr("maen"), "did you mean 'mean'?")   # bare-name form
    # nothing close enough: fall back to the full-registry discovery message
    @test msg(() -> parseaggr("ru(_)"), "Registered operations")

    # modifier names in call position get the pattern reminder, not "unknown"
    @test msg(() -> parsedim("orderby(date)"), "postfix modifier")
    @test msg(() -> parsedim("orderby(date)"), "|> orderby(date)")
    @test msg(() -> parseaggr("groupby(g)"), "postfix modifier")
    # ... and misspelled/malformed modifiers repair or remind
    @test msg(() -> parsedim("cumsum(x) |> orderb(d)"), "did you mean 'orderby'?")
    @test msg(() -> parsedim("cumsum(x) |> orderby"), "takes columns")
    @test msg(() -> parsedim("cumsum(x) |> groupb"), "did you mean 'groupby'?")

    # aggr specs reject a top-level groupby (dimension-spec-only feature);
    # orderby IS legal there -- see test/safe-modifiers.jl for its behavior
    @test msg(() -> parseaggr("sum(_) |> groupby(g)"), "dimension-spec")

    # dim-spec shape errors explain the chain grammar
    @test msg(() -> parsedim("sales"), "chain KEY")
    @test msg(() -> parsedim("cumsum"), "write it as a call")

    # column validation: the `columns` kwarg and standalone checkcols
    avail = [:qty, :wt, :region, :date, :sales]
    @test parseaggr("sum(_ * wt)"; columns = avail) isa SafeAggrSpec  # _ exempt
    @test parseaggr("sum(qty)"; columns = avail) === parseaggr("sum(qty)")  # cache kept
    @test msg(() -> parseaggr("sum(qtty)"; columns = avail), "did you mean 'qty'?")
    @test msg(() -> parsedim("cumsum(sales) |> orderby(dat)"; columns = avail),
              "did you mean 'date'?")                    # orderby cols validated
    @test msg(() -> parsedim("mean(qty) |> groupby(regoin)"; columns = avail),
              "did you mean 'region'?")                  # groupby keys validated
    @test msg(() -> parsedim("mean(qty) |> groupby(yyyymm(dat))"; columns = avail),
              "did you mean 'date'?")   # a COMPUTED groupby key's real columns validate too
    @test checkcols(parseaggr("sum(qty)"), avail) === parseaggr("sum(qty)")
    @test msg(() -> checkcols(parseaggr("sum(zzzzz)"), avail), "Available columns")

    # apply-time: agg keys, measure sources, and dim inputs all suggest
    df = DataFrame(region = ["E", "W"], qty = [1, 2], sales = [1.0, 2.0])
    @test msg(() -> agg(df, :regoin), "did you mean 'region'?")
    @test msg(() -> agg(df, :region; cols = [:qtty => :sum => :x]),
              "did you mean 'qty'?")
    @test msg(() -> agg(df, ["region", ["r1", "cumsum(qtyy)"]]),
              "dimension r1")
    @test msg(() -> agg(df, ["region", ["r1", "cumsum(qtyy)"]]),
              "did you mean 'qty'?")
end
