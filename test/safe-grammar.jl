using DataFrameAggrSpec
using DataFrames
using Test

# The untrusted DSL MACHINERY: what the grammar accepts, what it rejects, how
# good the errors are, and the caches. Nothing here is operator-specific.
#   operator vocabulary  -> test/safe-aggr.jl, test/safe-dim.jl
#   orderby/groupby      -> test/safe-modifiers.jl
#   hints/dims/chains    -> test/safe-integration.jl

# Does parsing `s` fail with a message containing `needle`? Both grammars are
# tried, so each case can be written in whichever spelling reads best (`_`
# forms are aggregation-only, chain-key advice is dimension-only). An empty
# needle asserts the spec PARSES.
# Message-matching helper: thunk must throw an ErrorException whose message
# contains the needle. Use this when the call under test is not a bare parse
# (a kwarg, a `columns` check, a chain verb); `msg2` below is the parse-only
# shorthand.
function msg(f, needle)
    err = try
        f()
        nothing
    catch e
        e
    end
    err isa Exception && occursin(needle, sprint(showerror, err))
end

function msg2(s, needle)
    for p in (parsedim, parseaggr)
        try
            p(s)
            isempty(needle) && return true
        catch e
            e isa Exception || rethrow()
            occursin(needle, sprint(showerror, e)) && return true
        end
    end
    false
end

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
        err isa Exception && occursin(needle, sprint(showerror, err))
    end

    @test reject("Core.eval(Main, x)", "qualified names")
    @test reject("run(`ls`)", "unknown function 'run'")
    @test reject("f{Int}(x)", "unsupported function name")
    # the tailored per-head message is used at the top level too, not only in
    # nested position -- the shape gate defers to SafeRejections
    @test reject("df[1, 1]", "indexing is not allowed")
    @test reject("sum(df[1, 1])", "indexing")
    @test reject("x = 1", "assignment is not allowed")
    @test reject("sum(x) do y end", "do-blocks are not allowed")
    @test reject("mean.(x)", "broadcast calls")
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
    # a lone word that repairs to no operator reads as a column, not a typo
    @test occursin("'nope' is a column reference, not an aggregation", err2.msg)

    # registerop! guards its namespace invariants
    @test_throws ErrorException registerop!(Symbol("Base.run"), identity)
    @test_throws ErrorException registerop!(:push!, push!)
end

@testset "every shipped operator declares a shape" begin
    # The third sync guard, beside the docs and per-operator-test ones. An
    # operator with no declared shape is invisible to the shape checks (they
    # bail to :unknown rather than guess), so a forgotten declaration would
    # silently switch them off for every spec mentioning it.
    for op in DataFrameAggrSpec.DefaultSafeOps
        @test DataFrameAggrSpec.opshape(op) !== :unknown
    end
    # a host verb is unknown until it opts in -- and opting in is validated
    @test DataFrameAggrSpec.opshape(:definitely_not_registered) === :unknown
    registerop!(:shapetest_op, sum)
    @test DataFrameAggrSpec.opshape(:shapetest_op) === :unknown
    registerop!(:shapetest_op, sum; shape = :reduce)
    @test DataFrameAggrSpec.opshape(:shapetest_op) === :reduce
    @test msg(() -> registerop!(:shapetest_op, sum; shape = :reduces),
              "did you mean 'reduce'?")
    delete!(DataFrameAggrSpec.SafeOps, :shapetest_op)
    delete!(DataFrameAggrSpec.SafeOpShapes, :shapetest_op)
end

