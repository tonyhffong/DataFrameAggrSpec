using DataFrameAggrSpec
using DataFrames
using Dates
using Statistics
using Test

# Per-operator tests for SAFE AGGREGATION operators, mirroring the table in
# docs/safe-aggregation-operators.md -- ONE @testset per operator, named for
# the operator exactly as the registry spells it, so `@testset "<op>"` is
# greppable. The "every shipped operator has a test" testset in
# test/safe-grammar.jl enforces that; a new operator without one fails there.
# Elsewhere: grammar/rejections/errors -> test/safe-grammar.jl,
# orderby/groupby -> test/safe-modifiers.jl, wiring -> test/safe-integration.jl.

@testset "reductions" begin
    # table-driven so each operator still gets a @testset NAMED for it (the
    # first column) -- greppable, and visible individually in test output
    v = [4.0, 1.0, 3.0, 2.0]
    for (op, spec, input, expected) in Any[
        ("sum",         "sum",                 v,                10.0),
        ("prod",        "prod(_)",             [2, 3],           6),
        ("mean",        "mean(_)",             v,                2.5),
        ("median",      "median(_)",           v,                2.5),
        ("std",         "std(_)",              v,                Statistics.std(v)),
        ("var",         "var(_)",              v,                Statistics.var(v)),
        ("quantile",    "quantile(_, 0.75)",   v,                Statistics.quantile(v, 0.75)),
        ("minimum",     "minimum(_)",          v,                1.0),
        ("maximum",     "maximum(_)",          v,                4.0),
        ("extrema",     "extrema(_)",          v,                (1.0, 4.0)),
        ("length",      "length(_)",           v,                4),
        ("nrow",        "nrow",                v,                4),
        ("count",       "count(_ > 2)",        v,                2),
        ("any",         "any(_ > 3)",          v,                true),
        ("all",         "all(_ > 0)",          v,                true),
        ("first",       "first(_)",            v,                4.0),
        ("last",        "last(_)",             v,                2.0),
        ("skipmissing", "sum(skipmissing(_))", [1, missing, 2],  3),
    ]
        @testset "$op" begin
            @test isequal(parseaggr(spec).f(input), expected)
        end
    end
end

@testset "uniqvalue" begin
    @test aggr"uniqvalue(_)".f(["a", "a"]) == "a"
    @test ismissing(aggr"uniqvalue(_)".f(["a", "b"]))   # not unique -> missing
end

@testset "unionall" begin
    @test sort(aggr"unionall(_)".f([[1, 2], [2, 3]])) == [1, 2, 3]
end

@testset "arithmetic combinations" begin
    x = [1.0, 2.0, 3.0]
    w = [10.0, 20.0, 30.0]
    @test aggr"sum(_ * wt) / sum(wt)".f(x, w) ≈ sum(x .* w) / sum(w)  # weighted mean
    @test aggr"maximum(_) - minimum(_)".f(x) == 2.0                   # range
    @test aggr"count(_ > 100) / length(_)".f([50.0, 150.0]) == 0.5    # fraction above
    @test aggr"sum(abs(_))".f([-1.0, 2.0]) == 3.0                     # L1 mass
    @test aggr"std(_) / mean(_)".f(x) == Statistics.std(x) / 2.0      # coeff. of variation
end

@testset "coalesce" begin
    # replace: elementwise coalesce before reducing (vs skipmissing = drop)
    @test aggr"sum(coalesce(_, 0))".f([1.0, missing, 2.0]) == 3.0
    # scalar broadcast: patch the missing that uniqvalue returns on mixed groups
    @test aggr"coalesce(uniqvalue(_), \"mixed\")".f(["a", "b"]) == "mixed"
    @test aggr"coalesce(uniqvalue(_), \"mixed\")".f(["a", "a"]) == "a"
end

@testset "ismissing" begin
    # flag: missing-count as a measure
    @test aggr"count(ismissing(_))".f([1, missing, missing]) == 2
end

@testset "countuniq" begin
    # verb semantics: count-distinct, uniqvalue's kwargs
    @test countuniq([1, 2, 2, 3]) == 3
    @test countuniq(["a", "b", "a"]) == 2
    @test countuniq([1, missing, 1]) == 1                  # skipna default
    @test countuniq([1, missing, 1]; skipna = false) == 2  # missing counts as a value
    @test countuniq(String[]) == 0
    @test countuniq(["a", "", "b"]; skipempty = true) == 2

    # through the untrusted DSL, bare-name form included
    @test aggr"countuniq(_)".f(["a", "b", "a"]) == 2
    @test aggr"countuniq".f([1, 1, 2]) == 2

    # count distinct districts per county, as a hints spec
    df = DataFrame(County = ["C1", "C1", "C1", "C2"],
                   District = ["d1", "d1", "d2", "d3"])
    out = agg(df, :County; hints = AggrHints(:District => aggr"countuniq"))
    @test out.District == [2, 1]
