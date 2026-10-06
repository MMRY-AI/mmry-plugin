# foundation-cut.awk - where the Foundation set is cut into parts, for a set that is not plain
# ASCII (#31411 QA round 2, R1 and TC3). userpromptsubmit-foundation.sh cuts a plain ASCII set
# itself, with the same rules; tests/handlers/foundation-parts.bats checks the two agree.
#
# Input:  the set on stdin, sent as a here-string, so it ends with one newline that is not part of
#         the set. Run with LC_ALL=C, so every string operation here works in bytes.
# Output: the byte length of each part, one per line, in order. At most max + 1 lines: one more
#         than fits means the set goes by reference, and the rest of it needs no cutting.
# -v cap  UTF-16 units allowed in one part (Claude Code counts characters as JavaScript does)
# -v max  parts allowed
#
# POSIX awk only, so BSD awk on a Mac and gawk on Windows and Linux read it the same way. Bytes are
# classified through lookup tables built with sprintf, never through byte ranges in a bracket.

function window(pos,    b, u, c, w, n) {
    # The most bytes from pos holding at most cap UTF-16 units of whole characters: one unit per
    # character, two for a character outside the Basic Multilingual Plane, none for a continuation
    # byte. A byte-by-byte walk with a lookup: measured on 28,500 bytes of Japanese, 18 ms, where
    # counting the same bytes with gsub over a 64-byte class took 850 ms. It stops on a character's
    # first byte, so a part never ends inside a character.
    n = N - pos + 1; u = 0; b = 0
    while (b < n) {
        c = substr(S, pos + b, 1)
        w = (c in ISCONT) ? 0 : ((c in ISASTRAL) ? 2 : 1)
        if (w > 0 && u + w > cap) break
        u += w; b++
    }
    return b
}

function after_last(w, re,    t) {
    # Bytes of w that follow the last match of re, or -1 when re does not occur. Callers check with
    # index() first: a search that fails costs about 50 ms on a part of Japanese text, one that
    # never runs costs nothing.
    t = w
    if (!sub(re, "", t)) return -1
    return length(t)
}

function has_blank(w) { return index(w, " ") || index(w, "\t") }
function has_stop(w) {
    return index(w, ". ") || index(w, "! ") || index(w, "? ") || index(w, ".\t") || index(w, "!\t") || index(w, "?\t")
}

function cut(mode,    pos, n_out, wb, w, half, a, best, c) {
    n_out = 0; pos = 1
    while (pos <= N && n_out <= max) {
        wb = window(pos)
        if (pos + wb > N) { P[++n_out] = N - pos + 1; break }
        w = substr(S, pos, wb); best = wb
        if (mode == "fill" || mode == "pack") {
            # fill (#31411 QA round 3, TC3): the latest line end or sentence end in the part's last
            # 400 bytes. pack, and fill when there is none: a blank within the last 256 bytes. The
            # hook's bash cut follows the same rules; foundation-parts.bats checks the two agree.
            c = 0
            if (mode == "fill") {
                if (index(w, "\n")) { a = after_last(w, "^.*\n"); if (a >= 0 && a <= 400 && wb - a > c) c = wb - a }
                if (has_stop(w)) { a = after_last(w, "^.*[.!?][ \t]"); if (a >= 0 && a <= 400 && wb - a > c) c = wb - a }
                if (index(w, JSTOP)) { a = after_last(w, "^.*" JSTOP); if (a >= 0 && a <= 400 && wb - a > c) c = wb - a }
                if (c > 0) best = c
            }
            if (c == 0) {
                a = -1
                if (has_blank(w) || index(w, "\n") || index(w, "\r")) a = after_last(w, "^.*[ \t\n\r]")
                if (a >= 0 && a + 1 <= 256) best = wb - a
            }
        } else {
            # The last line end in the second half, else the last sentence end, else the Japanese
            # full stop, else the last blank; failing all of those, hard, between characters.
            half = int(wb / 2); a = -1
            if (index(w, "\n")) a = after_last(w, "^.*\n")
            if (a >= 0 && wb - a >= half) best = wb - a
            else {
                a = -1
                if (has_stop(w)) a = after_last(w, "^.*[.!?][ \t]")
                if (a >= 0 && wb - a >= half) best = wb - a
                else {
                    a = -1
                    if (index(w, JSTOP)) a = after_last(w, "^.*" JSTOP)
                    if (a >= 0 && wb - a >= half) best = wb - a
                    else {
                        a = -1
                        if (has_blank(w)) a = after_last(w, "^.*[ \t]")
                        if (a >= 0 && wb - a >= half) best = wb - a
                    }
                }
            }
        }
        P[++n_out] = best; pos += best
    }
    return n_out
}

BEGIN {
    for (k = 128; k < 192; k++) ISCONT[sprintf("%c", k)] = 1
    for (k = 240; k < 248; k++) ISASTRAL[sprintf("%c", k)] = 1
    JSTOP = sprintf("%c%c%c", 227, 128, 130)
}
{ S = (NR == 1) ? $0 : S "\n" $0 }
END {
    N = length(S)
    n = cut("tidy")
    if (n > max) n = cut("fill")
    if (n > max) n = cut("pack")
    for (k = 1; k <= n; k++) print P[k]
}