@testset "shape inference and the shape checks" begin
    sh(s) = DataFrameAggrSpec.shape_of(Meta.parse(s))

    # composition is the point: the same `/` reduces or does not, depending on
    # whether its operands do
    @test sh("sum(_ * wt) / sum(wt)") === :scalar
    @test sh("sales / sum(sales)")    === :rowwise
    @test sh("sum(sales)")            === :scalar
    @test sh("cumsum(x)")             === :rowwise
    @test sh("skipmissing(x)")        === :collection
    @test sh("[a, b]")                === :collection
    @test sh("3")                     === :scalar
    @test sh("x > 1 && y < 2")        === :rowwise
    # `where` follows its condition rather than always mapping
    @test sh("where(sales > 12)")     === :rowwise
    @test sh("where(sum(x) > 12)")    === :scalar
    # :unknown is absorbing -- one undeclared verb silences every check
    @test sh("sum(mystery(x))")       === :scalar   # sum reduces regardless
    @test sh("mystery(x) + 1")        === :unknown

    # an aggregation must reduce to one value
    @test msg2("cumsum(_)", "one value per ROW")
    @test msg(() -> parseaggr("skipmissing(_)"), "yields many values, not one")
    # ...but the legitimate reducing forms all still parse
    for s in ["sum(_)", "sum(_ * wt) / sum(wt)", "nrow", "countuniq",
              "mean(sum(_) |> groupby(year))", "where(sum(_) > 100)",
              "count(coalesce(_ > 0, false))", "unionall(_)", "extrema(_)"]
        @test parseaggr(s) isa SafeAggrSpec
    end

    # a groupby dimension must LABEL each group, not collapse them. This is the
    # check that would have caught `mean(m) |> groupby(c)` shipping in our own
    # templates; the engine could only say "spec must return one value per
    # group (N groups)" much later, naming nothing.
    @test msg(() -> parsedim("mean(x) |> groupby(g)"), "must give one value per group")
    @test msg(() -> parsedim("mean(x) |> groupby(g)"), "'mean' reduces them")
    # the blame lands on the REDUCTION, not the innocent top-level verb
    @test msg(() -> parsedim("where(any(flag)) |> groupby(g)"), "'any' reduces them")
    @test msg(() -> parsedim("skipmissing(x) |> groupby(g)"), "not aligned")
    # ...and the classifying verbs are unaffected
    for s in ["rank(sales) |> groupby(region)", "denserank(x) |> groupby(g)",
              "quantiles(sales, ngroups = 4) |> groupby(region)",
              "discretize(x, [0, 10]) |> groupby(g)",
              "where(active > 0) |> groupby(region)",
              "cumsum(sales) |> groupby(yyyymm(date))"]
        @test parsedim(s) isa SafeDimSpec
    end
    # a WINDOW dim is exempt -- there a scalar is legal and broadcasts
    @test parsedim("sum(sales)") isa SafeDimSpec
    @test parsedim("mean(x)")    isa SafeDimSpec

    # a :map verb handed nothing but scalars has nothing to map over
    @test msg(() -> parsedim("cumsum(sum(x))"), "works down a column")
    @test msg(() -> parsedim("rank(1)"), "works down a column")

    # the shape verdict is whole-spec, so it must not pre-empt the compiler's
    # per-node rejections -- `cumsum(:qty)` is a colon mistake, not a shape one
    @test msg2("cumsum(:qty)", "is a Symbol literal")
    @test msg2("cumsum(maen(x))", "did you mean 'mean'?")

    # shape errors are diagnostics like any other
    e = try (parsedim("mean(x) |> groupby(g)"); nothing) catch e; e end
    @test e isa SpecError && e.code === :shape && e.token === :mean
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
    # operator typos repair against the whitelist (OSA: transposition = 1 edit)
    @test msg(() -> parseaggr("maen(_)"), "did you mean 'mean'?")
    @test msg(() -> parseaggr("sum(qty) / coutn(qty)"), "did you mean 'count'?")
    @test msg(() -> parsedim("cumsmu(sales)"), "did you mean 'cumsum'?")
    @test msg(() -> parseaggr("maen"), "did you mean 'mean'?")   # bare-name form
    # nothing close enough: fall back to the registry as a discovery message.
    # It lists the NAMED operations and summarizes the symbolic ones, which
    # are two thirds of listops() and teach nothing spelled out one by one.
    @test msg(() -> parseaggr("ru(_)"), "Named operations")
    @test msg(() -> parseaggr("ru(_)"), "topnames")
    @test !msg(() -> parseaggr("ru(_)"), ".≥")

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
    @test msg(() -> parsedim("rank(qty) |> groupby(regoin)"; columns = avail),
              "did you mean 'region'?")                  # groupby keys validated
    @test msg(() -> parsedim("rank(qty) |> groupby(yyyymm(dat))"; columns = avail),
              "did you mean 'date'?")   # a COMPUTED groupby key's real columns validate too
    @test checkcols(parseaggr("sum(qty)"), avail) === parseaggr("sum(qty)")
    @test msg(() -> checkcols(parseaggr("sum(zzzzz)"), avail), "Available columns")

    # checkcols names WHERE in the spec the bad reference is, so the user
    # knows which part of the string to edit
    @test msg(() -> parsedim("cumsum(sales) |> orderby(dat)"; columns = avail),
              "references orderby column 'dat'")
    @test msg(() -> parsedim("rank(qty) |> groupby(regoin)"; columns = avail),
              "references groupby column 'regoin'")

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

