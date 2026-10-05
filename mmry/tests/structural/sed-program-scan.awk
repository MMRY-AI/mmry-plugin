# sed-program-scan.awk - read every sed call the way bash and sed will, and name what will not
# survive the macOS sed (#31737 QA round 1).
#
# WHY NOT A REGEX OVER THE TEXT. The 2.9.1 line join is one PROGRAM with many spellings. Written in
# double quotes it is sed ":a;N;\$!ba;s/\n/ /g", and bash hands sed exactly the bytes of the
# single-quoted form; a regex over the text sees a backslash the program does not have. QA found
# that and six more spellings past the round 1 regexes. So this does what the shell does first
# (unquote the words, follow continuations), then what sed does (gather the -e parts, read the
# flags, walk the commands), and only then judges the program.
#
# WHAT IT REFUSES, by how sed reads the program:
#   - a label or branch that runs into ";" or "}". GNU sed ends a label there; BSD sed, the one macOS
#     ships, takes the rest of the line as the label and fails, which is the 2.9.1 fault.
#   - -z, or --null-data / --zero-terminated or any prefix getopt would accept for them, in any flag
#     group and in any position. BSD sed has no NUL-separated mode.
#   - a } with no ; or newline before it, as in "p}". BSD sed rejects it; "p;}" is fine.
#   - a line join: N, H, G or -z, together with a newline in an s or y pattern. This is the class the
#     product replaced with a bash join, so it is refused even where the spelling is portable.
#
# WHAT IT CANNOT SEE, stated rather than implied: a program held in a variable or read from a file
# (-f), a sed reached through eval or a wrapper function, and a call split across a here-document.
#
# Input: one path per line on stdin. -v root=DIR is stripped from each path in the output.
# Output: "relative/path:LINE: finding", once per finding per line. POSIX awk only: it has to run
# on the BSD awk macOS ships, on BusyBox and on gawk.

BEGIN {
    BS = "\\"
    NL = "\n"
    F_LABEL = "sed reads a label or branch that runs into ; or } (GNU-only: BSD sed takes the rest of the line as the label)"
    F_NULL = "sed reads -z or --null-data (GNU-only: BSD sed has no NUL-separated mode)"
    F_JOIN = "sed reads a line join (N, H, G or -z, then a newline in s or y): use the bash join"
    F_BRACE = "sed reads a } with no ; or newline before it (BSD sed rejects it; write ;})"
}

{
    p0 = $0
    sub(/\r$/, "", p0)
    if (p0 != "") scan_file(p0)
}

function scan_file(path,    n, l, i, rel) {
    n = 0
    while ((getline l < path) > 0) { sub(/\r$/, "", l); LINES[++n] = l }
    close(path)
    NLINES = n
    rel = path
    if (root != "" && index(rel, root "/") == 1) rel = substr(rel, length(root) + 2)
    for (i = 1; i <= n; i++) scan_line(rel, i)
    for (i = 1; i <= n; i++) delete LINES[i]
}

# A comment is not a use: a whole-line or trailing comment is cut off before sed is looked for.
function scan_line(rel, ln,    code, p) {
    code = strip_comment(LINES[ln])
    p = 1
    while ((p = find_sed(code, p)) > 0) {
        read_call(rel, ln, p + 3)
        p += 3
    }
}

function strip_comment(s,    i, c, q, n) {
    q = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "'") { if (c == "'") q = ""; continue }
        if (q == "\"") { if (c == BS) { i++; continue } if (c == "\"") q = ""; continue }
        if (c == BS) { i++; continue }
        if (c == "'" || c == "\"") { q = c; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;|&(]/)) return substr(s, 1, i - 1)
    }
    return s
}

