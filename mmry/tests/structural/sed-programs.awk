# sed-programs.awk: every sed program in shell source, judged as sed will receive it (#31737).
#
# Run by structural/bash32-portability.bats as:  LC_ALL=C awk -f sed-programs.awk FILE...
# Prints one line per finding:  path TAB line TAB rule TAB detail
# where rule is label, join, nulldata or lost. bash32-portability.bats names and explains each.
# With -v trace=1 it also prints every program it judges, rule "trace", to show what it read.
#
# WHY A READER AND NOT A PATTERN. A text pattern sees the characters in the file; sed sees what the
# shell hands it after quote removal. sed ":a;N;\$!ba" and sed ':a;N;$!ba' are different text and
# the same program, and #31737 QA round 1 got the first past a pattern written for the second. So
# this reads each file the way the shell does, as far as it takes to recover every sed command's
# arguments:
#   - single quotes; double quotes, where \$ \` \" \\ and \<newline> are the only escapes; $'...'
#     with its escapes; backslashes outside quotes, line continuations included;
#   - $(...), backticks and <(...), whose commands are read too, inside double quotes as well;
#   - ${...}, $((...)), ((...)) and $name, which stand for text the shell supplies at run time;
#   - here-documents, whose body lines are read one by one as commands: a body fed to bash is a
#     script, and a body that is prose costs nothing because each line is read on its own;
#   - the string given to bash -c or sh -c and the words given to eval, read as scripts in turn;
#   - a variable given a literal earlier in the same file, so sed "$prog" is judged by the literal.
# A word that is sed, or ends in /sed, anywhere in a simple command is taken as the command, which
# covers env, command, xargs, bats' run and a leading backslash. Its options are read the way GNU
# getopt reads them: -zE and --null are -z, and -ez is -e with the program "z".
#
# The program is then read command by command the way GNU sed reads it, which is how the label rule
# can say where GNU and BSD sed part: GNU ends a label at ; or } or a blank, BSD reads it to the end
# of the line.
#
# POSIX awk only: the suite runs this under BWK awk on macOS, mawk on Ubuntu, gawk on Windows Git
# Bash and BusyBox awk in a bash 3.2 container. LC_ALL=C makes every byte one character.

BEGIN {
    PH = "\001"     # stands for text the shell supplies at run time
    NLONG = split("expression file in-place line-length null-data zero-terminated quiet silent " \
                  "regexp-extended separate unbuffered debug posix sandbox follow-symlinks binary " \
                  "help version", LONGS, " ")
    started = 0
}

FNR == 1 {
    if (started) finish()
    started = 1; fname = FILENAME; nl = 0
}
{
    sub(/\r$/, "")
    LN[++nl] = $0
}
END { if (started) finish() }

# One file: the file itself, then every script found inside it (here-document lines, bash -c and
# eval strings), each read with a fresh shell state.
function finish(    i, n, q) {
    rel = fname
    if (substr(rel, 1, 2) == "./") rel = substr(rel, 3)
    split("", ASSIGN); split("", SEEN)
    for (i = 1; i <= nl; i++) LB[i] = i
    qn = 0
    lex(nl, "f")
    for (q = 1; q <= qn; q++) {
        n = split(QT[q], LN, "\n")
        for (i = 1; i <= n; i++) LB[i] = QL[q] + i - 1
        lex(n, QK[q])
    }
}

function enqueue(text, line, kind) { qn++; QT[qn] = text; QL[qn] = line; QK[qn] = kind }

function isin(set, ch) { return ch != "" && index(set, ch) > 0 }

function report(line, rule, detail,    key) {
    key = line SUBSEP rule
    if (key in SEEN) return
    SEEN[key] = 1
    printf "%s\t%s\t%s\t%s\n", rel, line, rule, detail
}

# ---------------------------------------------------------------------------------------------
# The shell reader. A stack of states: C (top level), P ($(...) or <(...)), B (backticks) are
# command contexts, each collecting the words of its current simple command; S, D, A are single,
# double and $'...' quotes; X, XS, XD are ${...} and quotes inside it; R is arithmetic.
# ---------------------------------------------------------------------------------------------

