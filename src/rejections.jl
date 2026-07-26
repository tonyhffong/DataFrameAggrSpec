# The REJECTION vocabulary: the fixed tables a rejection draws on, and the
# helpers that turn an offending token into a message worth reading.
#
# Nothing here decides WHETHER a spec is wrong -- checks.jl and compile.jl do
# that. This file decides what the user is told once it is, which is a
# separate job with its own standard (G1: the message says what to type
# instead) and its own failure mode (a technically-true message that leaves
# the user with nowhere to go). See design/user-guidance.md.

# ---- AST -> closure compiler ------------------------------------------------

# tailored rejection messages for syntax an end user (or attacker) will hit
const SafeRejections = Dict{Symbol,String}(
    Symbol(".") => "qualified names (A.B) and broadcast calls (f.(x)) are not allowed; hosts can register functions under a plain name with registerop!",
    :curly => "type parameters are not allowed",
    :macrocall => "macros (and command literals) are not allowed",
    :$ => "interpolation is not allowed",
    :string => "string interpolation is not allowed",
    Symbol("->") => "anonymous functions are not allowed",
    :do => "do-blocks are not allowed",
    :block => "blocks are not allowed",
    Symbol("=") => "assignment is not allowed",
    :ref => "indexing is not allowed",
    :comparison => "chained comparisons are not allowed -- combine single " *
                    "comparisons with && (10 < x < 20 becomes x > 10 && x < 20)",
    Symbol("...") => "splatting is not allowed",
    :tuple => "tuples are not allowed",
    :generator => "comprehensions are not allowed",
    :comprehension => "comprehensions are not allowed",
    :flatten => "comprehensions are not allowed",
    :quote => "nested quoting is not allowed",
    :if => "conditionals are not allowed",
)


# reminder shown when a modifier name is used (or repaired to) in call position
modifier_reminder(m::Symbol) =
    m == :orderby ?
    "'orderby' is a postfix modifier, not a function -- write the spec " *
    "first: \"cumsum(sales) |> orderby(date)\" (dim specs only)" :
    "'groupby' is a postfix modifier, not a function -- write the spec " *
    "first: \"mean(x) |> groupby(key)\" aggregates the measure per key " *
    "before the verb classifies (dim specs only)"

# Spellings a user arrives with from SQL, dplyr, pandas or Excel, mapped to what
# this grammar calls the same thing. These are NOT aliases -- the registry keeps
# exactly one spelling per concept (design/expressiveness.md) and the spec still
# FAILS. They exist because the OSA repair below can only rescue a misspelling
# of a whitelisted word: `avg` is four edits from `mean`, so a user typing it
# has no way to guess the local name from the rejection alone. Keyed by the
# UNDERSCORE-STRIPPED, lowercased name, so `row_number`/`ROW_NUMBER` land here
# too. Values complete the sentence "Use ___ instead."
const ForeignSpellings = Dict{Symbol,String}(
    :avg            => "mean(x)",
    :average        => "mean(x)",
    :stddev         => "std(x)",
    :stdev          => "std(x)",
    :sd             => "std(x)",
    :variance       => "var(x)",
    :n              => "nrow (the group's row count -- aggr\"nrow\")",
    :rowcount       => "nrow",
    :size           => "nrow for the group's row count, or length(x)",
    :len            => "length(x)",
    :nunique        => "countuniq(x)",
    :ndistinct      => "countuniq(x)",
    :countdistinct  => "countuniq(x)",
    :distinct       => "countuniq(x) to count them, uniqvalue(x) for the one " *
                       "distinct value, or strjoinuniq(x) to list them",
    :unique         => "countuniq(x) to count them, uniqvalue(x) for the one " *
                       "distinct value, or strjoinuniq(x) to list them",
    :groupconcat    => "strjoinuniq(x)",
    :stringagg      => "strjoinuniq(x)",
    :listagg        => "strjoinuniq(x)",
    :concat         => "strjoinuniq(x)",
    :strjoin        => "strjoinuniq(x)",
    :ifelse         => "where(cond), which labels both sides -- or " *
                       "onlyif(cond, x) when the other branch is missing, or " *
                       "plain arithmetic, e.g. x * (x > 0)",
    # SQL's NULLIF(a, b) is null WHEN a = b -- the opposite reading of the
    # name, so this redirect has to invert the condition rather than just
    # rename the verb.
    :nullif         => "onlyif(a != b, a) -- note SQL's NULLIF(a, b) nulls " *
                       "when a EQUALS b, so the condition inverts",
    :stopifnull     => "onlyif(cond, x), e.g. " *
                       "onlyif(isuniform(unit), sum(_))",
    :allequal       => "isuniform(x) for the strict reading (a missing makes " *
                       "it false), or countuniq(x, skipna = false) == 1 for " *
                       "Julia's allequal semantics exactly",
    :ifthen         => "where(cond)",
    :iif            => "where(cond)",
    :casewhen       => "where(cond) for a two-way split, or " *
                       "discretize(x, breaks) for numeric bands",
    :switch         => "where(cond), or discretize(x, breaks) for numeric bands",
    :filter         => "where(cond) as a chain key, then reduce",
    :subset         => "where(cond) as a chain key, then reduce",
    :rownumber      => "ordinalrank(x)",
    :rowid          => "ordinalrank(x)",
    :ntile          => "quantiles(x, ngroups = 4)",
    :percentile     => "quantile(x, 0.9)",
    :percentilecont => "quantile(x, 0.9)",
    :top            => "topnames(labels, values, n)",
    :topn           => "topnames(labels, values, n)",
    :cut            => "discretize(x, breaks)",
    :bin            => "discretize(x, breaks)",
    :ifnull         => "coalesce(x, 0)",
    :nvl            => "coalesce(x, 0)",
    :isnull         => "ismissing(x) to flag it, coalesce(x, 0) to replace it",
    :isna           => "ismissing(x) to flag it, coalesce(x, 0) to replace it",
    :fillna         => "coalesce(x, 0)",
    :fillmissing    => "coalesce(x, 0)",
    :dropna         => "skipmissing(x)",
    :dropmissing    => "skipmissing(x)",
    :naomit         => "skipmissing(x)",
    :argmax         => "last(_) |> orderby(col) -- the value at col's maximum",
    :argmin         => "first(_) |> orderby(col) -- the value at col's minimum",
    :maxby          => "last(_) |> orderby(col)",
    :minby          => "first(_) |> orderby(col)",
    :shift          => "lag(x) or lead(x)",
    :runningtotal   => "cumsum(x)",
    :sumif          => "sum(x * (cond)) -- the condition is just a column " *
                       "expression",
    :countif        => "count(cond)",
)