# The next "sed" that stands as a command word: after a boundary or a path, before a blank.
function find_sed(code, from,    k, rest, at, before, after) {
    k = from
    while (1) {
        rest = substr(code, k)
        at = index(rest, "sed")
        if (at == 0) return 0
        k = k + at - 1
        before = (k == 1) ? "" : substr(code, k - 1, 1)
        after = substr(code, k + 3, 1)
        if ((before == "" || before ~ /[ \t|;&(`{!\/\\]/) && (after == " " || after == "\t" || after == ""))
            return k
        k++
    }
}

# --- the shell: words, quotes and continuations, from just after "sed" ---------------------------

function peekc() { return (T_POS <= length(T_S)) ? substr(T_S, T_POS, 1) : "" }
function nextline() {
    if (T_LN >= NLINES || T_EXT >= 200) return 0
    T_LN++; T_EXT++; T_S = LINES[T_LN]; T_POS = 1
    return 1
}

function read_call(rel, ln, pos,    c, w, got) {
    T_LN = ln; T_POS = pos; T_S = LINES[ln]; T_EXT = 0
    NW = 0
    while (1) {
        c = peekc()
        if (c == "") break
        if (c == " " || c == "\t") { T_POS++; continue }
        if (c == "#" || c ~ /[|;&)<>`]/) break
        w = ""; got = 0
        while (1) {
            c = peekc()
            if (c == "" || c == " " || c == "\t" || c ~ /[|;&)<>`]/) break
            if (c == BS) {
                T_POS++
                if (peekc() == "") { if (!nextline()) break; continue }
                w = w peekc(); T_POS++; got = 1; continue
            }
            got = 1
            if (c == "'") { T_POS++; w = w read_single(); continue }
            if (c == "\"") { T_POS++; w = w read_double(); continue }
            if (c == "$" && substr(T_S, T_POS + 1, 1) == "'") { T_POS += 2; w = w read_ansi(); continue }
            if (c == "$" && substr(T_S, T_POS + 1, 1) == "(") { w = w read_paren(); continue }
            w = w c; T_POS++
        }
        if (got) W[++NW] = w
        if (peekc() == "") break
    }
    judge(rel, ln)
}

function read_single(    r, c) {
    r = ""
    while (1) {
        c = peekc()
        if (c == "") { if (!nextline()) return r; r = r NL; continue }
        T_POS++
        if (c == "'") return r
        r = r c
    }
}

# Inside double quotes a backslash escapes only $ ` " \ and newline; any other stays.
function read_double(    r, c, n2) {
    r = ""
    while (1) {
        c = peekc()
        if (c == "") { if (!nextline()) return r; r = r NL; continue }
        T_POS++
        if (c == "\"") return r
        if (c == BS) {
            n2 = peekc()
            if (n2 == "") { if (!nextline()) return r; continue }
            if (n2 == "$" || n2 == "`" || n2 == "\"" || n2 == BS) { r = r n2; T_POS++; continue }
            r = r BS; continue
        }
        if (c == "$" && peekc() == "(") { T_POS--; r = r read_paren(); continue }
        r = r c
    }
}

function read_ansi(    r, c, n2) {
    r = ""
    while (1) {
        c = peekc()
        if (c == "") { if (!nextline()) return r; r = r NL; continue }
        T_POS++
        if (c == "'") return r
        if (c == BS) {
            n2 = peekc(); T_POS++
            if (n2 == "n") r = r NL
            else if (n2 == "t") r = r "\t"
            else if (n2 == BS || n2 == "'" || n2 == "\"") r = r n2
            else r = r BS n2
            continue
        }
        r = r c
    }
}

function read_paren(    r, c, depth) {
    r = "$("; T_POS += 2; depth = 1
    while (depth > 0) {
        c = peekc()
        if (c == "") { if (!nextline()) return r; r = r NL; continue }
        T_POS++
        if (c == "(") depth++
        else if (c == ")") depth--
        r = r c
    }
    return r
}

# --- sed: options, then the program ---------------------------------------------------------------

function is_prefix(s, of) { return s != "" && index(of, s) == 1 }

function judge(rel, ln,    i, w, name, val, eq, j, c, rest, prog, nprog, fromfile, nop, op1, z) {
    prog = ""; nprog = 0; fromfile = 0; nop = 0; z = 0
    for (i = 1; i <= NW; i++) {
        w = W[i]
        if (w == "--") { for (i++; i <= NW; i++) if (++nop == 1) op1 = W[i]; break }
        if (substr(w, 1, 2) == "--") {
            name = substr(w, 3); val = ""; eq = index(name, "=")
            if (eq) { val = substr(name, eq + 1); name = substr(name, 1, eq - 1) }
            if (is_prefix(name, "null-data") || is_prefix(name, "zero-terminated")) z = 1
            else if (is_prefix(name, "expression")) {
                if (!eq) val = W[++i]
                prog = (nprog++ ? prog NL : "") val
            }
            else if (is_prefix(name, "file")) { fromfile = 1; if (!eq) i++ }
            else if (is_prefix(name, "line-length") && !eq) i++
            continue
        }
        if (substr(w, 1, 1) == "-" && length(w) > 1) {
            for (j = 2; j <= length(w); j++) {
                c = substr(w, j, 1)
                if (c == "e") {
                    rest = substr(w, j + 1); if (rest == "") rest = W[++i]
                    prog = (nprog++ ? prog NL : "") rest
                    break
                }
                if (c == "f") { fromfile = 1; if (substr(w, j + 1) == "") i++; break }
                if (c == "l") { if (substr(w, j + 1) == "") i++; break }
                if (c == "i") break
                if (c == "z") z = 1
            }
            continue
        }
        if (++nop == 1) op1 = w
    }
    if (nprog == 0 && !fromfile && nop > 0) { prog = op1; nprog = 1 }

    walk(prog)
    if (P_LABEL) report(rel, ln, F_LABEL)
    if (z) report(rel, ln, F_NULL)
    if ((P_MECH || z) && P_NL) report(rel, ln, F_JOIN)
    if (P_BRACE) report(rel, ln, F_BRACE)
}

function report(rel, ln, what,    key) {
    key = rel SUBSEP ln SUBSEP what
    if (key in SEEN) return
    SEEN[key] = 1
    printf "%s:%d: %s\n", rel, ln, what
}

function eol(P, pos,    k) {
    k = index(substr(P, pos), NL)
    return k ? pos + k - 1 : length(P) + 1
}

# Reads a delimited part from just after its opening delimiter, and returns the position after the
# closing one. P_SAWNL says whether it held \n, which in a sed pattern is a newline.
function delimited(P, pos, d,    c) {
    P_SAWNL = 0
    while (pos <= length(P)) {
        c = substr(P, pos, 1)
        if (c == BS) { if (substr(P, pos + 1, 1) == "n") P_SAWNL = 1; pos += 2; continue }
        if (c == d) return pos + 1
        if (c == NL) return pos
        pos++
    }
    return pos
}

function one_address(P, pos,    c) {
    c = substr(P, pos, 1)
    if (c ~ /[0-9]/) { while (substr(P, pos, 1) ~ /[0-9~]/) pos++; return pos }
    if (c == "$") return pos + 1
    if (c == "+" || c == "~") { pos++; while (substr(P, pos, 1) ~ /[0-9]/) pos++; return pos }
    if (c == "/") { pos = delimited(P, pos + 1, "/") }
    else if (c == BS) { pos = delimited(P, pos + 2, substr(P, pos + 1, 1)) }
    else return pos
    while (substr(P, pos, 1) ~ /[IM]/) pos++
    return pos
}


# BSD sed needs a ; or a newline before a closing }: "p;}" works on a stock Mac and "p}" does not
# (QA #2's probe on the Mac bench, 2026-10-05).
function closes_cleanly(P, pos,    k, c) {
    k = pos - 1
    while (k >= 1 && substr(P, k, 1) ~ /[ \t]/) k--
    if (k < 1) return 1
    c = substr(P, k, 1)
    return c == ";" || c == NL || c == "{"
}

function walk(P,    pos, L, c, d, e, lab) {
    P_LABEL = 0; P_MECH = 0; P_NL = 0; P_BRACE = 0
    pos = 1; L = length(P)
    while (pos <= L) {
        c = substr(P, pos, 1)
        if (c == "}") { if (!closes_cleanly(P, pos)) P_BRACE = 1; pos++; continue }
        if (c == " " || c == "\t" || c == NL || c == ";") { pos++; continue }
        if (c == "#") { pos = eol(P, pos); continue }
        pos = one_address(P, pos)
        while (substr(P, pos, 1) ~ /[ \t]/) pos++
        if (substr(P, pos, 1) == ",") { pos++; while (substr(P, pos, 1) ~ /[ \t]/) pos++; pos = one_address(P, pos) }
        while (substr(P, pos, 1) ~ /[ \t!]/) pos++
        c = substr(P, pos, 1)
        if (c == "{") { pos++; continue }
        if (c == ":" || c == "b" || c == "t" || c == "T") {
            pos++
            while (substr(P, pos, 1) ~ /[ \t]/) pos++
            e = eol(P, pos); lab = substr(P, pos, e - pos)
            if (lab ~ /[;}]/) P_LABEL = 1
            # Carry on the way GNU sed reads it, so later commands are still judged.
            while (pos < e && substr(P, pos, 1) !~ /[; \t}]/) pos++
            continue
        }
        if (c == "s" || c == "y") {
            d = substr(P, pos + 1, 1)
            if (d == "" || d == NL || d == BS) { pos++; continue }
            pos = delimited(P, pos + 2, d); if (P_SAWNL) P_NL = 1
            pos = delimited(P, pos, d)
            while (pos <= L && substr(P, pos, 1) !~ /[;}]/ && substr(P, pos, 1) != NL) pos++
            continue
        }
        if (c == "N" || c == "H" || c == "G") { P_MECH = 1; pos++; continue }
        if (c ~ /[aicrRwWe]/) {
            e = eol(P, pos)
            while (e > 1 && e <= L && substr(P, e - 1, 1) == BS) e = eol(P, e + 1)
            pos = e; continue
        }
        if (c ~ /[qQlL]/) { pos++; while (substr(P, pos, 1) ~ /[ \t0-9]/) pos++; continue }
        pos++
    }
}
