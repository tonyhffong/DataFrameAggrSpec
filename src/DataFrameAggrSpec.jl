module DataFrameAggrSpec

# A standalone, UI-free runtime DSL for DataFrame aggregation and dimensioning,
# extracted from TermWin. Everything is compiled at *runtime* (so specs can
# arrive as strings from a GUI, config file, or database — where DataFramesMeta's
# compile-time macros cannot reach).
#
#   * aggregation specs — `liftAggrSpecToFunc(:col, spec)` where `spec` is a
#     Symbol (`:sum`), an Expr (`:( mean(:_, :wcol) )`, with `:_` the on-the-fly
#     target column and `:col` a named column reference), or a `df -> ...`
#     lambda. `AggrHints` resolves per-column specs (col > eltype > default);
#     `aggregate(df, keys; hints)` is the grouped reduction.
#   * dimensioning — NEW columns computed from sibling rows sharing partition
#     keys: `WindowDim` (row-level within a partition; supports `order`) and
#     `PivotDim` (classify groups by their aggregates), applied via `dim`/`dim!`.
#   * chains — pivot lists declaring dimensions inline, partitioned by their
#     left context (chain.jl); `pivottable(df, chain; hints)` = dims + groupby +
#     aggregate in one call. Curried `dim(...)`/`pivottable(...)` return
#     callable transforms composable with `|>` and `∘`.
#   * presentation verbs — `discretize` (labeled/ranked binning), `topnames`
#     (top-N ranking with tie/dense/"Others" handling), `lag`/`lead`.
#   * legacy (deprecated, TermWin transition) — `CalcPivot` +
#     `liftCalcPivotToFunc`, shimmed over the dimension engine.
#
# SECURITY / TRUST BOUNDARY — the rule: Expr/Symbol/Function specs are TRUSTED;
# plain Strings are UNTRUSTED and parsed by the safe whitelist grammar (safe.jl —
# an eval-free, default-deny interpreter over the SafeOps registry) everywhere in
# the API. Sole exception: the frozen legacy `CalcPivot(::String)` constructor.
# Trusted Expr specs are compiled with `Core.eval(Main, ...)` so module-qualified
# names (e.g. `StatsBase.mean`) resolve against the *user's* loaded packages; the
# guards (must be a `:call`, no curly, simple/dotted name, reject any `!`) keep
# trusted-author specs honest but are NOT a sandbox — the String path is.

using DataFrames
using CategoricalArrays
using Statistics
using Format
using Base.Meta

include("exprsubst.jl")   # spec-expression substitution machinery + guards
include("aggrspec.jl")    # aggregation-spec compiler (liftAggrSpecToFunc) + AggrHints
include("verbs.jl")       # discretize / topnames / uniqvalue / unionall / lag / lead
include("safe.jl")        # UNTRUSTED whitelist DSL: aggr"..." / dim"..." (needs verbs;
                          # dimension.jl signatures need SafeDimSpec -- keep this order)
include("deprecated.jl")  # legacy CalcPivot / liftCalcPivotToFunc
include("dimension.jl")   # WindowDim / PivotDim dimensioning engine
include("chain.jl")       # chains: left-context pivot lists + dimspec
include("pivot.jl")       # hints-driven grouped aggregation

# Public runtime-spec API
export liftAggrSpecToFunc, liftCalcPivotToFunc, defaultAggr
export CalcPivot
# Untrusted whitelist DSL
export SafeAggrSpec, SafeDimSpec, parseaggr, parsedim, @aggr_str, @dim_str
export registerop!, registerclassifier!, listops
# Aggregation hints + grouped aggregation
export AggrHints, resolveaggr, aggrvalue, aggregate, pivottable
# Dimensioning
export WindowDim, PivotDim, Dimension, dimspec, dependencies, dim, dim!
# Aggregation / presentation verbs
export uniqvalue, unionall, strjoinuniq, discretize, topnames, quantiles, lag, lead

end # module