# lookup key for ForeignSpellings and the no-underscores redirect
squash(name) = Symbol(replace(lowercase(string(name)), "_" => ""))

# the whitelist as a user should read it. The symbolic entries (dotted aliases,
# unicode twins) are two thirds of listops() and teach nothing when spelled out
# one by one, so they are summarized instead.
function registry_summary()
    named = [s for s in string.(listops()) if isidenttoken(s)]
    "Named operations: " * join(named, ", ") *
    ". Operators: + - * / ^ == != < <= > >= (plus their dotted and unicode " *
    "spellings) and && / || for conditions. " *
    "(listops() shows the live registry; hosts extend it with registerop!.)"
end

# unknown function in call position. Ordered most-specific first: a structural
# redirect, a modifier misuse, the foreign-spelling table, an OSA repair, and
# only then the registry dump -- which is the discovery mechanism of last
# resort, when the package has nothing better to offer than the vocabulary.
function unknown_op_error(fname::Symbol)
    # DataFrames muscle memory: .& / .| are spelled && / || in this grammar
    if in(fname, (Symbol("&"), Symbol("|"), Symbol(".&"), Symbol(".|")))
        c = in(fname, (Symbol("&"), Symbol(".&"))) ? "&&" : "||"
        specerror("'" * string(fname) * "' is not an operator here -- " *
                  "combine conditions with '" * c * "' (pure elementwise over " *
                  "columns; binds looser than comparisons, so no parentheses " *
                  "needed: a > 1 " * c * " b < 2)";
                  code = :boolean_operator, token = fname, fix = Symbol(c))
    end
    in(fname, SafeModifiers) && specerror("" * modifier_reminder(fname);
                                          code = :modifier_misuse, token = fname)
    sq = squash(fname)
    # `dense_rank`, `ROW_NUMBER`: the concept exists, the spelling does not
    # (operator names carry no underscores -- design/expressiveness.md)
    if sq !== fname && haskey(SafeOps, sq)
        specerror("'" * string(fname) * "' is not registered -- write it " *
                  "as '" * string(sq) * "' (operator names are lowercase and carry " *
                  "no underscores).";
                  code = :spelling_convention, token = fname, fix = sq)
    end
    if haskey(ForeignSpellings, sq)
        # no `fix`: the table's values complete "Use ___ instead" in prose
        # ("nrow (the group's row count -- ...)"), so they are advice rather
        # than a substitution. Deriving a token from prose is the kind of
        # guessing G3 forbids.
        specerror("'" * string(fname) * "' is not registered here -- use " *
                  ForeignSpellings[sq] * ". (listops() shows the whitelist; " *
                  "hosts can extend it with registerop!.)";
                  code = :foreign_spelling, token = fname)
    end
    n = nearest(string(fname), vcat(listops(), collect(SafeModifiers)))
    if n isa Symbol && in(n, SafeModifiers)
        specerror("unknown function '" * string(fname) * "'. " *
                  modifier_reminder(n);
                  code = :modifier_misuse, token = fname)
    elseif n !== nothing
        specerror("unknown function '" * string(fname) *
                  "' -- did you mean '" * string(n) * "'? (listops() shows the " *
                  "whitelist; hosts can extend it with registerop!.)";
                  code = :unknown_op, token = fname, fix = n)
    end
    specerror("unknown function '" * string(fname) * "'. " *
              registry_summary(); code = :unknown_op, token = fname)
