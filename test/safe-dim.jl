using DataFrameAggrSpec
using DataFrames
using CategoricalArrays
using Statistics
using Dates
using Test

import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

# Per-operator tests for SAFE DIMENSION operators, mirroring the table in
# docs/safe-dimension-operators.md -- ONE @testset per operator, named for the
# operator exactly as the registry spells it, so `@testset "<op>"` is
# greppable. The "every shipped operator has a test" testset in
# test/safe-grammar.jl enforces that; a new operator without one fails there.
# Elsewhere: grammar/rejections/errors -> test/safe-grammar.jl,
# orderby/groupby -> test/safe-modifiers.jl, wiring -> test/safe-integration.jl.

sddf() = DataFrame(
    County = ["C1", "C1", "C1", "C1", "C2", "C2"],
    District = ["d1", "d1", "d2", "d3", "d4", "d5"],
    TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
    EnrlTot = [100, 100, 50, 30, 80, 20],
)

@testset "group-relative measures" begin
    # a reduction returns a scalar per partition; arithmetic broadcasts it back
    # across the rows. Not operator-specific -- this is the broadcast contract.
    @test dim"sales / sum(sales)".f([1.0, 3.0]) == [0.25, 0.75]   # share of group
    @test dim"sum(sales)".f([1.0, 3.0]) == 4.0                    # broadcast group total
    @test dim"sales > mean(sales)".f([1.0, 3.0]) == [false, true] # above-average flag
    @test dim"countuniq(District)".f(["a", "b", "a"]) == 2        # distinct count broadcast
    @test dim"round(sales / sum(sales), digits = 2)".f([1.0, 2.0]) == [0.33, 0.67]
end

@testset "cumsum" begin
    @test dim"cumsum(sales)".f([1, 2, 3]) == [1, 3, 6]
end

@testset "cumprod" begin
    @test dim"cumprod(g)".f([2, 3]) == [2, 6]
end

@testset "lag" begin
    @test isequal(dim"lag(x)".f([1, 2, 3]), [missing, 1, 2])
    @test isequal(dim"lag(x, 2)".f([1, 2, 3]), [missing, missing, 1])
end

@testset "lead" begin
    @test isequal(dim"lead(x)".f([1, 2, 3]), [2, 3, missing])
    @test isequal(dim"lead(x, 2)".f([1, 2, 3]), [3, missing, missing])
end

@testset "rank" begin
    # competition ranking: ties share a rank and SKIP the slots they consume
    @test dim"rank(x)".f([10, 20, 20, 30]) == [1, 2, 2, 4]
    @test dim"rank(x, rev = true)".f([10, 20, 20, 30]) == [4, 2, 2, 1]
    # missing ranks missing and takes no slot; eltype follows the INPUT
    @test isequal(dim"rank(x)".f([10, missing, 20, 20]), [1, missing, 2, 2])
    @test eltype(dim"rank(x)".f([3.0, 1.0])) === Int
    @test isempty(dim"rank(x)".f(Int[]))
    @test isequal(dim"rank(x)".f([missing, missing]), [missing, missing])

    # ranks VALUES, not row positions -- permuting the input permutes the
    # answer with it, which is why no `order` is needed (contrast lag/lead)
    v, p = [10, 20, 20, 30], [3, 1, 4, 2]
    @test dim"rank(x)".f(v[p]) == dim"rank(x)".f(v)[p]
end

@testset "denserank" begin
    # no gaps: the largest rank is the number of DISTINCT values
    @test dim"denserank(x)".f([10, 20, 20, 30]) == [1, 2, 2, 3]
    @test dim"denserank(x, rev = true)".f([10, 20, 20, 30]) == [3, 2, 2, 1]
    @test isequal(dim"denserank(x)".f([10, missing, 20, 20]), [1, missing, 2, 2])
    @test maximum(dim"denserank(x)".f([5, 5, 5])) == 1
end

