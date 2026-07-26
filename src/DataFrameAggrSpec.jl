module DataFrameAggrSpec

# A standalone, UI-free runtime DSL for DataFrame aggregation and dimensioning,
# extracted from TermWin. Everything is compiled at *runtime* (so specs can
# arrive as strings from a GUI, config file, or database — where DataFramesMeta's
# compile-time macros cannot reach).
#
#   * aggregation specs — `liftAggrSpecToFunc(:col, spec)` where `spec` is a
#     Symbol (`:sum`), an Expr (`:( mean(:_, :wcol) )`, with `:_` the on-the-fly
#     target column and `:col` a named column reference), a `df -> ...`
#     lambda, or a String / `SafeAggrSpec` (`aggr"mean(_)"` — the untrusted
#     path, see the trust boundary below). A safe spec may carry a top-level
#     `|> orderby(cols...)`, which sorts the group's rows before the reduction
#     runs — what `first`/`last` need to mean anything. `AggrHints` resolves
#     per-column specs (col > eltype > default).
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
#     (top-N ranking with tie/dense/"Others" handling), `quantiles`, `where`
#     (self-labeling Boolean flag), `lag`/`lead`, the ranking quartet
#     `rank`/`denserank`/`ordinalrank`/`tiedrank` (NOT exported — name
#     collisions; see the export block below), `wmeanfallback`, `hhi`
#     (Herfindahl-Hirschman concentration), and the date-bucket labels
#     `yyyy`/`yyyyq`/`yyq`/`yyyymm`/`yymm`.
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
include("diagnostics.jl") # SpecError: the machine channel beside the message
include("aggrspec.jl")    # aggregation-spec compiler (liftAggrSpecToFunc) + AggrHints
include("verbs.jl")       # discretize / topnames / uniqvalue / unionall / lag / lead / rank
# UNTRUSTED whitelist DSL: aggr"..." / dim"...", split by job. Only the first
# has a hard order requirement (it registers verbs at LOAD time, so it follows
# verbs.jl) and only the last is required before dimension.jl (whose signatures
# mention SafeDimSpec). The middle four are function bodies and consts, ordered
# for reading rather than for the loader -- see the header of safe.jl.
include("registry.jl")    # SafeOps / SafeOpShapes, registerop!, shipped operators
include("rejections.jl")  # the error vocabulary + with_spec_context
include("checks.jl")      # arity / keyword / shape checks, decided at parse time
include("compile.jl")     # the eval-free AST -> closure compiler
include("parse.jl")       # Meta.parse, modifier peeling, where desugaring
include("safe.jl")        # spec types + the public doors (parseaggr / parsedim)
include("dimension.jl")   # WindowDim / PivotDim dimensioning engine
include("chain.jl")       # chains: left-context pivot lists + dimspec
include("pivot.jl")       # hints-driven grouped aggregation
include("templates.jl")   # PROACTIVE suggestion: starter templates + completion
                          # vocabulary (needs SafeOps/SafeModifiers + the spec
                          # structs -- keep after safe.jl)

# Public runtime-spec API
export liftAggrSpecToFunc, defaultAggr
# Untrusted whitelist DSL
export SafeAggrSpec, SafeDimSpec, parseaggr, parsedim, @aggr_str, @dim_str
export registerop!, registerclassifier!, listops, checkcols, opshape, clearcaches!
# Structured diagnostics: the machine channel beside the human message. Every
# rejection of user-supplied spec text is a SpecError carrying a code, the
# offending token and (when one exists) a drop-in fix -- for linters, LSP
# servers and agents repairing their own output. Host-code mistakes (a bad
# `kind`, a malformed AggrHints key, registerop! name rules) stay plain
# ErrorExceptions. See design/user-guidance.md.
export SpecError
# Spec suggestion: proactive (templates / completion vocabulary, templates.jl)
# and the structural rendition of a parsed spec a host echoes back. The
# after-the-fact half (did-you-mean) reaches users through parser errors.
export spec_templates, spec_vocabulary, specsummary, specfields
export spec_columns, spec_coltype
# Aggregation hints + the two chain verbs (dim adds columns, agg reduces)
export AggrHints, resolveaggr, aggrvalue, agg
# Dimensioning -- chains are the only public entry; the window/pivot kinds and
# their types (WindowDim/PivotDim) are internals behind kind inference + dimspec
export dimspec, dim, dim!
# Aggregation / presentation verbs
export uniqvalue, countuniq, unionall, strjoinuniq, discretize, topnames, quantiles, lag, lead, where
export wmeanfallback, hhi
# Guarded values: `onlyif` injects a missing under a condition (the fourth
# missing-value role beside drop/replace/flag), `isuniform` is the strict
# "this column is constant across the group" predicate it is usually given.
export onlyif, isuniform
# The ranking quartet (rank/denserank/ordinalrank/tiedrank) is deliberately NOT
# exported, the one exception to the "every verb is exported" rule: `rank`
# collides with LinearAlgebra.rank (matrix rank) and the other three with their
# StatsBase namesakes, both routinely loaded next to DataFrames. Exporting would
# turn a working bare `denserank(x)` in a host session into an ambiguity
# UndefVarError -- an operator addition must not break a host's existing code.
# Nothing is lost: untrusted string specs read the SafeOps registry, not Main's
# bindings, so dim"rank(x)" works regardless, and trusted Exprs can qualify
# (DataFrameAggrSpec.rank, or StatsBase's own).
# Date-bucketing labels (lexical order = chronological order)
export yyyy, yyyyq, yyq, yyyymm, yymm

end # module