# ---------------------------------------------------------------------------
# The rejections below all answer the same question -- "what do I type
# instead?" -- for mistakes that used to parse cleanly and die later, or that
# named the offending token without naming the fix.

@testset "errors quote the spec they came from" begin
    # a host parses many specs per frame (an AggrHints table, a chain); the
    # message has to say WHICH one to fix
    err = try
        parseaggr("foo(_)")
    catch e
        e
    end
    @test occursin("[in aggr\"foo(_)\"]", err.msg)
    err2 = try
        parsedim("cumsum(x) |> orderby(1)")
    catch e
        e
    end
    @test occursin("[in dim\"cumsum(x) |> orderby(1)\"]", err2.msg)
    # ... including errors raised by shared helpers further down (order
    # entries live in dimension.jl and know nothing about spec strings)
    @test occursin("parsedim:", err2.msg)

    # Julia's own parse diagnosis is carried over, not swallowed
    @test msg2("sum(_))", "extra tokens after end of expression")
    @test msg2("sum(_", "incomplete expression")
end

@testset "call shape: arity and keyword names" begin
    # both are decidable at parse time from the registered function's method
    # table, and used to surface as a MethodError from inside a group-by --
    # with no mention of the spec that caused it
    # (assertions use THIS package's verbs: the envelope is read off the live
    # method table, so a Base/stdlib name's arity depends on what the host
    # session has loaded -- StatsBase widens `sum` and `quantile`. That is the
    # intended behavior, and the reason the check only fires when NO method
    # could accept the count.)
    @test msg2("uniqvalue()", "takes 1 positional argument, got 0")
    @test msg2("wmeanfallback(qty)", "'wmeanfallback' takes 2 positional arguments, got 1")
    # this package's verbs name their arguments in the message; Base's are
    # terse internals, so those fall back to a generic nudge
    @test msg2("topnames(a, b)", "-- topnames(name, measure, n)")
    @test msg2("wmeanfallback(qty)", "-- wmeanfallback(x, weights)")
    @test msg2("cumsum()", "name the column it works on")
    @test msg2("lag(qty, 1, 2, 3)", "takes 1 to 2 positional arguments, got 4")
    @test msg2("topnames()", "takes 3 positional arguments, got 0")
    # legal arities still parse, including the variadic and defaulted ones
    @test parseaggr("sum(_)") isa SafeAggrSpec
    @test parsedim("discretize(x)") isa SafeDimSpec
    @test parsedim("strjoinuniq(x, \",\", 3)") isa SafeDimSpec
    @test parsedim("yyyymm(t, \"/\")") isa SafeDimSpec

    # keyword names are checked against the same method table, with repair
    @test msg2("rank(x, rev = true)", "")          # accepted
    @test parsedim("rank(x, rev = true)") isa SafeDimSpec
    @test msg2("rank(x, rev1 = true)", "has no keyword option 'rev1'")
    @test msg2("rank(x, rve = true)", "did you mean 'rev'?")
    @test msg2("topnames(a, b, 3, dens = true)", "did you mean 'dense'?")
    @test msg2("topnames(a, b, 3, dens = true)", "Accepted: ")
    @test msg2("countuniq(x, skipna = true)", "")  # accepted
    @test msg2("unionall(x, k = 1)", "takes no keyword options")
    # a function that forwards arbitrary keywords cannot be checked, and is
    # left alone rather than guessed at (discretize passes them to the formatter)
    @test parsedim("discretize(x, [0, 10], anything = 1)") isa SafeDimSpec
