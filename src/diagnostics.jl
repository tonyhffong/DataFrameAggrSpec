# Structured diagnostics for the guidance surface (design/user-guidance.md,
# "the machine-facing direction").
#
# Every rejection in this package was written as prose for a person typing into
# a one-line field, and the prose is the contract -- rule G1 ("the message says
# what to type instead") is not negotiable. But a linter, an LSP server or an
# agent repairing its own output needs the same information as DATA: which
# category of mistake, which token, and what to put there instead. Before this
# type existed the only channel was the message string, so the reference host
# ended up regexing our English (TermWin's `_strip_spec_prefix`) and the repair
# `nearest` had already computed was formatted into a sentence and discarded.
#
# `SpecError` adds the machine channel WITHOUT touching the human one:
# `showerror` prints `msg` verbatim, so every message is byte-identical to what
# it was as an `ErrorException`. Adding a `code` at a new site is additive; the
# default (`:invalid_spec`) is always correct if unhelpful, so no site is
# obliged to classify itself before someone needs it to.
#
# SCOPE -- what raises this rather than a plain `error`: a diagnostic about
# USER-SUPPLIED spec text or the column/order references in it (the whole
# safe.jl parse path, `checkcols`, order entries, column-existence checks in
# `dim`/`agg`). Developer-facing API misuse -- a bad `kind` argument, an
# `AggrHints` key that is not a Symbol or Type, `registerop!` name rules, a
# verb's own argument validation -- stays an ordinary `ErrorException`: it is a
# bug in host code, not something a linter reports against a user's spec.

"""
    SpecError <: Exception

A rejection of user-supplied spec text, carrying both the human message and a
machine-readable classification.

Thrown by the untrusted grammar (`parseaggr`/`parsedim`, [`checkcols`](@ref))
and by the column/order checks `dim`/`agg` make at apply time. Programmer
errors — a bad `kind` argument, a malformed `AggrHints` key, a `registerop!`
name that breaks the naming rules — remain plain `ErrorException`s, because
they are host bugs rather than something to report against a user's spec.

# Fields

* `msg::String` — the full human-facing message, exactly as printed. This is
  what `showerror` emits, so a consumer that only wants text can keep using
  `sprint(showerror, e)` and ignore everything else.
* `code::Symbol` — the category (see below). `:invalid_spec` is the catch-all
  for sites that have not been classified.
* `token::Union{Nothing,Symbol}` — the offending identifier, when the mistake
  is about one (`:maen`, a missing column, an unknown keyword).
* `fix::Union{Nothing,Symbol}` — a **drop-in replacement** for the text at
  `span`, when one is known. Deliberately set only when substituting it would
  produce a valid spec, so a consumer may apply it without re-checking: this is
  the quick-fix channel, and a wrong fix is worse than none (rule G3).
  Redirects whose answer is a restructure rather than a substitution (the
  foreign-spelling table, the modifier reminders) leave it `nothing` and put the
  advice in `msg`.
* `span::Union{Nothing,UnitRange{Int}}` — **byte** range of the offending text
  within `spec`, for an underline or a squiggle; `nothing` when it cannot be
  located. Indexes `spec` (the *stripped* source), so `e.spec[e.span]` is the
  offending text and `replace` at `span` with `fix` is the quick edit. Byte
  ranges are what Julia string indexing wants; an LSP host converts to UTF-16
  offsets itself. Located lexically and best-effort: a repeated token resolves
  to its first occurrence, and a span is never guessed into existence.
* `spec::Union{Nothing,String}` — the spec source the diagnostic came from,
  filled in by `with_spec_context`. The same information the message carries as
  a `[in aggr"…"]` suffix, without the regex.

`span` and `fix` are the pair a quick-fix provider needs:

```julia
e = try parseaggr("sum(qtty)"; columns = [:qty]) catch e; e end
e.spec[e.span]                                  # "qtty"
e.spec[1:first(e.span)-1] * string(e.fix) *
    e.spec[last(e.span)+1:end]                  # "sum(qty)"
```

# Codes

| Code | Meaning |
|---|---|
| `:parse` | not parseable Julia (also `:empty_spec` for the empty string) |
| `:unsupported_syntax` | parses, but the shape is outside the grammar (assignment, indexing, a lambda) |
| `:unknown_op` | a call to something not in the registry |
| `:foreign_spelling` | a known SQL/dplyr/pandas/Excel name, redirected to the local one |
| `:spelling_convention` | right concept, wrong casing/underscores (`dense_rank`) |
| `:boolean_operator` | `&`/`\\|` where the grammar wants `&&`/`\\|\\|` |
| `:modifier_misuse` | `orderby`/`groupby` in the wrong position or on the wrong kind |
| `:arity` | wrong number of positional arguments |
| `:unknown_kwarg` | an option name the function does not accept |
| `:symbol_literal` | the colon flip — `:col` where a bare word belongs |
| `:groupby_literal` | a literal where a grouping key belongs |
| `:groupby_key` | a nested `\\|> groupby` key that is not a usable column — the only code raised at APPLY time, so it carries no `spec` |
| `:order_entry` | a malformed `orderby` entry, including a bare `:asc`/`:desc` |
| `:unknown_column` | a column reference not present in the frame |
| `:bare_name` | a lone identifier used where a call is required |
| `:target_placeholder` | `_` used outside an aggregation target position |
| `:invalid_spec` | unclassified |

```julia
try
    parseaggr("maen(_)")
catch e
    e.code   # :unknown_op
    e.token  # :maen
    e.fix    # :mean   -- safe to substitute
end
```

See `design/user-guidance.md` for how this fits the wider guidance system.
"""
struct SpecError <: Exception
    msg::String
    code::Symbol
    token::Union{Nothing,Symbol}
    fix::Union{Nothing,Symbol}
    span::Union{Nothing,UnitRange{Int}}
    spec::Union{Nothing,String}