@testset "ordinalrank" begin
    # ROW_NUMBER: no ties -- every element gets its own rank
    @test dim"ordinalrank(x)".f([10, 20, 20, 30]) == [1, 2, 3, 4]
    # ties break by INPUT POSITION, and `rev` does not reverse that: the
    # first-occurring 20 keeps the lower rank in both directions
    @test dim"ordinalrank(x)".f([20, 20, 10]) == [2, 3, 1]
    @test dim"ordinalrank(x, rev = true)".f([10, 20, 20, 30]) == [4, 2, 3, 1]
    @test isequal(dim"ordinalrank(x)".f([10, missing, 20, 20]), [1, missing, 2, 3])
    @test sort(dim"ordinalrank(x)".f([5, 5, 5])) == [1, 2, 3]   # a permutation of 1:n

    # the odd one out: position-based, so unlike the other three it is NOT
    # permutation-equivariant -- this is why it pairs with `order`
    v, p = [10, 20, 20, 30], [3, 1, 4, 2]
    @test dim"ordinalrank(x)".f(v[p]) != dim"ordinalrank(x)".f(v)[p]
end

@testset "tiedrank" begin
    # each tie group takes the AVERAGE of the ordinal ranks it spans
    @test dim"tiedrank(x)".f([10, 20, 20, 30]) == [1.0, 2.5, 2.5, 4.0]
    @test dim"tiedrank(x, rev = true)".f([10, 20, 20, 30]) == [4.0, 2.5, 2.5, 1.0]
    @test dim"tiedrank(x)".f([5, 5, 5]) == [2.0, 2.0, 2.0]
    @test isequal(dim"tiedrank(x)".f([10, missing, 20, 20]), [1.0, missing, 2.5, 2.5])
    @test eltype(dim"tiedrank(x)".f([3, 1])) === Float64
    # the defining property: ranks always sum to n(n+1)/2, however they tie
    @test sum(dim"tiedrank(x)".f([2, 1, 2, 1, 3])) == 5 * 6 / 2
    # value-based like rank/denserank, so permutation-equivariant
    v, p = [10, 20, 20, 30], [3, 1, 4, 2]
    @test dim"tiedrank(x)".f(v[p]) == dim"tiedrank(x)".f(v)[p]
end

@testset "ranking in the engine" begin
    df = sddf()
    # window kind, partitioned by the left context (County)
    out = dim(df, [:County, :r => dim"rank(TestScr, rev = true)"])
    @test out.r == [4, 3, 1, 2, 1, 2]      # C1: 10,20,50,30 | C2: 40,10
    @test out.TestScr == df.TestScr        # non-destructive, original row order

    # an `order` on the dimension cannot disturb a value-based rank
    @test dim(df, [:County, :r => dimspec(dim"rank(TestScr)"; order = :TestScr)]).r ==
          dim(df, [:County, :r => dim"rank(TestScr)"]).r

    # ordinalrank is position-based, so the declared `order` decides its
    # tie-break. District d1's two C1 rows both carry EnrlTot 100, and which of
    # them takes the lower ordinal flips with the order:
    noorder = dim(df, [:County, :n => dim"ordinalrank(EnrlTot)"]).n
    desc = dim(df, [:County, :n => dim"ordinalrank(EnrlTot) |> orderby(TestScr => :desc)"]).n
    @test noorder[1:4] == [3, 4, 2, 1]   # frame order: row 1's 100 ranks first
    @test desc[1:4] == [4, 3, 2, 1]      # TestScr desc puts row 2 first instead
    @test noorder != desc                # the contrast rank/denserank cannot show

    # `groupby` ranks the GROUPS by their aggregate, broadcast to member rows
    g = dim(df, [:County, :r => dim"rank(EnrlTot) |> groupby(District)"])
    @test length(unique(g.r[g.District.=="d1"])) == 1   # one rank per district
end