end

@testset "the colon flip" begin
    # `:col` IS the column in a trusted Expr and is NOT here -- the single
    # commonest way to write a spec string wrong. It used to compile to a
    # Symbol constant and die at apply time as `MethodError: length(::Symbol)`
    @test msg2("cumsum(:qty)", "is a Symbol literal")
    @test msg2("cumsum(:qty)", "write 'qty', without the colon")
    # still legal as an option VALUE and inside a literal array
    @test parsedim("discretize(x, [0, 10], boundedness = :boundedbelow)") isa SafeDimSpec
    @test parsedim("cls in [:a, :b]") isa SafeDimSpec
    # grouping keys say the same thing, for colons and for quotes
    @test msg2("mean(x) |> groupby(:region)", "without the colon")
    @test msg2("mean(x) |> groupby(\"region\")", "without the quotes")
    @test msg2("mean(sum(_) |> groupby(:year))", "without the colon")
end

@testset "vocabulary a user arrives with" begin
    # The OSA repair can only rescue a MISSPELLING of a whitelisted word;
    # `avg` is four edits from `mean`. Foreign spellings are not aliases --
    # the spec still fails -- they just make the rejection self-guiding.
    @test msg2("avg(_)", "use mean(x)")
    @test msg2("stddev(_)", "use std(x)")
    @test msg2("nunique(x)", "use countuniq(x)")
    @test msg2("n_distinct(x)", "use countuniq(x)")     # underscores stripped
    @test msg2("ifelse(x > 1, 1, 0)", "use where(cond)")
    @test msg2("group_concat(x)", "use strjoinuniq(x)")
    @test msg2("fillna(x, 0)", "use coalesce(x, 0)")
    @test msg2("argmax(x)", "orderby(col)")
    @test msg2("ntile(x)", "quantiles(x, ngroups = 4)")
    # a registered concept spelled the SQL way: name the local spelling
    @test msg2("dense_rank(x)", "write it as 'denserank'")
    @test msg2("SUM(_)", "write it as 'sum'")
    # the declined-by-design entries point at what covers the use case
    @test msg2("unique(x)", "uniqvalue(x)")
    @test msg2("filter(x > 1)", "as a chain key")
end

@testset "repair suggestions stay useful" begin
    # a one-character token is within one edit of half the registry, so a
    # "suggestion" there is noise -- '_' used to repair to '!'
    @test DataFrameAggrSpec.nearest("_", DataFrameAggrSpec.listops()) === nothing
    @test DataFrameAggrSpec.nearest("n", DataFrameAggrSpec.listops()) === nothing
    # ... and a word never repairs to a punctuation operator
    @test DataFrameAggrSpec.nearest("nean", [:mean, Symbol("!")]) == :mean
    @test DataFrameAggrSpec.nearest("!=", [:mean, Symbol("!")]) == Symbol("!")

    # equal-distance candidates resolve by SHARED PREFIX, not alphabetically:
    # 'dsc' is one edit from both 'asc' and 'desc', and the 'd' the user got
    # right is the evidence about which they meant
    @test DataFrameAggrSpec.nearest("dsc", [:asc, :desc]) == :desc
    @test DataFrameAggrSpec.nearest("yyymm", DataFrameAggrSpec.listops()) == :yyyymm
    # the prefix rule is a TIE-break only -- it never beats a closer candidate
    @test DataFrameAggrSpec.nearest("meam", [:mean, :median]) == :mean

    # '_' alone is the target column, not an aggregation
    @test msg2("_", "names the aggregation target column")
