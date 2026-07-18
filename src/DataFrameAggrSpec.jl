module DataFrameAggrSpec

# A standalone, UI-free runtime DSL for DataFrame aggregation and dimensioning,
# extracted from TermWin. Everything is compiled at *runtime* (so specs can
# arrive as strings from a GUI, config file, or database — where DataFramesMeta's
# compile-time macros cannot reach).
#
#   * aggregation specs — `liftAggrSpecToFunc(:col, spec)` where `spec` is a
#     Symbol (`:sum`), an Expr (`:( mean(:_, :wcol) )`, with `:_` the on-the-fly
#     target column and `:col` a named column reference), or a `df -> ...`
#     lambda. `AggrHints` resolves per-column specs (col > eltype > default).
#   * dimensioning — NEW columns computed from sibling rows sharing partition
#     keys, declared ONLY in chains: `name => spec` entries partitioned by
#     their left context, options via `dimspec(spec; by, order, kind)`. Two
#     kinds behind kind inference: window (row-level within a partition;
#     supports `order`) and pivot (classify groups by their aggregates) —
#     the types WindowDim/PivotDim are internals.
#   * the two chain verbs — `dim(df, chain)` ADDS the chain's columns (rows
#     preserved); `agg(df, chain)` groups by the chain and reduces to one row
#     per key combination (bare-symbol entries are existing keys, `name => spec`
#     entries are on-the-fly dimensions materialized first). `agg`'s `cols`
#     entries may be `col => spec => outname` (DataFrames-style) to reduce the
#     same column several times under distinct names. Curried
#     `dim(...)`/`agg(...)` return callable transforms composable with `|>`/`∘`.
#   * presentation verbs — `discretize` (labeled/ranked binning), `topnames`
#     (top-N ranking with tie/dense/"Others" handling), `lag`/`lead`.
#
# SECURITY / TRUST BOUNDARY — the rule: Expr/Symbol/Function specs are TRUSTED;
# plain Strings are UNTRUSTED and parsed by the safe whitelist grammar (safe.jl —
# an eval-free, default-deny interpreter over the SafeOps registry) everywhere in
# the API, with no exceptions.
# Trusted Expr specs are compiled with `Core.eval(Main, ...)` so module-qualified
# names (e.g. `StatsBase.mean`) resolve against the *user's* loaded packages; the
# guards (must be a `:call`, no curly, simple/dotted name, reject any `!`) keep
# trusted-author specs honest but are NOT a sandbox — the String path is.

using DataFrames
using CategoricalArrays
using Statistics
using Dates
using Format
using Base.Meta

include("exprsubst.jl")   # spec-expression substitution machinery + guards
include("suggest.jl")     # OSA "did you mean" helpers for user-facing errors
include("aggrspec.jl")    # aggregation-spec compiler (liftAggrSpecToFunc) + AggrHints
include("verbs.jl")       # discretize / topnames / uniqvalue / unionall / lag / lead
include("safe.jl")        # UNTRUSTED whitelist DSL: aggr"..." / dim"..." (needs verbs;
                          # dimension.jl signatures need SafeDimSpec -- keep this order)
include("dimension.jl")   # WindowDim / PivotDim dimensioning engine
include("chain.jl")       # chains: left-context pivot lists + dimspec
include("pivot.jl")       # hints-driven grouped aggregation

# Public runtime-spec API
export liftAggrSpecToFunc, defaultAggr
# Untrusted whitelist DSL
export SafeAggrSpec, SafeDimSpec, parseaggr, parsedim, @aggr_str, @dim_str
export registerop!, registerclassifier!, listops, checkcols
# Aggregation hints + the two chain verbs (dim adds columns, agg reduces)
export AggrHints, resolveaggr, aggrvalue, agg
# Dimensioning -- chains are the only public entry; the window/pivot kinds and
# their types (WindowDim/PivotDim) are internals behind kind inference + dimspec
export dimspec, dim, dim!
# Aggregation / presentation verbs
export uniqvalue, countuniq, unionall, strjoinuniq, discretize, topnames, quantiles, lag, lead, where
export wmeanfallback
# Date-bucketing labels (lexical order = chronological order)
export yyyy, yyyyq, yyq, yyyymm, yymm

end # module