end

_diagsym(x) = x === nothing ? nothing : Symbol(x)

SpecError(msg::AbstractString; code::Symbol = :invalid_spec, token = nothing,
          fix = nothing, span = nothing, spec = nothing) =
    SpecError(String(msg), code, _diagsym(token), _diagsym(fix), span,
              spec === nothing ? nothing : String(spec))

# ---- locating the offending text --------------------------------------------
# `span` is derived at the entry point from `token`, not threaded through the
# ~40 error sites: the same choke-point trick `spec` uses, so a site that sets
# `token` gets highlighting for free and no site had to learn about byte
# offsets.
#
# The scan below is a small hand-rolled lexer rather than a call into
# `Base.JuliaSyntax`. That is deliberate: JuliaSyntax is an INTERNAL API here
# (its `Token` accessors have already shifted between releases), while the
# consequence of this scanner disagreeing with Julia's real lexer on some edge
# case is only a wrong or missing highlight -- the parse itself is still
# `Meta.parse`. Advisory precision buys stability; do not "fix" this to reach
# into Base.
#
# Multiple occurrences resolve to the FIRST. A one-line spec that names the
# same token twice is rare, and the first is where the reader looks.

_isidstart(c::AbstractChar) = isletter(c) || c == '_'
# `!` continues an identifier (push!) but not when it opens `!=`
_isidcont(c::AbstractChar) = isletter(c) || isdigit(c) || c == '_'
_isopchar(c::AbstractChar) =
    c in ('+', '-', '*', '/', '^', '<', '>', '=', '!', '&', '|', '.', '~', '%',
          '≠', '≤', '≥', '∈', '∉', '∘')

# (range, kind, text, idrange): `range` is the whole token (`:qty`, `"qty"`),
# `idrange` just its name part (`qty`). Which one a diagnostic wants depends on
# whether its `fix` replaces the quoting -- see SPAN_QUOTED_CODES.
const ScanTok = NamedTuple{(:range, :kind, :text, :idrange),
                           Tuple{UnitRange{Int},Symbol,String,UnitRange{Int}}}

function scan_tokens(src::AbstractString)
    out = ScanTok[]
    n = ncodeunits(src)
    i = firstindex(src)
    while i <= n
        c = src[i]
        if c == '"'                                   # string literal
            j = nextind(src, i)
            cstart = j
            closed = 0
            while j <= n
                if src[j] == '\\'
                    j = nextind(src, j)
                    j > n && break
                elseif src[j] == '"'
                    closed = j
                    break
                end
                j = nextind(src, j)
            end
            stop = closed == 0 ? n : closed
            cend = closed == 0 ? n : prevind(src, closed)
            push!(out, (range = i:stop, kind = :string,
                        text = cstart <= cend ? String(src[cstart:cend]) : "",
                        idrange = cstart <= cend ? (cstart:cend) : (i:stop)))
            i = nextind(src, stop)
        elseif c == ':' && (k = nextind(src, i)) <= n && _isidstart(src[k]) &&
               !(i > firstindex(src) && src[prevind(src, i)] == ':')
            j = k                                     # quoted symbol :name
            while (m = nextind(src, j)) <= n && _isidcont(src[m])
                j = m
            end
            push!(out, (range = i:j, kind = :quotesym,
                        text = String(src[k:j]), idrange = k:j))
            i = nextind(src, j)
        elseif _isidstart(c)                          # identifier
            j = i
            while (m = nextind(src, j)) <= n && _isidcont(src[m])
                j = m
            end
            m = nextind(src, j)                       # trailing ! (push!), not !=
            if m <= n && src[m] == '!' &&
               !((p = nextind(src, m)) <= n && src[p] == '=')
                j = m
            end
            push!(out, (range = i:j, kind = :ident,
                        text = String(src[i:j]), idrange = i:j))
            i = nextind(src, j)
        elseif _isopchar(c)                           # operator run (&, .|, |>)
            j = i
            while (m = nextind(src, j)) <= n && _isopchar(src[m])
                j = m
            end
            push!(out, (range = i:j, kind = :other,
                        text = String(src[i:j]), idrange = i:j))
            i = nextind(src, j)
        else
            i = nextind(src, i)
        end
    end
    out
end

# Codes whose `fix` replaces the QUOTING as well as the name, so the span has
# to cover it: substituting `qty` for `qty` in `cumsum(:qty)` fixes nothing --
# the colon is the mistake, so the span must be `:qty`.
const SPAN_QUOTED_CODES = (:symbol_literal, :groupby_literal)

"""
    token_span(src, token, code) -> Union{Nothing,UnitRange{Int}}

Byte range of `token` within `src`, or `nothing` when it cannot be located.
Never throws — a missing span degrades to no highlight.
"""
function token_span(src::AbstractString, token, code::Symbol = :invalid_spec)
    token === nothing && return nothing
    t = string(token)
    isempty(t) && return nothing
    toks = try
        scan_tokens(src)
    catch
        return nothing
    end
    if code in SPAN_QUOTED_CODES
        for tk in toks
            (tk.kind === :quotesym || tk.kind === :string) && tk.text == t &&
                return tk.range
        end
    end
    for tk in toks
        tk.text == t && return tk.idrange
    end
    nothing
end

# the message IS the human contract -- print it and nothing else, so switching a
# site from `error` to `specerror` is invisible to anyone reading the output
Base.showerror(io::IO, e::SpecError) = print(io, e.msg)

# `error`'s counterpart for the guidance surface. Same argument shape (a
# message), plus the machine channel.
specerror(msg::AbstractString; kwargs...) = throw(SpecError(msg; kwargs...))