end

@testset "Boolean measures (&&, ||, where)" begin
    # a Bool-valued measure from compound reductions -- top-level && is legal
    @test aggr"sum(_) > 100 && length(_) > 2".f([50.0, 60.0, 70.0]) == true
    @test aggr"sum(_) > 100 && length(_) > 2".f([200.0]) == false

    # where as a group-level flag measure, label = the condition text
    @test aggr"where(sum(_) > 100)".f([60.0, 70.0]) == "sum(_) > 100"
    @test aggr"where(sum(_) > 100, true_label = \"big\")".f([1.0]) == "Not big"

    # in a grouped aggregation: group sums x=3, y=7
    df = DataFrame(g = ["x", "x", "y"], v = [1.0, 2.0, 7.0])
    out = agg(df, :g; hints = AggrHints(:v => aggr"where(sum(_) > 5)"),
              cols = [:v => aggr"where(sum(_) > 5)" => :big])
    @test out.big == ["Not sum(_) > 5", "sum(_) > 5"]

    # any/all compose directly with where for group flags (the readable
    # alternative to count(cond) > 0 / count(cond) == length(_))
    @test aggr"where(any(_ > 100))".f([60.0, 150.0]) == "any(_ > 100)"
    @test aggr"where(all(_ > 100))".f([60.0, 150.0]) == "Not all(_ > 100)"
end

@testset "composite aggregation (nested groupby)" begin
    # panel: district populations, snapshots over years; yearly sums 30, 30, 30
    pop  = [10.0, 20.0, 5.0, 25.0, 8.0, 22.0]
    year = [2020, 2020, 2021, 2021, 2022, 2022]
    @test aggr"mean(sum(_) |> groupby(year))".f(pop, year) == 30.0
    @test aggr"mean(sum(_) ∘ groupby(year))".f(pop, year) == 30.0  # glyph twin
    @test aggr"length(sum(_) |> groupby(year))".f(pop, year) == 3  # n subgroups

    # subgroups are sorted by key: first/last = earliest/latest year,
    # regardless of row order
    v  = [30.0, 2.0, 1.0]
    yr = [2022, 2020, 2021]
    @test aggr"first(sum(_) |> groupby(year))".f(v, yr) == 2.0     # 2020
    @test aggr"last(sum(_) |> groupby(year))".f(v, yr) == 30.0     # 2022
    @test aggr"maximum(sum(_) |> groupby(year))".f(v, yr) == 30.0

    # the inner spec is a full spec: weighted mean per year, then spread
    w = [1.0, 3.0, 1.0, 1.0, 2.0, 2.0]
    wm(x, ww) = sum(x .* ww) / sum(ww)
    expected = [wm(pop[1:2], w[1:2]), wm(pop[3:4], w[3:4]), wm(pop[5:6], w[5:6])]
    @test aggr"maximum(sum(_ * w) / sum(w) |> groupby(year))".f(pop, w, year) ≈
          maximum(expected)

    # multi-key: state x year, both spellings
    st = ["a", "a", "a", "b", "b", "b"]
    y2 = [2020, 2020, 2021, 2020, 2021, 2021]
    @test aggr"length(sum(_) |> groupby(state, year))".f(pop, st, y2) == 4
    @test aggr"length(sum(_) |> groupby([state, year]))".f(pop, st, y2) == 4

    # computed key: bucket a raw date column by calendar year on the fly
    t = [Date(2020, 1, 1), Date(2020, 6, 1), Date(2021, 3, 1)]
    x = [1.0, 2.0, 4.0]
    @test aggr"mean(sum(_) |> groupby(yyyy(t)))".f(x, t) == (3.0 + 4.0) / 2

    # missing key forms its own subgroup (sorted last)
    ym = [2020, 2020, missing]
    @test aggr"length(sum(_) |> groupby(year))".f(x, ym) == 2
    @test aggr"last(sum(_) |> groupby(year))".f(x, ym) == 4.0      # the missing group

    # stages nest: mean county total per year, then max across years
    cty = ["c1", "c1", "c2", "c1", "c2", "c2"]
    y3  = [2020, 2020, 2020, 2021, 2021, 2021]
    p3  = [1.0, 2.0, 9.0, 4.0, 3.0, 3.0]
    # 2020: county totals 3, 9 -> mean 6;  2021: totals 4, 6 -> mean 5
    @test aggr"maximum(mean(sum(_) |> groupby(county)) |> groupby(year))".f(
        p3, cty, y3) == 6.0

    # end-to-end through agg: average yearly total per county
    df = DataFrame(
        county = ["c1", "c1", "c1", "c2", "c2"],
        year   = [2020, 2020, 2021, 2020, 2021],
        pop    = [10.0, 20.0, 40.0, 5.0, 15.0],
    )
    out = agg(df, :county;
              hints = AggrHints(:pop => aggr"mean(sum(_) |> groupby(year))"),
              cols = [:pop])
    @test out.pop == [35.0, 10.0]   # c1: (30 + 40)/2;  c2: (5 + 15)/2

    # column bookkeeping: nested keys are real column references
    s = aggr"mean(sum(_) |> groupby(year))"
    @test s.cols == [:_, :year]                       # source order
    @test checkcols(s, [:pop, :year]) === s
    @test_throws SpecError checkcols(s, [:pop])  # year missing

    # mixed key types cannot sort: a curated error, not a raw MethodError
    err = try
        aggr"mean(sum(_) |> groupby(k))".f([1.0, 2.0, 3.0], Any[1, "a", 2])
        nothing
    catch e
        e
    end
    @test err isa Exception && occursin("mutually comparable", sprint(showerror, err))
