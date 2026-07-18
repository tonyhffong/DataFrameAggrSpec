using DataFrameAggrSpec
using DataFrames
using CategoricalArrays
using Statistics
using Test

import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

# Per-operator tests for SAFE DIMENSION operators, mirroring
# docs/safe-dimension-operators.md. When a new dimension operator is added to
# the SafeOps registry, its tests belong here; the DSL machinery itself
# (grammar, rejections, integration, caching) is covered in test/safe.jl.

sddf() = DataFrame(
    County = ["C1", "C1", "C1", "C1", "C2", "C2"],
    District = ["d1", "d1", "d2", "d3", "d4", "d5"],
    TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
    EnrlTot = [100, 100, 50, 30, 80, 20],
)

@testset "group-relative and elementwise operators" begin
    @test dim"sales / sum(sales)".f([1.0, 3.0]) == [0.25, 0.75]   # share of group
    @test dim"sum(sales)".f([1.0, 3.0]) == 4.0                    # broadcast group total
    @test dim"cumsum(sales)".f([1, 2, 3]) == [1, 3, 6]
    @test dim"cumprod(g)".f([2, 3]) == [2, 6]
    @test isequal(dim"lag(x)".f([1, 2, 3]), [missing, 1, 2])
    @test isequal(dim"lead(x, 2)".f([1, 2, 3]), [3, missing, missing])
    @test dim"round(sales / sum(sales), digits = 2)".f([1.0, 2.0]) == [0.33, 0.67]
    @test dim"sales > mean(sales)".f([1.0, 3.0]) == [false, true]  # above-average flag
    @test dim"max(sales, 0)".f([-1.0, 2.0]) == [0.0, 2.0]          # elementwise clamp
    @test dim"countuniq(District)".f(["a", "b", "a"]) == 2         # distinct count broadcast
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

    # validation
    @test_throws ErrorException quantiles(v, [0.5, 0.25])
    @test_throws ErrorException quantiles(v, [0.0, 0.5])
    @test_throws ErrorException quantiles(v, Float64[])

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

    # the old 3rd-argument form is gone: it parses as a window dim whose kernel
    # then fails at the verb (no such method)
    @test_throws MethodError dim(df, [:bad => dim"quantiles(TestScr, [.5], [District])"])
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

    # ! negates elementwise, on comparisons and on Bool columns
    @test dim"!(a > 1)".f([0, 2]) == [true, false]
    @test dim"!flag".f([true, false]) == [false, true]
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
    @test_throws ErrorException parsedim("where()")
    @test_throws ErrorException parsedim("where(a > 1, b > 1)")
    @test_throws ErrorException dim"where(x > 1, true_label = \"a\", false_label = \"a\")".f([2])
end

@testset "orderby modifier (behavior)" begin
    df = DataFrame(region = ["E", "E", "W", "W", "W"],
                   date   = [1, 2, 1, 2, 3],
                   sales  = [10.0, 20.0, 5.0, 15.0, 30.0])

    # in-string orderby ≡ dimspec(...; order = ...)
    a = dim(df, [:region, :cum => dim"cumsum(sales) |> orderby(date)"])
    b = dim(df, [:region, :cum => dimspec(dim"cumsum(sales)"; order = :date)])
    @test a.cum == b.cum == [10.0, 30.0, 5.0, 20.0, 50.0]

    # ∘ spelling + descending direction
    c = dim(df, [:region, :cum2 => dim"cumsum(sales) ∘ orderby(date => :desc)"])
    @test c.cum2 == [30.0, 20.0, 50.0, 45.0, 30.0]

    # THE motivating case: ordering expressible from a pure-string config chain
    d = dim(df, ["region", ["cum", "cumsum(sales) |> orderby(date)"]])
    @test d.cum == a.cum

    # conflict between in-string orderby and dimspec order is an error
    @test_throws ErrorException dim(df, [:region,
        :x => dimspec(dim"cumsum(sales) |> orderby(date)"; order = :sales)])

    # orderby on a pivot dim is legal since 0.8.4: it means GROUP ordering
    # (a no-op for order-insensitive verbs like topnames, same as a pointless
    # orderby on a window sum)
    (_, pdims) = DataFrameAggrSpec.normalize_chain(
        [:t => dim"topnames(region, sales, 2) |> orderby(date)"])
    @test pdims[1] isa PivotDim
    @test pdims[1].order == [:date => false]

    # the orderby columns count as dependencies
    (_, dims) = DataFrameAggrSpec.normalize_chain(
        [:region, :cum => dim"cumsum(sales) |> orderby(date)"])
    @test dependencies(dims[1]) == [:sales, :date]
end