@testset "elementwise math" begin
    # table-driven so each operator still gets a @testset NAMED for it
    for (op, spec, input, expected) in Any[
        ("abs",   "abs(x)",               [-1.0, 2.0],  [1.0, 2.0]),
        ("log",   "log(x)",               [1.0, ℯ],     [0.0, 1.0]),
        ("log2",  "log2(x)",              [1.0, 8.0],   [0.0, 3.0]),
        ("log10", "log10(x)",             [1.0, 100.0], [0.0, 2.0]),
        ("exp",   "exp(x)",               [0.0, 1.0],   [1.0, ℯ]),
        ("sqrt",  "sqrt(x)",              [4.0, 9.0],   [2.0, 3.0]),
        ("round", "round(x, digits = 1)", [1.24, 1.26], [1.2, 1.3]),
        ("floor", "floor(x)",             [1.7, -1.2],  [1.0, -2.0]),
        ("ceil",  "ceil(x)",              [1.2, -1.7],  [2.0, -1.0]),
        ("min",   "min(x, 2)",            [1.0, 5.0],   [1.0, 2.0]),
        ("max",   "max(x, 2)",            [1.0, 5.0],   [2.0, 5.0]),
    ]
        @testset "$op" begin
            @test parsedim(spec).f(input) ≈ expected
        end
    end
end

@testset "arithmetic and comparison operators" begin
    # broadcast semantics, no dots needed; dotted spellings are aliases.
    # Comparison results are Bool columns -- legal pivot keys on their own.
    a = [1.0, 2.0, 3.0]
    b = [3.0, 2.0, 1.0]
    for (op, spec, expected) in Any[
        ("+",  "a + b",  [4.0, 4.0, 4.0]),
        ("-",  "a - b",  [-2.0, 0.0, 2.0]),
        ("*",  "a * b",  [3.0, 4.0, 3.0]),
        ("/",  "a / b",  [1/3, 1.0, 3.0]),
        ("^",  "a ^ b",  [1.0, 4.0, 3.0]),
        ("==", "a == b", [false, true, false]),
        ("!=", "a != b", [true, false, true]),
        ("<",  "a < b",  [true, false, false]),
        ("<=", "a <= b", [true, true, false]),
        (">",  "a > b",  [false, false, true]),
        (">=", "a >= b", [false, true, true]),
        ("≠",  "a ≠ b",  [true, false, true]),
        ("≤",  "a ≤ b",  [true, true, false]),
        ("≥",  "a ≥ b",  [false, true, true]),
    ]
        @testset "$op" begin
            @test parsedim(spec).f(a, b) ≈ expected
        end
    end
    # dotted spellings bind to the same broadcasting closure
    @test dim"a .+ b".f(a, b) == dim"a + b".f(a, b)
    @test dim"a .< b".f(a, b) == dim"a < b".f(a, b)
end

@testset "in" begin
    # membership: the item broadcasts, the collection is Ref-protected --
    # compared as a WHOLE, not zipped elementwise against the item vector
    @test dim"x in [1, 2, 5]".f([1, 2, 3, 5]) == [true, true, false, true]
    @test dim"x in [1, 2, 5]".cols == [:x]        # the literal array is not a column

    # the collection can itself be a column -- membership against its whole
    # set of values, still not a row-by-row zip (lengths need not even match)
    @test dim"x in y".f([1, 2, 3], [2, 3, 3]) == [false, true, true]

    # missing item propagates (Julia's own `in` semantics)
    @test isequal(dim"x in [1, 2, 5]".f([1, missing]), [true, missing])

    # the replacement for a chain of == / || checks, composed with where
    lab = dim"where(x in [1, 2, 5])".f([1, 3])
    @test string.(lab) == ["x in [1, 2, 5]", "Not x in [1, 2, 5]"]

    @testset "∈" begin   # Unicode spelling, same closure as `in`
        @test dim"x ∈ [1, 2, 5]".f([1, 2, 3, 5]) == dim"x in [1, 2, 5]".f([1, 2, 3, 5])
    end

    @testset "∉" begin   # negation
        @test dim"x ∉ [1, 2, 5]".f([1, 2, 3, 5]) == [false, false, true, false]
        @test isequal(dim"x ∉ [1, 2, 5]".f([1, missing]), [false, missing])
        lab = dim"where(x ∉ [1, 2, 5])".f([1, 3])
        @test string.(lab) == ["Not x ∉ [1, 2, 5]", "x ∉ [1, 2, 5]"]
    end
