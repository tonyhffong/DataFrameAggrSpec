using DataFrameAggrSpec
using DataFrames
using CategoricalArrays
using Statistics
using Dates
using Test

import DataFrameAggrSpec: WindowDim, PivotDim, dependencies   # internals, white-box tests

# The MODIFIER system -- `spec |> orderby(...)` / `spec |> groupby(...)`:
# how they parse (metadata, never called) and what they do to the engine
# (window row ordering, pivot grouping, pivot GROUP ordering), plus the
# nested `inner |> groupby(k)` composite-reduction node. Operator vocabulary
# lives in test/safe-aggr.jl / test/safe-dim.jl.

smdf() = DataFrame(
    County = ["C1", "C1", "C1", "C1", "C2", "C2"],
    District = ["d1", "d1", "d2", "d3", "d4", "d5"],
    TestScr = [10.0, 20.0, 50.0, 30.0, 40.0, 10.0],
    EnrlTot = [100, 100, 50, 30, 80, 20],
)

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
    @test dim"rank(TestScr) |> groupby(District, County)".by == [:District, :County]

    # groupby accepts COMPUTED keys too, exactly like the nested composite-
    # aggregation groupby (compile_grouped) already did -- finding #3
    gk = dim"cumsum(sales) |> groupby(yyyymm(date))"
    @test length(gk.by) == 1
    @test gk.by[1] isa DataFrameAggrSpec.GroupByKey
    @test gk.by[1].cols == [:date]
    # mixed bare-column + computed keys in one groupby
    gmix = dim"cumsum(sales) |> groupby(region, yyyymm(date))"
    @test gmix.by[1] == :region
    @test gmix.by[2] isa DataFrameAggrSpec.GroupByKey && gmix.by[2].cols == [:date]
    # the [ ... ] array spelling stays symbol-only -- mixing an expression in
    # errors with a redirect rather than silently doing something surprising
    @test_throws SpecError dim"cumsum(sales) |> groupby([yyyymm(date)])"

    # both modifiers parse together (groupby -> pivot kind, orderby -> group
    # ordering; textual order is non-semantic, see design/compound-modifiers.md)
    gb = dim"discretize(x, [1]) |> groupby(g) |> orderby(d)"
    @test gb.by == [:g] && gb.order == [:d => false]

    modreject(f, s, needle) = begin
        err = try
            f(s)
            nothing
        catch e
            e
        end
        err isa Exception && occursin(needle, sprint(showerror, err))
    end
    @test modreject(parsedim, "cumsum(sales) |> orderby(date) |> orderby(x)",
                    "duplicate orderby")
    @test modreject(parsedim, "orderby(date) |> cumsum(sales)",
                    "must follow the spec")
    @test modreject(parsedim, "cumsum(sales) |> orderby()",
                    "at least one column")
    @test modreject(parsedim, "cumsum(sales) |> foo(x)",
                    "expected a modifier call")
    @test modreject(parsedim, "sum(a |> b)", "attaches a groupby")  # nested, non-modifier rhs

    # orderby IS legal at an aggr spec's top level (unlike groupby, below) --
    # peeled with the SAME peel_modifiers dim specs use
    s = parseaggr("first(_) |> orderby(date)")
    @test s.order == [:date => false]
    @test s.fname == :first && s.cols == [:_]
    @test parseaggr("first(_) |> orderby(date => :desc)").order == [:date => true]
    @test parseaggr("first(_) |> orderby(region, date)").order ==
          [:region => false, :date => false]
    @test modreject(parseaggr, "first(_) |> orderby(date) |> orderby(x)",
                    "duplicate orderby")
    # `_` names the aggregation target, bound only when the spec is applied
    # -- it has no meaning as a fixed row-order key
    @test modreject(parseaggr, "last(sum(_) |> groupby(year)) |> orderby(_)",
                    "no meaning in orderby")
    @test modreject(parsedim, "mean(x) |> groupby(a) |> groupby(b)",
                    "duplicate groupby")
    @test modreject(parsedim, "mean(x) |> groupby()", "at least one column")
    @test modreject(parsedim, "mean(x) |> groupby([])", "at least one column")
    @test modreject(parsedim, "mean(x) |> groupby(3)", "got the literal 3")
    @test modreject(parsedim, "mean(x) |> groupby([yyyymm(date)])", "array form")
    # top-level grouped reduction in an aggr spec: one value per key is not an
    # aggregate -- the error teaches the nested composite form
    @test modreject(parseaggr, "sum(_) |> groupby(g)", "NEST it in a reduction")

    # NESTED grouped reductions (composite aggregation) have their own errors
    @test modreject(parseaggr, "mean(sum(_) |> orderby(year))",
                    "ordered by their groupby keys")
    @test modreject(parseaggr, "mean(sum(_) |> groupby())", "at least one key")
    @test modreject(parseaggr, "mean(sum(_) |> groupby(3))", "got the literal 3")
    @test modreject(parseaggr, "mean(sum(_) |> groupby(k = v))",
                    "not keyword arguments")
    @test modreject(parseaggr, "mean(sum(_) |> groupby(a) |> groupby(b))",
                    "multi-key grouping is groupby(k1, k2, ...)")
    @test modreject(parseaggr, "mean(groupby(year) |> sum(_))",
                    "must follow the spec")
    @test modreject(parseaggr, "mean(sum(_) |> groupby)", "takes columns")
    @test modreject(parseaggr, "mean(sum(_) |> gropby(year))",
                    "did you mean 'groupby'?")
    @test_throws ErrorException registerop!(:orderby, identity)   # reserved names
    @test_throws ErrorException registerop!(:groupby, identity)
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