function lex(n, kind,    li, line, ll, i, t, j) {
    sp = 1; ST[1] = "C"; SL[1] = 0; CK[1] = 1; cmdinit(1); HDN = 0; CONT = 0
    for (li = 1; li <= n; li++) {
        line = LN[li]; cur = LB[li]; ll = length(line); i = 1
        while (i <= ll) {
            t = ST[sp]
            if (t == "S") {
                j = index(substr(line, i), "'")
                if (j == 0) { addw(substr(line, i)); i = ll + 1 }
                else { addw(substr(line, i, j - 1)); i += j; sp-- }
            }
            else if (t == "C" || t == "P" || t == "B") i = in_cmd(line, i, ll, t)
            else if (t == "D") i = in_dq(line, i, ll)
            else if (t == "A") i = in_ansi(line, i, ll)
            else if (t == "X") i = in_param(line, i, ll)
            else if (t == "XS") {
                j = index(substr(line, i), "'")
                if (j == 0) i = ll + 1; else { i += j; sp-- }
            }
            else if (t == "XD") i = in_param_dq(line, i, ll)
            else i = in_arith(line, i, ll)
        }
        if (CONT) { CONT = 0; continue }        # backslash-newline: the newline is removed
        t = ST[sp]
        if (t == "S" || t == "D" || t == "A") addw("\n")
        else if (t == "C" || t == "P" || t == "B") {
            endc(sp)
            if (HDN > 0) li = bodies(li, n, kind)
        }
    }
    if (kind != "h" && sp > 1)
        report(SL[2], "lost", "a " what(ST[2]) " opened here is never closed")
}

function what(t) {
    if (t == "S") return "single-quoted string"
    if (t == "D") return "double-quoted string"
    if (t == "A") return "$'...' string"
    if (t == "P") return "$(...) substitution"
    if (t == "B") return "backtick substitution"
    if (t == "R") return "arithmetic expression"
    return "${...} expansion"
}

function cmdinit(k) { WIN[k] = 0; WN[k] = 0; SKIP[k] = 0; PD[k] = 0 }
function push(t) { sp++; ST[sp] = t; SL[sp] = cur; CK[sp] = CK[sp - 1] }
function pushcmd(t) { sp++; ST[sp] = t; SL[sp] = cur; CK[sp] = sp; cmdinit(sp) }

function startw(k) { WIN[k] = 1; W[k] = ""; WSL[k] = cur; WV[k] = ""; WVOK[k] = 1 }
function touchw(    k) { k = CK[sp]; if (!WIN[k]) startw(k) }
function addw(s,    k) {
    k = CK[sp]
    if (!WIN[k]) startw(k)
    if (s != "") { W[k] = W[k] s; WVOK[k] = 0 }
}
# $name: remembered, so a word that is exactly one variable can be judged by that variable's literal.
function addvar(name,    k) {
    k = CK[sp]
    if (!WIN[k]) startw(k)
    if (WVOK[k] && W[k] == "") WV[k] = name; else WVOK[k] = 0
    W[k] = W[k] PH
}
function endw(k) {
    if (!WIN[k]) return
    WIN[k] = 0
    if (SKIP[k]) { SKIP[k] = 0; return }     # a redirection's target is not an argument
    WN[k]++
    WD[k, WN[k]] = W[k]; WL[k, WN[k]] = WSL[k]; WVAR[k, WN[k]] = (WVOK[k] ? WV[k] : "")
}
function endc(k) { endw(k); if (WN[k] > 0) analyze(k); WN[k] = 0; SKIP[k] = 0 }