end

@testset "discretize" begin
    q1 = dim"discretize(TestScr, quantiles=[.25,.5,.75])"
    q2 = dim"discretize(TestScr; quantiles=[.25,.5,.75])"
    @test q1.cols == [:TestScr] && q2.cols == [:TestScr]
    v = [1.0, 2.0, 3.0, 4.0]
    @test string.(q1.f(v)) == string.(q2.f(v))
    b = dim"discretize(x, [0, 10], boundedness = :boundedbelow)"
    @test string(b.f([5.0])[1]) == "1. [0,10)"
end

@testset "topnames" begin
    t = dim"topnames(District, TestScr, 5)"
    labels = t.f(["a", "b", "c"], [30.0, 10.0, 20.0])
    @test string.(labels) == ["1. a", "3. b", "2. c"]
    @test labels isa CategoricalArray

    # pivot-kind end-to-end within a chain (context = left of the chain)
    df = sddf()
    out = dim(df, [:County, :top1 => dim"topnames(District, TestScr, 1)"])
    @test string.(out.top1) == ["Others", "Others", "1. d2", "Others", "1. d4", "Others"]
end

@testset "quantiles" begin
    # verb semantics: label each element by its quantile bucket
    v = [1.0, 2.0, 3.0, 4.0]
    q = quantiles(v, [0.25, 0.5, 0.75])
    @test string.(q) == ["1. [0%, 25%)", "2. [25%, 50%)", "3. [50%, 75%)", "4. [75%, 100%]"]
    @test q isa CategoricalArrays.CategoricalArray

    # leftequal = false flips the interval closure
    q2 = quantiles(v, [0.25, 0.5, 0.75]; leftequal = false)
    @test string(q2[1]) == "1. [0%, 25%]"
    @test string(q2[2]) == "2. (25%, 50%]"

    # prefix / suffix decorate the interval
    @test string(quantiles(v, [0.5]; prefix = "scr")[1]) == "1. scr [0%, 50%)"
    @test string(quantiles(v, [0.5]; suffix = "tile")[4]) == "2. [50%, 100%] tile"

    # non-integer percent boundary, missing passthrough
    @test string(quantiles(v, [0.125])[4]) == "2. [12.5%, 100%]"
    @test ismissing(quantiles([1.0, missing, 3.0], [0.5])[2])

    # ngroups convenience: equal-width boundaries 1/n .. (n-1)/n
    @test string.(quantiles(v; ngroups = 4)) == string.(quantiles(v, [0.25, 0.5, 0.75]))
    @test string.(quantiles(v)) == string.(quantiles(v; ngroups = 4))   # bare = quartiles
    @test string(quantiles(v; ngroups = 2)[1]) == "1. [0%, 50%)"
    # terciles hit the 2-decimal percent cap
    @test string.(quantiles([1.0, 2.0, 3.0]; ngroups = 3)) ==
          ["1. [0%, 33.33%)", "2. [33.33%, 66.67%)", "3. [66.67%, 100%]"]
    # string-spec forms (window kind, kwarg in both spellings)
    @test string.(dim"quantiles(x, ngroups = 4)".f(v)) == string.(quantiles(v; ngroups = 4))
    @test string.(dim"quantiles(x; ngroups = 2)".f(v)) == string.(quantiles(v; ngroups = 2))

    # validation
    @test_throws ErrorException quantiles(v, [0.5, 0.25])
    @test_throws ErrorException quantiles(v, [0.0, 0.5])
    @test_throws ErrorException quantiles(v, Float64[])
    @test_throws ErrorException quantiles(v, [0.5]; ngroups = 4)   # mutually exclusive
    @test_throws ErrorException quantiles(v; ngroups = 1)

    # pivot kind comes from the universal groupby modifier
    df = sddf()
    s = dim"quantiles(TestScr, [.25,.5,.75]) |> groupby(District)"
    @test s.by == [:District]
    d = PivotDim(:qd, s)
    @test d.by == [:District]
    @test dependencies(d) == [:TestScr]

    # whole-frame: district TestScr sums [d1=30, d2=50, d3=30, d4=40, d5=10]
    out = dim(df, [d])
    @test string.(out.qd) == ["3. [50%, 75%)", "3. [50%, 75%)", "4. [75%, 100%]",
                              "3. [50%, 75%)", "4. [75%, 100%]", "1. [0%, 25%)"]

    # trusted Expr form: dimspec is the Julia-side equivalent of the modifier
    d2 = PivotDim(:qd, :( quantiles(:TestScr, [.25, .5, .75]) ); by = :District)
    @test d2.by == [:District]
    @test isequal(string.(dim(df, [d2]).qd), string.(out.qd))

    # in a chain: pivot kind + left context
    keycols, dims = DataFrameAggrSpec.normalize_chain(
        [:County, :qd => dim"quantiles(TestScr, [.5]) |> groupby(District)"])
    @test dims[1] isa PivotDim
    @test dims[1].by == [:District] && dims[1].context == [:County]

    # the old 3rd-argument form is gone, and the parser says so directly:
    # arity is checked against the verb's method table at parse time, so this
    # no longer waits to become a MethodError inside the kernel
    @test_throws SpecError dim"quantiles(TestScr, [.5], [District])"
    err = try
        parsedim("quantiles(TestScr, [.5], [District])")
    catch e
        e
    end
    @test occursin("takes 1 to 2 positional arguments, got 3", err.msg)