end

# a literal where a grouping key belongs. Both `groupby` paths (the nested
# composite reduction and the top-level modifier) funnel here so the colon and
# quote habits -- by far the commonest way to write this wrong, since every
# other DataFrames API wants `:col` or `"col"` -- get named as such instead of
# being reported as "a literal".
function groupby_literal_error(a)
    # both quoting habits have a genuine drop-in fix: strip the colon/quotes
    if isa(a, QuoteNode) && isa(a.value, Symbol)
        specerror("':" * string(a.value) * "' is a Symbol literal -- a " *
                  "grouping key is a bare column name, written without the colon: " *
                  "groupby(" * string(a.value) * ")";
                  code = :groupby_literal, token = a.value, fix = a.value)
    end
    isa(a, AbstractString) && Base.isidentifier(a) && specerror(
        "" * repr(a) * " is a string literal -- a grouping key is a " *
        "bare column name, written without the quotes: groupby(" * a * ")";
        code = :groupby_literal, token = Symbol(a), fix = Symbol(a))
    specerror("groupby keys must be columns (or elementwise transforms " *
              "of columns, e.g. yyyy(t)), got the literal " * repr(a);
              code = :groupby_literal)
end

# would unknown_op_error have something concrete to say about this name, or
# would it fall through to the registry dump? Call sites that have a BETTER
# story for an unrepairable name (a bare identifier is far likelier to be a
# column than a mistyped verb) use this to choose which error to raise.
op_is_repairable(fname::Symbol) =
    in(fname, SafeModifiers) ||
    haskey(SafeOps, squash(fname)) ||
    haskey(ForeignSpellings, squash(fname)) ||
    nearest(string(fname), vcat(listops(), collect(SafeModifiers))) !== nothing


# a spec whose TOP level is not a call. The shape gate runs before the
# compiler, so without this the tailored SafeRejections wording ("assignment
# is not allowed", "do-blocks are not allowed") would only ever be reached
# from a nested position -- `x = 1` at the top level got the generic
# "must be a function call", which does not name what is wrong.
function shape_error(ex, src::String, generic::String)
    if isa(ex, Expr) && haskey(SafeRejections, ex.head)
        specerror("" * SafeRejections[ex.head] * " (in \"" * src * "\")";
                  code = :unsupported_syntax, token = ex.head)
    end
    specerror("" * generic * ", got \"" * src * "\"";
              code = :unsupported_syntax)
end


# Every rejection ends by quoting the spec it came from. A host parses many
# specs per frame (an AggrHints table, the entries of a chain), and "unknown
# function 'foo'" on its own does not say WHICH one to fix. Applied once at
# the entry point rather than at the ~40 individual error sites, so it also
# tags errors raised by shared helpers further down (order entries, verbs).
const SPEC_CONTEXT_MARK = " [in "

# This is also the choke point that makes the diagnostic TYPE uniform: whatever
# a helper deeper down threw -- a classified SpecError from safe.jl, or a plain
# ErrorException from a verb or an order-entry helper that has not been
# classified -- comes out of parseaggr/parsedim as a SpecError carrying the
# spec source. An unclassified site therefore still yields a usable diagnostic
# (`code = :invalid_spec`), so classifying a site is always additive and never
# a prerequisite. The message is rebuilt exactly as before.
function with_spec_context(f, what::String, src::String)
    try
        f()
    catch e
        isa(e, Union{ErrorException,SpecError}) || rethrow()
        isa(e, SpecError) && e.spec !== nothing && rethrow()   # already tagged
        occursin(SPEC_CONTEXT_MARK, e.msg) && rethrow()        # ...ditto, untyped
        msg = startswith(e.msg, what * ":") ? e.msg : what * ": " * e.msg
        code  = isa(e, SpecError) ? e.code : :invalid_spec
        token = isa(e, SpecError) ? e.token : nothing
        # locate the offending text here too -- a site that set `token` gets a
        # highlight without ever having to know a byte offset
        span  = isa(e, SpecError) && e.span !== nothing ? e.span :
                token_span(src, token, code)
        throw(SpecError(msg * SPEC_CONTEXT_MARK *
                        (what == "parseaggr" ? "aggr\"" : "dim\"") * src * "\"]";
                        code = code, token = token,
                        fix  = isa(e, SpecError) ? e.fix : nothing,
                        span = span, spec = src))
    end
end