function in_cmd(line, i, ll, t,    k, rest, c, c2) {
    k = sp
    rest = substr(line, i)
    if (!match(rest, /[ \t\\'"$`;&|()<>#]/)) { addw(rest); return ll + 1 }
    if (RSTART > 1) { addw(substr(rest, 1, RSTART - 1)); return i + RSTART - 1 }
    c = substr(line, i, 1); c2 = substr(line, i + 1, 1)
    if (c == " " || c == "\t") { endw(k); return i + 1 }
    if (c == "#") { if (WIN[k]) { addw("#"); return i + 1 }; return ll + 1 }
    if (c == "\\") {
        if (c2 == "") { CONT = 1; return ll + 1 }
        addw(c2); return i + 2
    }
    if (c == "'") { touchw(); push("S"); return i + 1 }
    if (c == "\"") { touchw(); push("D"); return i + 1 }
    if (c == "$") return dollar(line, i)
    if (c == "`") {
        if (t == "B") { endc(k); sp--; return i + 1 }
        addw(PH); pushcmd("B"); return i + 1
    }
    if (c == ";" || c == "&" || c == "|") { endc(k); return i + 1 }
    if (c == "(") {
        if (!WIN[k] && c2 == "(") { push("R"); RP[sp] = 0; return i + 2 }
        endc(k)
        if (t == "P") PD[k]++
        return i + 1
    }
    if (c == ")") {
        endc(k)
        if (t == "P") { if (PD[k] > 0) PD[k]--; else sp-- }
        return i + 1
    }
    # < or >. A word of digits right before it is a file descriptor, not an argument.
    if (WIN[k] && W[k] ~ /^[0-9]+$/) WIN[k] = 0; else endw(k)
    if (c2 == "(") { addw(PH); pushcmd("P"); return i + 2 }
    if (c == "<" && c2 == "<") {
        if (substr(line, i + 2, 1) == "<") { SKIP[k] = 1; return i + 3 }
        return heredoc(line, i + 2)
    }
    i++
    if (isin("<>&|", substr(line, i, 1))) i++
    SKIP[k] = 1
    return i
}

function in_dq(line, i, ll,    rest, c, c2) {
    rest = substr(line, i)
    if (!match(rest, /[\\"$`]/)) { addw(rest); return ll + 1 }
    if (RSTART > 1) { addw(substr(rest, 1, RSTART - 1)); return i + RSTART - 1 }
    c = substr(line, i, 1); c2 = substr(line, i + 1, 1)
    if (c == "\\") {
        if (c2 == "") { CONT = 1; return ll + 1 }
        if (isin("$`\"\\", c2)) { addw(c2); return i + 2 }
        addw("\\"); return i + 1
    }
    if (c == "\"") { sp--; return i + 1 }
    if (c == "$") return dollar(line, i)
    addw(PH); pushcmd("B"); return i + 1
}

function in_ansi(line, i, ll,    rest, c2, j) {
    rest = substr(line, i)
    if (!match(rest, /[\\']/)) { addw(rest); return ll + 1 }
    if (RSTART > 1) { addw(substr(rest, 1, RSTART - 1)); return i + RSTART - 1 }
    if (substr(line, i, 1) == "'") { sp--; return i + 1 }
    c2 = substr(line, i + 1, 1)
    if (c2 == "") { addw("\\"); return i + 1 }
    if (c2 == "n") addw("\n")
    else if (c2 == "t") addw("\t")
    else if (c2 == "r") addw("\r")
    else if (isin("\\'\"?", c2)) addw(c2)
    else if (isin("abefvE", c2)) addw(PH)
    else if (isin("01234567", c2)) {
        addw(PH); j = i + 2
        while (j < i + 4 && isin("01234567", substr(line, j, 1))) j++
        return j
    }
    else if (c2 == "x" || c2 == "u" || c2 == "U") {
        addw(PH); j = i + 2
        while (j < i + 2 + (c2 == "x" ? 2 : (c2 == "u" ? 4 : 8)) && isin("0123456789abcdefABCDEF", substr(line, j, 1))) j++
        return j
    }
    else if (c2 == "c") { addw(PH); return i + 3 }
    else addw("\\" c2)
    return i + 2
}

function in_param(line, i, ll,    rest, c, c2) {
    rest = substr(line, i)
    if (!match(rest, /[\\${}'"`]/)) return ll + 1
    i += RSTART - 1
    c = substr(line, i, 1); c2 = substr(line, i + 1, 1)
    if (c == "\\") return i + 2
    if (c == "$") {
        if (c2 == "{") { XD[sp]++; return i + 2 }
        if (c2 == "(") {
            if (substr(line, i + 2, 1) == "(") { push("R"); RP[sp] = 0; return i + 3 }
            pushcmd("P"); return i + 2
        }
        return i + 1
    }
    if (c == "`") { pushcmd("B"); return i + 1 }
    if (c == "}") { if (XD[sp] > 0) XD[sp]--; else sp--; return i + 1 }
    if (c == "{") return i + 1
    if (c == "'") { if (!XQ[sp]) push("XS"); return i + 1 }
    push("XD"); return i + 1
}

function in_param_dq(line, i, ll,    rest, c, c2) {
    rest = substr(line, i)
    if (!match(rest, /[\\"$`]/)) return ll + 1
    i += RSTART - 1
    c = substr(line, i, 1); c2 = substr(line, i + 1, 1)
    if (c == "\\") return i + 2
    if (c == "\"") { sp--; return i + 1 }
    if (c == "$") {
        if (c2 == "(") {
            if (substr(line, i + 2, 1) == "(") { push("R"); RP[sp] = 0; return i + 3 }
            pushcmd("P"); return i + 2
        }
        if (c2 == "{") { push("X"); XD[sp] = 0; XQ[sp] = 1; return i + 2 }
        return i + 1
    }
    pushcmd("B"); return i + 1
}

function in_arith(line, i, ll,    rest, c, c2) {
    rest = substr(line, i)
    if (!match(rest, /[()$`]/)) return ll + 1
    i += RSTART - 1
    c = substr(line, i, 1); c2 = substr(line, i + 1, 1)
    if (c == "(") { RP[sp]++; return i + 1 }
    if (c == ")") {
        if (RP[sp] > 0) { RP[sp]--; return i + 1 }
        sp--
        return (c2 == ")") ? i + 2 : i + 1
    }
    if (c == "$") {
        if (c2 == "(" && substr(line, i + 2, 1) != "(") { pushcmd("P"); return i + 2 }
        if (c2 == "{") { push("X"); XD[sp] = 0; XQ[sp] = 1; return i + 2 }
        return i + 1
    }
    pushcmd("B"); return i + 1
}

function dollar(line, i,    c2, rest) {
    c2 = substr(line, i + 1, 1)
    if (c2 == "(") {
        addw(PH)
        if (substr(line, i + 2, 1) == "(") { push("R"); RP[sp] = 0; return i + 3 }
        pushcmd("P"); return i + 2
    }
    if (c2 == "{") {
        rest = substr(line, i + 2)
        if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*[}]/)) { addvar(substr(rest, 1, RLENGTH - 1)); return i + 2 + RLENGTH }
        addw(PH); push("X"); XD[sp] = 0; XQ[sp] = (ST[sp - 1] == "D"); return i + 2
    }
    if (ST[sp] != "D" && c2 == "'") { touchw(); push("A"); return i + 2 }
    if (ST[sp] != "D" && c2 == "\"") { touchw(); push("D"); return i + 2 }
    rest = substr(line, i + 1)
    if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) { addvar(substr(rest, 1, RLENGTH)); return i + 1 + RLENGTH }
    if (isin("0123456789?!#$@*-", c2)) { addw(PH); return i + 2 }
    addw("$"); return i + 1
}

function heredoc(line, i,    ll, strip, d, c, j) {
    ll = length(line); strip = 0
    if (substr(line, i, 1) == "-") { strip = 1; i++ }
    while (isin(" \t", substr(line, i, 1))) i++
    d = ""
    while (i <= ll) {
        c = substr(line, i, 1)
        if (isin(" \t;&|()<>", c)) break
        if (c == "'" || c == "\"") {
            j = index(substr(line, i + 1), c)
            if (j == 0) { d = d substr(line, i + 1); i = ll + 1; break }
            d = d substr(line, i + 1, j - 1); i += j + 1; continue
        }
        if (c == "\\") { d = d substr(line, i + 1, 1); i += 2; continue }
        d = d c; i++
    }
    if (d != "") { HDN++; HDD[HDN] = d; HDS[HDN] = strip; HDL[HDN] = cur }
    return i
}

# The bodies of the here-documents opened on line li; returns the last line they take.
function bodies(li, n, kind,    h, b, found) {
    for (h = 1; h <= HDN; h++) {
        found = 0
        while (li < n) {
            li++
            b = LN[li]
            if (HDS[h]) sub(/^\t+/, "", b)
            if (b == HDD[h]) { found = 1; break }
            enqueue(LN[li], LB[li], "h")
        }
        if (!found && kind != "h")
            report(HDL[h], "lost", "a here-document opened here never reaches its " HDD[h] " line")
    }
    HDN = 0
    return li
}

# ---------------------------------------------------------------------------------------------
# One simple command: remember literal assignments, then find sed, bash -c or eval in it.
# ---------------------------------------------------------------------------------------------

function analyze(k,    nw, i, w, b, decl, lead, eq) {
    nw = WN[k]
    decl = (WD[k, 1] ~ /^(local|declare|readonly|export|typeset)$/)
    lead = 1
    for (i = 1; i <= nw; i++) {
        w = WD[k, i]
        if ((lead || decl) && w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
            eq = index(w, "=")
            ASSIGN[substr(w, 1, eq - 1)] = substr(w, eq + 1)
            continue
        }
        if (!(decl && i == 1)) lead = 0
    }
    for (i = 1; i <= nw; i++) {
        b = WD[k, i]
        sub(/.*\//, "", b)
        if (b == "sed") { sedcmd(k, i); return }
        if (b == "bash" || b == "sh" || b == "dash" || b == "zsh" || b == "ksh") { shc(k, i); return }
        if (b == "eval") { evalc(k, i); return }
    }
}

function wordval(k, j) {
    if (WVAR[k, j] != "" && (WVAR[k, j] in ASSIGN)) return ASSIGN[WVAR[k, j]]
    return WD[k, j]
}

function shc(k, at,    nw, j, a, hasc) {
    nw = WN[k]; hasc = 0
    for (j = at + 1; j <= nw; j++) {
        a = WD[k, j]
        if (a == "--" || a == "-") { j++; break }
        if (a ~ /^[-+]/) {
            if (a !~ /^--/ && index(a, "c")) hasc = 1
            if (a == "-o" || a == "+o" || a == "-O" || a == "+O") j++
            continue
        }
        break
    }
    if (hasc && j <= nw) enqueue(wordval(k, j), WL[k, j], "c")
}

function evalc(k, at,    j, s) {
    s = ""
    for (j = at + 1; j <= WN[k]; j++) s = s (j > at + 1 ? " " : "") wordval(k, j)
    if (s != "") enqueue(s, WL[k, at], "c")
}

# A long option, or the one long option it abbreviates, or "" if it is none or ambiguous.
function longopt(nm,    i, hit, cnt) {
    cnt = 0; hit = ""
    for (i = 1; i <= NLONG; i++) {
        if (LONGS[i] == nm) return nm
        if (nm != "" && index(LONGS[i], nm) == 1) { cnt++; hit = LONGS[i] }
    }
    return (cnt == 1) ? hit : ""
}

# sed's arguments, read the way GNU getopt reads them.
function sedcmd(k, at,    nw, line, j, a, nm, v, hasv, p, full, c, ch, nexpr, prog, ns, zf, endopts, bare_i) {
    nw = WN[k]; line = WL[k, at]
    nexpr = 0; prog = ""; ns = 0; zf = ""; endopts = 0; bare_i = 0
    for (j = at + 1; j <= nw; j++) {
        a = WD[k, j]
        if (endopts || a == "-" || substr(a, 1, 1) != "-") { NO[++ns] = j; continue }
        if (a == "--") { endopts = 1; continue }
        if (substr(a, 1, 2) == "--") {
            nm = substr(a, 3); hasv = 0; v = ""
            p = index(nm, "=")
            if (p > 0) { v = substr(nm, p + 1); nm = substr(nm, 1, p - 1); hasv = 1 }
            full = longopt(nm)
            if (full == "null-data" || full == "zero-terminated") { if (zf == "") zf = a }
            else if (full == "expression") {
                if (!hasv && j < nw) { j++; v = wordval(k, j) }
                prog = (nexpr ? prog "\n" : "") v; nexpr++
            }
            else if (full == "file" || full == "line-length") {
                if (full == "file") nexpr++
                if (!hasv) j++
            }
            continue
        }
        for (c = 2; c <= length(a); c++) {
            ch = substr(a, c, 1)
            if (ch == "e" || ch == "f" || ch == "l") {
                v = substr(a, c + 1)
                if (v == "" && j < nw) { j++; v = wordval(k, j) }
                if (ch == "e") { prog = (nexpr ? prog "\n" : "") v; nexpr++ }
                if (ch == "f") nexpr++
                break
            }
            if (ch == "i") { if (c == length(a)) bare_i = 1; break }     # GNU -i[SUFFIX]
            if (ch == "z" && zf == "") zf = a
        }
    }
    if (zf != "") report(line, "nulldata", "sed receives the option " zf)
    if (nexpr > 0) judge(prog, line)
    else if (ns > 0) {
        judge(wordval(k, NO[1]), line)
        if (bare_i && ns > 1) judge(wordval(k, NO[2]), line)    # BSD reads -i's suffix as a word
    }
}

# ---------------------------------------------------------------------------------------------
# One sed program, read command by command the way GNU sed reads it.
# ---------------------------------------------------------------------------------------------

function judge(p, line,    i, c, j, e, rest, labelhit, accN, accH, accG, acch, accX) {
    if (trace) printf "%s\t%s\ttrace\tsed receives %s\n", rel, line, show(p)
    JP = p; JN = length(p); NLRE = 0
    labelhit = 0; accN = 0; accH = 0; accG = 0; acch = 0; accX = 0
    i = 1
    while (i <= JN) {
        c = substr(JP, i, 1)
        if (isin(" \t\n;", c)) { i++; continue }
        if (c == "#") { i = jeol(i); continue }
        i = jaddr(i)
        if (substr(JP, i, 1) == ",") {
            i++
            while (isin(" \t", substr(JP, i, 1))) i++
            if (isin("+~", substr(JP, i, 1))) { i++; while (isin("0123456789", substr(JP, i, 1))) i++ }
            else i = jaddr(i)
        }
        while (isin(" \t!", substr(JP, i, 1))) i++
        c = substr(JP, i, 1)
        if (c == "") break
        if (c == "{" || c == "}") { i++; continue }
        if (c == ":" || c == "b" || c == "t" || c == "T") {
            # GNU's name ends at a blank, ; or }. BSD's runs to the end of the line, so anything after
            # GNU's name on the same line makes BSD read a different name.
            i++
            while (isin(" \t", substr(JP, i, 1))) i++
            j = i
            while (j <= JN && !isin(" \t\n;}", substr(JP, j, 1))) j++
            e = j
            while (e <= JN && substr(JP, e, 1) != "\n") e++
            rest = substr(JP, j, e - j)
            gsub(/[ \t]/, "", rest)
            if (rest != "") labelhit = 1
            i = j
            continue
        }
        if (c == "s") {
            i = jdelim(i + 1)
            while (isin("gpiImMe0123456789", substr(JP, i, 1))) i++
            if (substr(JP, i, 1) == "w") i = jeol(i)
            continue
        }
        if (c == "y") { i = jdelim(i + 1); continue }
        if (c == "a" || c == "i" || c == "c") { i = jtext(i + 1); continue }
        if (isin("rRwWe", c)) { i = jeol(i + 1); continue }
        if (c == "N") accN = 1
        else if (c == "H") accH = 1
        else if (c == "G") accG = 1
        else if (c == "h") acch = 1
        else if (c == "x" || c == "g") accX = 1
        if (isin("dDgGhHlnNpPxzF=qQL", c)) {
            i++
            while (isin("0123456789", substr(JP, i, 1))) i++
            continue
        }
        if (c == "v") { i++; while (i <= JN && !isin("\n;}", substr(JP, i, 1))) i++; continue }
        break       # not a sed command: stop reading, keep what was found
    }
    if (labelhit) report(line, "label", "sed receives " show(p))
    # Lines gathered into one pattern space (N, or the hold space filled and fetched back) and the
    # newline between them matched: a join, whatever it is spelled with.
    if (NLRE && (accN || (accH && (accX || accG)) || (accG && (acch || accX))))
        report(line, "join", "sed receives " show(p))
}

function jeol(i) { while (i <= JN && substr(JP, i, 1) != "\n") i++; return i }

function jtext(i,    c) {
    while (i <= JN) {
        c = substr(JP, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == "\n") return i
        i++
    }
    return i
}

function jaddr(i,    c, d) {
    c = substr(JP, i, 1)
    if (isin("0123456789", c)) {
        while (isin("0123456789", substr(JP, i, 1))) i++
        if (substr(JP, i, 1) == "~") { i++; while (isin("0123456789", substr(JP, i, 1))) i++ }
        return i
    }
    if (c == "$") return i + 1
    if (c == "/" || c == "\\") {
        if (c == "\\") { d = substr(JP, i + 1, 1); if (d == "" || d == "\n") return i + 1; i++ }
        else d = "/"
        i = jre(i + 1, d)
        while (isin("IM", substr(JP, i, 1))) i++
        return i
    }
    return i
}

# A regex up to its closing delimiter; notes a match on the newline, \n or a backslash-newline.
function jre(i, d,    c, c2) {
    while (i <= JN) {
        c = substr(JP, i, 1)
        if (c == "\\") {
            c2 = substr(JP, i + 1, 1)
            if (c2 == "n" || c2 == "\n") NLRE = 1
            i += 2; continue
        }
        if (c == d) return i + 1
        i++
    }
    return i
}

# s/regex/replacement/ or y/source/dest/: the first part may match the newline, the second cannot.
function jdelim(i,    d, c) {
    d = substr(JP, i, 1)
    if (d == "" || d == "\n" || d == "\\") return JN + 1
    i = jre(i + 1, d)
    while (i <= JN) {
        c = substr(JP, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == d) return i + 1
        i++
    }
    return i
}

function show(p,    s) {
    s = p
    gsub(PH, "<$>", s)
    gsub(/\n/, "<NL>", s)
    gsub(/\t/, "<TAB>", s)
    return "'" s "'"
}