end

@testset "Boolean operators (&&, ||, !)" begin
    # && / || translate to pure elementwise and/or -- and bind looser than
    # comparisons, so compound conditions need no parentheses
    @test dim"a > 1 && a < 4".f([0, 2, 5]) == [false, true, false]
    @test dim"a < 1 || a > 4".f([0, 2, 5]) == [true, false, true]
    @test dim"a > 1 && a < 4 || a == 0".f([0, 2, 5]) == [true, true, false]

    # Kleene logic: missing propagates instead of throwing
    @test isequal(dim"a > 1 && b > 1".f([2, 2], [missing, 0]), [missing, false])
    @test isequal(dim"a > 1 || b > 1".f([0, 0], [missing, 2]), [missing, true])

    @testset "!" begin   # negates elementwise, on comparisons and Bool columns
        @test dim"!(a > 1)".f([0, 2]) == [true, false]
        @test dim"!flag".f([true, false]) == [false, true]
    end
end

@testset "date bucketing verbs" begin
    d = Date(2025, 7, 9)
    for (op, got, expected) in Any[
        ("yyyy",   yyyy(d),   "2025"),
        ("yyyyq",  yyyyq(d),  "2025Q3"),
        ("yyq",    yyq(d),    "25Q3"),
        ("yyyymm", yyyymm(d), "202507"),
        ("yymm",   yymm(d),   "2507"),
    ]
        @testset "$op" begin @test got == expected end
    end
    @test yyyymm(d, "/") == "2025/07"
    @test yymm(d, "-") == "25-07"
    @test yyyymm(DateTime(2026, 1, 2, 13, 30)) == "202601"   # DateTime too
    @test ismissing(yyyy(missing))
    @test ismissing(yymm(missing, "/"))

    # elementwise through the DSL; missing propagates
    ds = Union{Missing,Date}[Date(2025, 12, 31), missing, Date(2026, 1, 1)]
    @test isequal(dim"yyyymm(t)".f(ds), ["202512", missing, "202601"])
    @test dim"yyyymm(t, \"/\")".f([d]) == ["2025/07"]
    @test dim"yyq(t)".f([d]) == ["25Q3"]

    # THE property: lexical order is chronological order
    seq = [Date(2025, 9, 1), Date(2025, 10, 2), Date(2026, 2, 3)]
    @test issorted(yyyy.(seq))
    @test issorted(yyyyq.(seq))
    @test issorted(yyyymm.(seq))
    @test issorted(yyyymm.(seq, "/"))   # delimiter broadcasts as a scalar

    # as a chain key across a year boundary (calendar month, not month-of-year)
    df = DataFrame(t = [Date(2025, 12, 30), Date(2025, 12, 31), Date(2026, 1, 5)],
                   sales = [1.0, 2.0, 4.0])
    out = agg(df, [:ym => dim"yyyymm(t)"]; allbut = [:t])
    @test sort(out.ym) == ["202512", "202601"]
    @test out.sales[sortperm(out.ym)] == [3.0, 4.0]