end

@testset "wmeanfallback" begin
    x  = [1.0, 2.0, 3.0]
    z  = [0.0, 0.0, 0.0]      # sums to zero -- unusable
    m  = [10.0, missing, 30.0]  # sum is missing -- unusable, but must not crash
    sz = [10.0, 20.0, 30.0]

    # verb semantics: direct calls
    @test wmeanfallback(x, [sz]) ≈ sum(x .* sz) / sum(sz)
    @test wmeanfallback(x, [z, sz]) ≈ sum(x .* sz) / sum(sz)   # first fails, second wins
    @test wmeanfallback(x, [m, sz]) ≈ sum(x .* sz) / sum(sz)   # missing weight-sum skipped too
    @test wmeanfallback(x, [z, 1]) ≈ sum(x) / length(x)        # literal weight = unweighted mean
    @test ismissing(wmeanfallback(x, [z]))                     # every candidate fails
    @test_throws ErrorException wmeanfallback(x, Float64[])    # no candidates at all

    # through the untrusted DSL, first-encounter arg order: _, z, sz
    @test aggr"wmeanfallback(_, [z, sz])".f(x, z, sz) ≈ sum(x .* sz) / sum(sz)
    @test ismissing(aggr"wmeanfallback(_, [z])".f(x, z))

    # as a grouped hints spec
    df = DataFrame(
        g = ["a", "a", "b", "b"],
        v = [1.0, 2.0, 10.0, 20.0],
        Size = [0.0, 0.0, 1.0, 3.0],
        Suitability = [2.0, 4.0, 5.0, 5.0],
    )
    spec = aggr"wmeanfallback(_, [Size, Suitability, 1])"
    out = agg(df, :g; hints = AggrHints(:v => spec))
    @test out.v[1] ≈ (2 * 1.0 + 4 * 2.0) / (2 + 4)     # group a: Size sums to 0, falls to Suitability
    @test out.v[2] ≈ (1 * 10.0 + 3 * 20.0) / (1 + 3)   # group b: Size usable
end

@testset "strjoinuniq" begin
    # verb semantics: unique, non-missing, stringified, sorted, joined, capped
    @test strjoinuniq(["b", "a", "b", missing]) == "a,b"
    @test strjoinuniq([2, 1, 2]) == "1,2"
    @test strjoinuniq(["b", "a"], "; ") == "a; b"
    @test strjoinuniq(Union{String,Missing}[missing, missing]) == ""
    long = strjoinuniq(["district" * string(i) for i = 1:50], ",", 20)
    @test length(long) == 20 && endswith(long, "…")
    @test strjoinuniq(["abc"], ",", 3) == "abc"          # exactly at the limit

    # through the untrusted DSL, defaults and explicit args
    @test aggr"strjoinuniq(_)".f(["b", "a", "b"]) == "a,b"
    s = parseaggr("strjoinuniq(_, \"; \", 5)")
    @test s.f(["bb", "aa", "cc"]) == "aa; …"

    # as an AggrHints spec in a grouped aggregation
    df = DataFrame(g = ["x", "x", "y"], name = ["b", "a", "c"])
    out = agg(df, :g; hints = AggrHints(:name => aggr"strjoinuniq(_)"))
    @test out.name == ["a,b", "c"]