end

@testset "SpecError: the machine channel" begin
    # design/user-guidance.md, "the machine-facing direction". The message is
    # the human contract and must not change; `code`/`token`/`fix` are the
    # linter/copilot channel beside it.
    err(f) = try (f(); nothing) catch e; e end

    # showerror prints msg verbatim -- switching a site from `error` to
    # `specerror` is invisible to anyone reading the output
    e = err(() -> parseaggr("maen(_)"))
    @test e isa SpecError
    @test sprint(showerror, e) == e.msg
    @test occursin("did you mean 'mean'?", e.msg)

    # ...and the repair `nearest` computed is no longer discarded
    @test (e.code, e.token, e.fix) == (:unknown_op, :maen, :mean)

    # a `fix` is a DROP-IN: substituting it for `token` must yield a valid spec
    for (src, kind) in [("maen(_)", :aggr), ("sum(qty) / coutn(qty)", :aggr),
                        ("cumsmu(sales)", :dim), ("dense_rank(x)", :dim),
                        ("cumsum(x) |> orderb(d)", :dim)]
        d = err(() -> kind === :aggr ? parseaggr(src) : parsedim(src))
        @test d isa SpecError && d.fix !== nothing
        fixed = replace(src, string(d.token) => string(d.fix))
        @test (kind === :aggr ? parseaggr(fixed) : parsedim(fixed)) !== nothing
    end

    # codes distinguish the ladder's rungs, so a consumer can branch
    @test err(() -> parsedim("(a > 1) & (b < 2)")).code == :boolean_operator
    @test err(() -> parseaggr("avg(_)")).code           == :foreign_spelling
    @test err(() -> parsedim("dense_rank(x)")).code     == :spelling_convention
    @test err(() -> parsedim("orderby(date)")).code     == :modifier_misuse
    @test err(() -> parsedim("topnames()")).code        == :arity
    @test err(() -> parsedim("rank(x, rve = true)")).code == :unknown_kwarg
    @test err(() -> parsedim("cumsum(:qty)")).code      == :symbol_literal
    @test err(() -> parsedim("x = 1")).code             == :unsupported_syntax
    @test err(() -> parsedim("sum(")).code              == :parse
    @test err(() -> parseaggr("")).code                 == :empty_spec
    @test err(() -> parseaggr("_")).code                == :target_placeholder
    @test err(() -> parseaggr("nope")).code             == :bare_name

    # a foreign spelling deliberately offers NO fix: the table's values are
    # prose ("Use ___ instead"), and guessing a token out of prose is the kind
    # of repair rule G3 forbids
    fs = err(() -> parseaggr("avg(_)"))
    @test fs.token === :avg && fs.fix === nothing

    # the colon flip's fix is the bare word
    cf = err(() -> parsedim("cumsum(:qty)"))
    @test (cf.token, cf.fix) == (:qty, :qty)

    # column diagnostics carry the spec they came from, so a host need not
    # regex the `[in aggr"…"]` suffix back out of the message
    cc = err(() -> parseaggr("sum(qtty)"; columns = [:qty, :region]))
    @test (cc.code, cc.token, cc.fix) == (:unknown_column, :qtty, :qty)
    @test cc.spec == "sum(qtty)"
    tagged = err(() -> parseaggr("suum(x)"))
    @test tagged.spec == "suum(x)"
    @test occursin("[in aggr\"suum(x)\"]", tagged.msg)   # message unchanged

    # an unclassified site still yields a usable diagnostic rather than an
    # untyped ErrorException -- classifying a site is additive, never a
    # prerequisite
    u = err(() -> parsedim("cumsum(x) |> orderby(d => :dsc)"))
    @test u isa SpecError && u.spec == "cumsum(x) |> orderby(d => :dsc)"
    @test (u.code, u.token, u.fix) == (:order_entry, :dsc, :desc)

    # apply-time column checks are diagnostics too
    df = DataFrame(region = ["E"], qty = [1])
    a = err(() -> agg(df, :regoin))
    @test a isa SpecError && (a.code, a.token, a.fix) == (:unknown_column, :regoin, :region)

    # host-code mistakes stay ordinary ErrorExceptions -- they are not
    # something a linter reports against a user's spec
    for f in (() -> registerop!(:orderby, identity),
              () -> AggrHints("qty" => :sum),
              () -> dimspec(:(cumsum(x)); kind = :nope),
              () -> spec_templates(:bogus))
        @test err(f) isa ErrorException
    end