@testset "orderby on aggregation specs (behavior)" begin
    # encounter order deliberately does NOT match date order, in either
    # group -- sorting must be real, not luck (same discipline as the
    # pivot-orderby tests above)
    df = DataFrame(region = ["E", "E", "W", "W", "W"],
                   date   = [2, 1, 3, 1, 2],
                   sales  = [20.0, 10.0, 30.0, 5.0, 15.0])

    # first/last respect the DECLARED order, not frame order
    out = agg(df, :region; cols = [:sales => aggr"first(_) |> orderby(date)" => :early,
                                    :sales => aggr"last(_) |> orderby(date)" => :late])
    @test out.early == [10.0, 5.0]    # E: date1 -> 10 ; W: date1 -> 5
    @test out.late  == [20.0, 30.0]   # E: date2 -> 20 ; W: date3 -> 30

    # descending direction flips which end "first" reads from
    outd = agg(df, :region;
               cols = [:sales => aggr"first(_) |> orderby(date => :desc)" => :latest])
    @test outd.latest == out.late   # same rows as ascending `last`

    # order-insensitive verb: orderby is a silent no-op, not an error
    outs = agg(df, :region; cols = [:sales => aggr"sum(_) |> orderby(date)" => :total])
    @test outs.total == [30.0, 50.0]

    # multi-key: a second sort key breaks ties a single key cannot. Frame
    # order among the date==1 ties is id DESCENDING (id2 before id1), so a
    # single-key sort (stable) and a two-key sort disagree.
    df2 = DataFrame(region = ["E", "E", "E"], date = [2, 1, 1], id = [9, 2, 1],
                    sales = [30.0, 20.0, 10.0])
    single = agg(df2, :region; cols = [:sales => aggr"first(_) |> orderby(date)" => :x])
    @test single.x == [20.0]        # date-only: ties keep frame order -> id2's row
    multi = agg(df2, :region; cols = [:sales => aggr"first(_) |> orderby(date, id)" => :x])
    @test multi.x == [10.0]         # id breaks the tie -> id1's row

    # direct liftAggrSpecToFunc check against a shuffled frame
    shuffled = DataFrame(date = [3, 1, 2], sales = [30.0, 10.0, 20.0])
    fspec = liftAggrSpecToFunc(:sales, aggr"first(_) |> orderby(date)")
    @test Base.invokelatest(fspec, shuffled) == 10.0
    lspec = liftAggrSpecToFunc(:sales, aggr"last(_) |> orderby(date)")
    @test Base.invokelatest(lspec, shuffled) == 30.0

    # columns referenced only via orderby are validated too (checkcols)
    @test checkcols(aggr"first(_) |> orderby(date)", [:sales, :date]) isa SafeAggrSpec
    @test_throws SpecError checkcols(aggr"first(_) |> orderby(dat)", [:sales, :date])

    # composing top-level orderby with a NESTED composite groupby reduction:
    # orderby pre-sorts the WHOLE group, which decides row order WITHIN each
    # composite subgroup too -- so it governs the tie-break of an
    # order-sensitive verb (first) nested inside the reduction, even though
    # orderby cannot attach directly to the nested groupby itself.
    #   year 2020: t=2(20.0), t=1(10.0)  -> earliest t is 10.0
    #   year 2021: t=5(40.0), t=3(30.0)  -> earliest t is 30.0
    #   last(...) picks the LATEST year (2021) -> earliest-t value there
    panel = DataFrame(year = [2021, 2020, 2020, 2021], t = [5, 2, 1, 3],
                      val  = [40.0, 20.0, 10.0, 30.0])
    ordered = liftAggrSpecToFunc(:val, aggr"last(first(_) |> groupby(year)) |> orderby(t)")
    @test Base.invokelatest(ordered, panel) == 30.0
    # without orderby, the same spec is at the mercy of frame order (here,
    # the FIRST-encountered 2021 row, t=5 -> 40.0) -- not a meaningful answer
    unordered = liftAggrSpecToFunc(:val, aggr"last(first(_) |> groupby(year))")
    @test Base.invokelatest(unordered, panel) == 40.0
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
    dfx = smdf()
    c = dim(dfx, [:County,
                  :cum => dim"cumsum(TestScr) |> groupby(District) |> orderby(TestScr => :desc)"])
    @test c.cum == [80.0, 80.0, 50.0, 110.0, 40.0, 50.0]

    # conflicts are still errors: order in-string AND via dimspec
    @test_throws ErrorException DataFrameAggrSpec.normalize_chain([:bad =>
        dimspec(dim"cumsum(sales) |> groupby(region) |> orderby(date)"; order = :sales)])
