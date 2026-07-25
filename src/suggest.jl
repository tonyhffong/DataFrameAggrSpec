# "did you mean" support for user-facing errors (ported from DateSeries).
# On a rejection we try to repair the offending token against the known
# vocabulary (operator registry, modifier names, or a frame's column names)
# and append the repaired spelling to the error, so a TUI user typing
# "maen(_)" fails with `did you mean 'mean'?` instead of a bare rejection.
# Matching uses the OSA (restricted Damerau-Levenshtein) distance --
# transpositions like maen/mean are single edits, which plain Levenshtein
# would score 2 and miss under the short-token budget.

function osa_distance(a::AbstractString, b::AbstractString)
    A, B = collect(a), collect(b)
    la, lb = length(A), length(B)
    la == 0 && return lb
    lb == 0 && return la
    d = Matrix{Int}(undef, la + 1, lb + 1)
    d[:, 1] = 0:la
    d[1, :] = 0:lb
    for i in 2:la+1, j in 2:lb+1
        cost = A[i-1] == B[j-1] ? 0 : 1
        d[i, j] = min(d[i-1, j] + 1, d[i, j-1] + 1, d[i-1, j-1] + cost)
        if i > 2 && j > 2 && A[i-1] == B[j-2] && A[i-2] == B[j-1]
            d[i, j] = min(d[i, j], d[i-2, j-2] + 1)  # transposition
        end
    end
    d[la+1, lb+1]
end

# does this token read as a name (column, operator word) rather than punctuation?
isidenttoken(s::AbstractString) =
    !isempty(s) && (isletter(first(s)) || first(s) == '_')

# how many leading characters two tokens share -- the tie-breaker below
function common_prefix(a::AbstractString, b::AbstractString)
    n = 0
    for (x, y) in zip(a, b)
        x == y || break
        n += 1
    end
    n
end

# Nearest candidate within an edit budget scaled to the token length (1 edit
# for short tokens, 2 from 4 chars up); `nothing` when no candidate is close
# enough. Case-insensitive match, canonical spelling returned.
#
# Two guards keep the repair from being noise rather than help, both learned
# from the operator registry (which holds words and punctuation side by side):
#   * tokens under 2 characters get NO repair -- at that length nearly every
#     short candidate is one edit away, so `_` "repairs" to `!`
#   * a candidate must have the same SHAPE as the token -- a word never repairs
#     to a punctuation operator, and vice versa (`n` to `!`)
#
# Equal-distance candidates resolve to the one sharing the LONGER prefix with
# the token, then to the first listed (so pass candidates sorted for
# determinism). Distance alone is not enough: `dsc` is one edit from both `asc`
# and `desc`, and picking alphabetically answers the wrong one -- a user who
# typed the `d` meant `desc`. Typos cluster after the first character, so the
# prefix a user got right is evidence about what they were reaching for.
function nearest(tok::AbstractString, candidates)
    t = lowercase(tok)
    maxd = length(t) >= 4 ? 2 : length(t) >= 2 ? 1 : 0
    maxd == 0 && return nothing
    word = isidenttoken(t)
    best, bestd, bestp = nothing, maxd + 1, -1
    for c in candidates
        isidenttoken(string(c)) == word || continue
        s = lowercase(string(c))
        dist = osa_distance(t, s)
        dist <= maxd || continue
        p = common_prefix(t, s)
        (dist < bestd || (dist == bestd && p > bestp)) &&
            ((best, bestd, bestp) = (c, dist, p))
    end
    best
end

# Hint fragment appended to error messages: "" when nothing is close enough,
# so call sites degrade gracefully to the plain rejection.
function didyoumean(tok, candidates)
    n = nearest(string(tok), candidates)
    n === nothing ? "" : " -- did you mean '" * string(n) * "'?"
end