end

@testset "the entry-point prefix comes from the choke point, not the sites" begin
    # After the safe.jl split, no parse-path helper threads a `what` parameter:
    # `with_spec_context` prefixes any message that lacks one (G12), the same
    # way dimension.jl's order-entry helpers have always relied on it. These
    # pin the property end to end, since a helper that started self-prefixing
    # again would still pass every message-content test.
    for (f, want) in [(() -> parseaggr("maen(_)"),        "parseaggr: "),
                      (() -> parsedim("cumsmu(x)"),       "parsedim: "),
                      (() -> parseaggr("topnames()"),     "parseaggr: "),
                      (() -> parsedim("x = 1"),           "parsedim: "),
                      (() -> parseaggr("sum("),           "parseaggr: "),
                      (() -> parsedim("cumsum(x) |> orderby(d => :dsc)"), "parsedim: ")]
        e = try (f(); nothing) catch e; e end
        @test e isa SpecError && startswith(e.msg, want)
        @test !occursin(want, e.msg[length(want)+1:end])   # exactly once
    end

    # the three apply-time diagnostics inside a nested grouped reduction are the
    # exception: no wrapper is active there, so they name the CONSTRUCT rather
    # than an entry point (claiming "parsedim:" would be a lie -- parsing
    # succeeded long before)
    df = DataFrame(g = ["a", "b"], v = [1, 2])
    e = try (dim(df, [:d => dim"mean(sum(v) |> groupby(nrow(v)))"]); nothing) catch e; e end
    @test e isa SpecError && e.code === :groupby_key
    @test occursin("grouped reduction (|> groupby)", e.msg)
    @test !occursin("parsedim", e.msg)
end