end

@testset "groupby modifier (behavior)" begin
    df = smdf()

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

    # groupby accepts a COMPUTED key too (finding #3): the district column
    # exists on the frame but isn't the grouping key at all here -- rows are
    # bucketed by their yyyymm(date) group's EnrlTot total instead. Proves
    # the gensym-materialization path works standalone and doesn't leak a
    # synthetic column into the output.
    dfd = DataFrame(
        District = ["d1", "d1", "d2", "d3", "d4", "d5"],
        date     = Date.(2024, [1, 1, 1, 2, 2, 3], 1),
        EnrlTot  = [100, 100, 50, 30, 80, 20],
    )
    dfk = dim(dfd, [:size => dim"discretize(EnrlTot, [50, 150]) |> groupby(yyyymm(date))"])
    @test string.(dfk.size) ==
          ["3. 150+", "3. 150+", "3. 150+", "2. 50…149", "2. 50…149", "1. ≤49"]
    @test propertynames(dfk) == [:District, :date, :EnrlTot, :size]   # no leaked gensym column

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

@testset "nested grouped reduction (dim side)" begin
    # a |> groupby NESTED inside a dim spec is COMPUTATIONAL grouping -- a
    # grouped-reduction vector feeding the outer expression -- not the
    # top-level pivot modifier: the spec stays window kind and its scalar
    # result broadcasts to the partition
    df = DataFrame(
        county = ["c1", "c1", "c1", "c2", "c2"],
        year   = [2020, 2020, 2021, 2020, 2021],
        pop    = [10.0, 20.0, 40.0, 5.0, 15.0],
    )
    keycols, dims = DataFrameAggrSpec.normalize_chain(
        [:county, :avgyr => dim"mean(sum(pop) |> groupby(year))"])
    @test dims[1] isa WindowDim                    # nested groupby ≠ pivot kind
    @test :year in dependencies(dims[1])           # nested key is a dependency
    out = dim(df, [:county, :avgyr => dim"mean(sum(pop) |> groupby(year))"])
    # c1: yearly sums 30, 40 -> 35;  c2: 5, 15 -> 10
    @test out.avgyr == [35.0, 35.0, 35.0, 10.0, 10.0]
end