end

@testset "ismissing / coalesce (dimension side)" begin
    # flag: a Bool pivot key, and it composes with !
    @test isequal(dim"ismissing(x)".f([1, missing, 3]), [false, true, false])
    @test dim"!ismissing(x)".f([1, missing]) == [true, false]

    # replace: fallback cascade -- columns first, literal default last
    @test isequal(dim"coalesce(a, b, 0)".f([1, missing, missing],
                                           [10, 20, missing]),
                  [1, 20, 0])

    # Kleene interplay: ismissing rescues the missing branch of ||
    @test isequal(dim"ismissing(x) || x > 3".f([1, missing, 5]),
                  [false, true, true])

    # self-labeling missing flag via where
    lab = dim"where(ismissing(comment))".f(["a", missing])
    @test string(lab[1]) == "Not ismissing(comment)"
    @test string(lab[2]) == "ismissing(comment)"
end

@testset "where" begin
    # default labels are the condition's source text; missing labels missing
    w = dim"where(sales > 100)"
    @test w.fname == :where && w.cols == [:sales]
    lab = w.f(Union{Missing,Float64}[50.0, 150.0, missing])
    @test string(lab[1]) == "Not sales > 100"
    @test string(lab[2]) == "sales > 100"
    @test ismissing(lab[3])
    @test lab isa CategoricalArray
    @test levels(lab) == ["sales > 100", "Not sales > 100"]   # true sorts first

    # custom labels; false_label derives from true_label
    @test string.(dim"where(x > 0, true_label = \"pos\")".f([1, -1])) ==
          ["pos", "Not pos"]
    @test string.(dim"where(x > 0; true_label = \"pos\", false_label = \"neg\")".f([1, -1])) ==
          ["pos", "neg"]

    # compound condition inside where, label text included
    cw = dim"where(x > 1 && x < 4)"
    @test string.(cw.f([0, 2, 5])) ==
          ["Not x > 1 && x < 4", "x > 1 && x < 4", "Not x > 1 && x < 4"]

    # scalar (partition-level) condition returns the bare label to broadcast
    @test dim"where(sum(sales) > 100)".f([60.0, 70.0]) == "sum(sales) > 100"
    @test dim"where(sum(sales) > 100)".f([1.0, 2.0]) == "Not sum(sales) > 100"

    # window kind end-to-end, and the flag as an agg key
    df = DataFrame(region = ["E", "E", "W", "W", "W"],
                   sales  = [10.0, 20.0, 5.0, 15.0, 30.0])
    out = dim(df, [:big => dim"where(sales > 12)"])
    @test string.(out.big) == ["Not sales > 12", "sales > 12", "Not sales > 12",
                               "sales > 12", "sales > 12"]
    r = agg(df, [:region, :big => dim"where(sales > 12)"]; cols = [:sales])
    @test nrow(r) == 4
    @test r.sales == [10.0, 20.0, 5.0, 45.0]   # (E,not) (E,big) (W,not) (W,big)

    # pivot kind via the universal groupby modifier: flag GROUPS by their
    # aggregates (district TestScr sums: C1 d1=30, d2=50, d3=30; C2 d4=40, d5=10)
    dfx = sddf()
    gb = dim(dfx, [:County, :bigd => dim"where(TestScr > 35) |> groupby(District)"])
    @test string.(gb.bigd) == ["Not TestScr > 35", "Not TestScr > 35",
                               "TestScr > 35", "Not TestScr > 35",
                               "TestScr > 35", "Not TestScr > 35"]

    # arity and label validation
    @test_throws SpecError parsedim("where()")
    @test_throws SpecError parsedim("where(a > 1, b > 1)")
    @test_throws ErrorException dim"where(x > 1, true_label = \"a\", false_label = \"a\")".f([2])
end

