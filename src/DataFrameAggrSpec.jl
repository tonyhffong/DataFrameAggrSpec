module DataFrameAggrSpec

# A standalone, UI-free runtime DataFrame-aggregation DSL, extracted from TermWin.
#
# Two spec languages, both compiled at *runtime* (so specs can arrive as strings
# from a GUI, config file, or database — where DataFramesMeta's compile-time macros
# cannot reach):
#
#   * aggregation specs      — `liftAggrSpecToFunc(:col, spec)` where `spec` is a
#                              Symbol (`:sum`), an Expr (`:( mean(:_, :wcol) )`, with
#                              `:_` the on-the-fly target column and `:col` a named
#                              column reference), or a `df -> ...` lambda.
#   * CalcPivot derived cols — `CalcPivot(spec, by)` + `liftCalcPivotToFunc`, a nested
#                              split-apply-combine producing a computed pivot column.
#
# plus the presentation verbs `discretize` (labeled/ranked binning) and `topnames`
# (top-N ranking with tie/dense/"Others" handling).
#
# SECURITY / TRUST BOUNDARY: general aggregation-spec expressions are compiled with
# `Core.eval(Main, ...)` so that module-qualified names in a spec (e.g.
# `StatsBase.mean`) resolve against the *user's* loaded packages. The guards in
# `liftAggrSpecToFunc` (must be a `:call`, no curly, simple/dotted name, reject any
# `!`) make this safe for *trusted-author* specs (config you control) — they are NOT
# a sandbox. Do not feed untrusted input to these functions. A restricted evaluator
# is a possible future addition.

using DataFrames
using CategoricalArrays
using Statistics
using Format
using Base.Meta

include("dfutils.jl")

# Public runtime-spec API
export liftAggrSpecToFunc, liftCalcPivotToFunc, defaultAggr
export CalcPivot
# Aggregation / presentation verbs
export uniqvalue, unionall, discretize, topnames

end # module