@testset "orderby on pivot dims (group ordering)" begin
    # encounter order is W-first on purpose: sorting must be real, not luck
    df = DataFrame(region = ["W", "W", "W", "E", "E"],
                   date   = [1, 2, 3, 1, 2],
                   sales  = [5.0, 15.0, 30.0, 10.0, 20.0])
    # region sales sums: W = 50, E = 30

    # THE Pareto idiom: running total over groups, largest group first
    p = dim(df, [:cum => dim"cumsum(sales) |> groupby(region) |> orderby(sales => :desc)"])
    @test p.cum == [50.0, 50.0, 50.0, 80.0, 80.0]

    # ascending (smallest group first)
    a = dim(df, [:cum => dim"cumsum(sales) |> groupby(region) |> orderby(sales)"])
    @test a.cum == [80.0, 80.0, 80.0, 30.0, 30.0]

    # ordering by the group KEY (E before W, though W is encountered first)
    k = dim(df, [:cum => dim"cumsum(sales) |> groupby(region) |> orderby(region)"])
    @test k.cum == [80.0, 80.0, 80.0, 30.0, 30.0]

    # modifier textual order is NON-semantic (design/compound-modifiers.md)
    q = dim(df, [:cum => dim"cumsum(sales) |> orderby(sales => :desc) |> groupby(region)"])
    @test q.cum == p.cum

    # dimspec is the Julia-side equivalent, for safe and trusted specs alike
    j = dim(df, [:cum => dimspec(dim"cumsum(sales)";
                                 by = :region, kind = :pivot, order = :sales => :desc)])
    @test j.cum == p.cum
    t = dim(df, [:cum => dimspec(:( cumsum(:sales) );
                                 by = :region, kind = :pivot, order = :sales => :desc)])
    @test t.cum == p.cum

    # order column the spec never references: aggregated per hints, and a dependency
    df2 = DataFrame(region = ["W", "W", "E"], sales = [1.0, 1.0, 5.0],
                    profit = [1.0, 1.0, 9.0])
    # sums: sales W=2, E=5 ; profit W=2, E=9 -> desc by profit puts E first
    h = dim(df2, [:cum => dim"cumsum(sales) |> groupby(region) |> orderby(profit => :desc)"])
    @test h.cum == [7.0, 7.0, 5.0]
    (_, hd) = DataFrameAggrSpec.normalize_chain(
        [:x => dim"cumsum(sales) |> groupby(region) |> orderby(profit)"])
    @test dependencies(hd[1]) == [:sales, :profit]

    # context partitioning: per County, districts sorted by their sums desc
    # C1 sums: d2=50, then the d1=30/d3=30 tie stays stable (d1 first)
    #   -> cum: d2=50, d1=80, d3=110 ; C2: d4=40 -> 40, d5 -> 50
    dfx = sddf()
    c = dim(dfx, [:County,
                  :cum => dim"cumsum(TestScr) |> groupby(District) |> orderby(TestScr => :desc)"])
    @test c.cum == [80.0, 80.0, 50.0, 110.0, 40.0, 50.0]

    # conflicts are still errors: order in-string AND via dimspec
    @test_throws ErrorException DataFrameAggrSpec.normalize_chain([:bad =>
        dimspec(dim"cumsum(sales) |> groupby(region) |> orderby(date)"; order = :sales)])
end

@testset "groupby modifier (behavior)" begin
    df = sddf()

    # no groupby = per-row window bucketing
    df0 = DataFrame(x = [1.0, 2.0, 3.0, 4.0])
    out = dim(df0, :q => dim"quantiles(x, [.25,.5,.75])")
    @test string.(out.q) ==
          ["1. [0%, 25%)", "2. [25%, 50%)", "3. [50%, 75%)", "4. [75%, 100%]"]

    # window kind partitions by the chain's left context
    keycols, dims = DataFrameAggrSpec.normalize_chain(
        [:County, :rq => dim"quantiles(TestScr, [.5])"])
    @test dims[1] isa WindowDim
    @test dims[1].by == [:County]
    out3 = dim(df, [:County, :rq => dim"quantiles(TestScr, [.5])"])
    @test string.(out3.rq) == ["1. [0%, 50%)", "1. [0%, 50%)", "2. [50%, 100%]",
                               "2. [50%, 100%]", "2. [50%, 100%]", "1. [0%, 50%)"]

    # discretize goes pivot via the modifier -- no dimspec needed
    # (district EnrlTot sums: d1=200, d2=50, d3=30, d4=80, d5=20)
    df4 = dim(df, [:size => dim"discretize(EnrlTot, [35, 60]) |> groupby(District)"])
    @test string.(df4.size) == ["3. 60+", "3. 60+", "2. 35…59", "1. ≤34", "3. 60+", "1. ≤34"]

    # array form of the keys, and the ∘ spelling
    df5 = dim(df, [:size2 => dim"discretize(EnrlTot, [35, 60]) ∘ groupby([District])"])
    @test string.(df5.size2) == string.(df4.size)

    # an UNREGISTERED host verb classifies via groupby -- zero registration
    registerop!(:hilo,
        (measure,) -> [m > Statistics.median(measure) ? "hi" : "lo" for m in measure])
    hf = dim(df, [:County, :half => dim"hilo(TestScr) |> groupby(District)"])
    # per County, district sums: C1 [d1=30, d2=50, d3=30] (median 30),
    # C2 [d4=40, d5=10] (median 25)
    @test hf.half == ["lo", "lo", "hi", "lo", "hi", "lo"]

    # conflicts are errors, never precedence
    @test_throws ErrorException dim(df, [:x =>
        dimspec(dim"discretize(EnrlTot, [35]) |> groupby(District)"; by = :County)])
    @test_throws ErrorException DataFrameAggrSpec.normalize_chain(
        [:bad => dim"topnames(District, TestScr, 5) |> groupby(County)"])
    gob = DataFrameAggrSpec.normalize_chain(
        [:ok => dim"discretize(EnrlTot, [35]) |> groupby(District) |> orderby(TestScr)"])[2][1]
    @test gob.by == [:District] && gob.order == [:TestScr => false]   # both modifiers
    @test_throws ErrorException dim(df, [:bad =>
        dimspec(dim"discretize(EnrlTot, [35]) |> groupby(District)"; kind = :window)])
end