@testset "SpecError: source spans" begin
    err(f) = try (f(); nothing) catch e; e end
    at(e) = e.span === nothing ? nothing : e.spec[e.span]

    # the span underlines the offending TEXT, in bytes into `spec`
    @test at(err(() -> parseaggr("sum(_ * wt) / maen(wt)"))) == "maen"
    @test at(err(() -> parsedim("(a > 1) & (b < 2)")))       == "&"
    @test at(err(() -> parsedim("rank(x, rve = true)")))     == "rve"
    @test at(err(() -> parseaggr("sum(qtty)"; columns = [:qty]))) == "qtty"

    # `span` + `fix` compose into an edit that actually repairs the spec
    for (src, kind) in [("sum(_ * wt) / maen(wt)", :aggr), ("cumsmu(sales)", :dim),
                        ("cumsum(:qty)", :dim), ("dense_rank(x)", :dim),
                        ("cumsum(x) |> orderby(d => :dsc)", :dim),
                        ("rank(x) |> groupby(\"region\")", :dim)]
        e = err(() -> kind === :aggr ? parseaggr(src) : parsedim(src))
        @test e.span !== nothing && e.fix !== nothing
        fixed = e.spec[1:first(e.span)-1] * string(e.fix) * e.spec[last(e.span)+1:end]
        @test (kind === :aggr ? parseaggr(fixed) : parsedim(fixed)) !== nothing
    end

    # a quoting mistake spans the QUOTING too -- swapping `qty` for `qty` would
    # repair nothing, so the colon/quotes have to be inside the range
    @test at(err(() -> parsedim("cumsum(:qty)")))                  == ":qty"
    @test at(err(() -> parsedim("mean(x) |> groupby(\"region\")"))) == "\"region\""
    # ...while a direction typo does NOT, since `desc` replaces `dsc` after the colon
    @test at(err(() -> parsedim("cumsum(x) |> orderby(d => :dsc)"))) == "dsc"

    # shape verdicts point at what caused them, on both sides
    @test at(err(() -> parsedim("mean(x) |> groupby(g)")))       == "mean"
    @test at(err(() -> parsedim("where(any(f)) |> groupby(g)"))) == "any"
    @test at(err(() -> parseaggr("sum(a) + qtty")))              == "qtty"
    @test at(err(() -> parseaggr("cumsum(_)")))                  == "cumsum"

    # a syntax error carries the range Julia's own parser reported
    @test at(err(() -> parsedim("sum(x))"))) == ")"

    # byte ranges stay correct across multibyte characters
    e = err(() -> parseaggr("sum(x ≠ y) / maen(z)"))
    @test e.spec[e.span] == "maen"

    # the span indexes the STRIPPED source, which is what `spec` holds
    e2 = err(() -> parseaggr("   maen(_)   "))
    @test e2.spec == "maen(_)" && e2.spec[e2.span] == "maen"

    # a span is never guessed into existence
    @test err(() -> parseaggr("foo(_)")).span == 1:3          # located
    @test err(() -> parseaggr("")).span === nothing           # nothing to point at

    # the lexer is advisory and must never throw, whatever it is handed
    for s in ["\"unterminated", "a \\ b", "\$(x)", "sum(x) # c", "≠≠≠", ":", "x!"]
        @test DataFrameAggrSpec.token_span(s, :nope, :invalid_spec) === nothing
        @test DataFrameAggrSpec.scan_tokens(s) isa Vector
    end
end

@testset "argument-name typos are repaired too" begin
    # `kind` is developer-facing rather than end-user-facing, but the repair is
    # one call and the sites used to disagree on whether to even try
    @test msg(() -> spec_templates(:aggrr), "did you mean 'aggr'?")
    @test msg(() -> spec_vocabulary(:dimm), "did you mean 'dim'?")
    @test msg(() -> dimspec(:(cumsum(x)); kind = :windo), "did you mean 'window'?")
    # ...and they agree with orderentry's long-standing wording
    @test msg(() -> parsedim("cumsum(x) |> orderby(d => :dsc)"), "did you mean 'desc'?")
end

@testset "modifier and ordering mistakes" begin
    # a direction where a column belongs used to sort by a phantom `desc`
    # column, silently, and only fail at the frame (if at all)
    @test msg2("cumsum(x) |> orderby(date, :desc)", "is a sort direction, not a column")
    @test msg2("cumsum(x) |> orderby(date, :desc)", "orderby(col => :desc)")
    @test msg2("cumsum(x) |> orderby(date, desc)", "is a sort direction")
    # ... with an escape hatch if `desc` really is a column name
    @test parsedim("cumsum(x) |> orderby(desc => :asc)").order == [:desc => false]
    @test msg2("cumsum(x) |> orderby(date => :descending)", "must be :asc or :desc")
    @test msg2("cumsum(x) |> orderby(date => :descending)", "on column 'date'")
    # the array spelling groupby accepts is not orderby's, and says so
    @test msg2("cumsum(x) |> orderby([a, b])", "write orderby(a, b)")
    @test msg2("cumsum(x) |> orderby(1)", "an entry is a column")
    # the dotted separator this grammar deliberately does not have
    # (design/glyph-choice.md) reads as a qualified name without this
    @test msg2("cumsum(x).orderby(date)", "postfix modifier")
    @test msg2("cumsum(x).orderby(date)", "never '.'")
end