end

@testset "isuniform" begin
    # STRICT: equal values AND no missing. A row whose unit is *unknown* is a
    # row whose unit is *possibly different*, which is the whole point.
    @test isuniform(["USD", "USD"])
    @test !isuniform(["USD", "EUR"])
    @test !isuniform(["USD", missing])       # the trap the strict reading closes
    @test !isuniform([missing, missing])     # nothing known ⇒ nothing established
    @test !isuniform(String[])               # nothing to agree on
    @test isuniform([1])
    @test isuniform([1.0, 1.0])              # isequal, so any element type
    @test !isuniform([1, 2])

    # the two looser readings stay spellable with existing operators, which is
    # why only the strict one is registered
    u = ["USD", missing]
    @test countuniq(u) == 1                      # lenient: ignores the unknown
    @test countuniq(u; skipna = false) == 2      # ≡ Julia's allequal
    @test allequal(u) == (countuniq(u; skipna = false) == 1)
    @test !isuniform(u)

    @test aggr"isuniform(unit)".f(["USD", "USD"]) === true
    @test aggr"isuniform(unit)".f(["USD", "EUR"]) === false
end

@testset "onlyif" begin
    # x when the condition holds, missing otherwise -- the *inject* member of
    # the missing-value set
    @test onlyif(true, 5) == 5
    @test onlyif(false, 5) === missing
    @test onlyif(missing, 5) === missing          # Kleene, like && / ||
    @test_throws ErrorException onlyif(1, 5)      # non-Boolean, as in `where`

    # elementwise, so it follows its arguments: scalar guards an aggregate,
    # vector guards a column
    guard = aggr"onlyif(countuniq(unit) == 1, sum(_))"
    @test guard.cols == [:unit, :_]        # .f takes columns in first-encounter order
    @test guard.f(["a", "a"], [1, 2]) == 3
    @test guard.f(["a", "b"], [1, 2]) === missing
    @test isequal(dim"onlyif(ok, v)".f([true, false, true], [1, 2, 3]),
                  [1, missing, 3])

    # the motivating case, end to end: a total that must not be reported when
    # the group mixes units. Group X mixes a known unit with an UNKNOWN one --
    # lenient guards let it through, which is why isuniform is strict.
    df = DataFrame(region = ["E", "E", "W", "W", "X", "X"],
                   unit   = ["USD", "USD", "USD", "EUR", "USD", missing],
                   sales  = [10, 20, 30, 40, 50, 60])
    strict = agg(df, :region; cols = [:sales => aggr"onlyif(isuniform(unit), sum(_))"])
    @test isequal(strict.sales, [30, missing, missing])
    lenient = agg(df, :region; cols = [:sales => aggr"onlyif(countuniq(unit) == 1, sum(_))"])
    @test isequal(lenient.sales, [30, missing, 110])   # X slips through
    # the column widens to admit the guarded value rather than coercing it
    @test eltype(strict.sales) == Union{Missing,Int}

    # the arithmetic workarounds this exists to replace are actively wrong:
    # `* (cond)` yields 0, indistinguishable from a real zero total
    @test agg(df, :region; cols = [:sales => aggr"sum(_) * (countuniq(unit) == 1)"]).sales ==
          [30, 0, 110]

    # shape inference catches the confused forms for free
    @test_throws SpecError parseaggr("onlyif(unit, sum(_))")   # condition is a column
    @test_throws SpecError parseaggr("onlyif(isuniform(unit), sales)")

    # foreign spellings redirect, including SQL's inverted NULLIF
    redirect(s, needle) = begin
        e = try (parseaggr(s); nothing) catch e; e end
        e !== nothing && occursin(needle, sprint(showerror, e))
    end
    @test redirect("nullif(a, b)", "onlyif(a != b, a)")
    @test redirect("nullif(a, b)", "nulls when a EQUALS b")
    @test redirect("stopifnull(x, unit)", "onlyif(cond, x)")
    @test redirect("allequal(unit)", "isuniform(x)")
    @test redirect("ifelse(c, x, y)", "onlyif(cond, x)")
end
