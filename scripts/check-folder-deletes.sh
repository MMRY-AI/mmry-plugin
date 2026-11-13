#!/usr/bin/env bash
# check-folder-deletes.sh - refuse a recursive delete of a variable path that is not guarded against
# being empty (#33618; the mmry repository has the same rule in scripts/check-rm-guards.sh, #33782).
#
# WHY THIS EXISTS. On 2026-11-08 a test script whose work folder had not been created deleted the
# computer's shared temporary folder, taking other work with it. QA of 33363 found the same pattern
# here: the mutation runners and several older scripts deleted a folder named by a variable, and some
# fell back to /tmp when TMPDIR was not set. One empty or wrong value would have done the same.
#
# THE RULE. In every tracked shell file in this repository, each rm whose options make it recursive
# (-r, -R, -rf, -fr, -f -r, --recursive) is read operand by operand. An operand built from a variable
# passes only when its FIRST expansion is written ${NAME:?...}, so an empty or unset value stops the
# shell before rm runs:
#
#     rm -rf "$W/tmp"          refused    (W empty -> /tmp)
#     rm -rf "${W}/tmp"        refused    (braces are not a guard)
#     rm -rf "${W:-/x}/tmp"    refused    (a default is not a guard)
#     rm -rf "${W:?}/tmp"      passes
#     rm -rf build/out         passes     (no variable)
#
# A command substitution or backtick as the first part of the path is refused for the same reason:
# it can print nothing. A line that genuinely cannot be written this way carries a documented
# exemption on the same line, with a reason, which the report counts:
#
#     rm -rf "$W"   # rm-guard-exempt: W is the checked mktemp -d result above
#
# `rm-guard-exempt:` with no reason after it is not an exemption. The guard against the shared
# temporary folder itself, and the root, is in the code: the mutation runners make and remove their
# work folder only through tests/helpers/work-dir.bash, and each shipped delete is of a fixed name
# inside a folder (tests/structural/folder-deletes-check.bats proves both).
#
# WHAT IT READS. The git index (git ls-files), not the disk, so an untracked scratch file cannot
# change the result and a committed one cannot hide from it. Shell files are *.sh, *.bash, *.bats,
# and extensionless files whose first line is a shell shebang. The bats libraries are submodules and
# are not in the index. A line ending in a backslash is joined to the next before it is read, and a
# line whose first character is # is a comment.
#
# NOT READ, BY NAME: the frozen release fixtures in FROZEN below. Each is a byte-for-byte copy of a
# script a customer's machine ran in 2.15.2, kept so the tests can run the real old code, and
# tests/handlers/self-update-cleanup.bats pins byte offsets inside one of them. Editing them would make
# them no longer the release they stand for. The report names each one it did not read.
#
# KNOWN LIMITS. It reads text, not a parse tree: an rm built at run time (eval, a variable holding
# the command name) is not seen, and an rm spelled inside a quoted string is read as if it ran. The
# second errs toward refusing.
#
# usage: bash scripts/check-folder-deletes.sh                 scan the repository (tracked)
#        bash scripts/check-folder-deletes.sh --file PATH...  scan only the named files (any location)
# Exit 0 clean, 1 if any unguarded line, 2 if it could not read what it was asked to read.
set -uo pipefail

die() { echo "REFUSED: $*" >&2; exit 2; }

files=()
skipped=()
FROZEN="mmry/tests/fixtures/self-update-2.15.2.sh mmry/tests/fixtures/session-init-2.15.2.sh"
if [ "${1:-}" = "--file" ]; then
    shift
    [ "$#" -gt 0 ] || die "--file needs at least one path."
    for f in "$@"; do
        [ -f "$f" ] && [ -r "$f" ] || die "cannot read $f, and a file that was not read cannot pass."
        files+=("$f")
    done
else
    [ "$#" -eq 0 ] || die "unknown argument '$1' (usage: check-folder-deletes.sh [--file PATH...])"
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository."
    cd "$root" || die "cannot enter $root."
    # sort -u: during a conflicted merge git ls-files lists an unmerged file once per stage
    listing="$(git ls-files | sort -u)" || die "git ls-files failed."
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        case " $FROZEN " in *" $f "*) skipped+=("$f"); continue ;; esac
        case "$f" in
            *.sh|*.bash|*.bats) files+=("$f") ;;
            */*.*|*.*) ;;
            *) head -1 "$f" 2>/dev/null | grep -qE '^#!.*(ba|z|k|da)?sh' && files+=("$f") ;;
        esac
    done <<< "$listing"
    [ "${#files[@]}" -gt 0 ] || die "found no tracked shell files; refusing to pass on nothing."
fi

# ---- quote state: 0 outside quotes, 1 inside "...", 2 inside '...', at the end of TEXT.
QSTATE=0
qstate() {
    # $( ... ) starts a fresh quoting context inside a double-quoted string, so the state outside it is
    # pushed (one digit per level, the dq flag) and restored at its closing parenthesis.
    local t="$1" n=${#1} i=0 c sq=0 dq=0 stack=""
    while [ "$i" -lt "$n" ]; do
        c="${t:i:1}"
        case "$c" in
            '') [ "$sq" -eq 0 ] && i=$((i + 1)) ;;
            "'") [ "$dq" -eq 0 ] && sq=$((1 - sq)) ;;
            '"') [ "$sq" -eq 0 ] && dq=$((1 - dq)) ;;
            '$') if [ "$sq" -eq 0 ] && [ "${t:i+1:1}" = "(" ]; then stack="$stack$dq"; dq=0; i=$((i + 1)); fi ;;
            ')') if [ "$sq" -eq 0 ] && [ "$dq" -eq 0 ] && [ -n "$stack" ]; then dq="${stack:${#stack}-1}"; stack="${stack%?}"; fi ;;
        esac
        i=$((i + 1))
    done
    QSTATE=0; [ "$dq" -eq 1 ] && QSTATE=1; [ "$sq" -eq 1 ] && QSTATE=2
    return 0
}

# ---- tokenizer: read the words after "rm " up to the end of that command.
# $2 is the quote state the rm sits in. Inside "..." (an rm written into a message or a payload) the
# command ends where that string closes; inside '...' (a trap body, or a payload) it ends at the
# closing single quote, whatever double quotes it holds.
# Sets TOKS (the words, quotes kept) and TOK_END (characters consumed). Bash 3.2 safe.
TOKS=(); TOK_END=0
tokenize() {
    local t="$1" ctx="${2:-0}" n=${#1} i=0 c nx w="" dq=0 depth=0 inword=0 j
    TOKS=()
    while [ "$i" -lt "$n" ]; do
        c="${t:i:1}"
        if [ "$ctx" -eq 2 ] && [ "$depth" -eq 0 ] && [ "$c" = "'" ]; then break; fi
        if [ "$ctx" -eq 1 ] && [ "$depth" -eq 0 ] && [ "$dq" -eq 0 ] && [ "$c" = '"' ]; then break; fi
        if [ "$dq" -eq 0 ] && [ "$depth" -eq 0 ]; then
            case "$c" in
                ' '|$'\t')
                    if [ "$inword" -eq 1 ]; then TOKS+=("$w"); w=""; inword=0; fi
                    i=$((i + 1)); continue ;;
                ';'|'&'|'|'|')'|'}') break ;;
                '<'|'>')
                    # 2>/dev/null: the "2" read so far belongs to the redirection, not the operands
                    case "$w" in *[!0-9]*|'') ;; *) w=""; inword=0 ;; esac
                    break ;;
                "'")
                    if [ "$inword" -eq 0 ]; then
                        # a single-quoted literal word: copy it whole, nothing in it expands
                        j=$((i + 1))
                        while [ "$j" -lt "$n" ] && [ "${t:j:1}" != "'" ]; do j=$((j + 1)); done
                        w="${t:i:$((j - i + 1))}"; inword=1; i=$((j + 1)); continue
                    fi
                    break ;;   # closes the quoted string this rm sits in (trap '...')
                '#') [ "$inword" -eq 0 ] && break ;;
            esac
        fi
        case "$c" in
            '\')
                w="$w$c${t:i+1:1}"; inword=1; i=$((i + 2)); continue ;;
            '"')
                [ "$depth" -eq 0 ] && dq=$((1 - dq)) ;;
            '$')
                nx="${t:i+1:1}"
                if [ "$nx" = "{" ] || [ "$nx" = "(" ]; then
                    depth=$((depth + 1)); w="$w$c$nx"; inword=1; i=$((i + 2)); continue
                fi ;;
            '{'|'(') [ "$depth" -gt 0 ] && depth=$((depth + 1)) ;;
            '}'|')') [ "$depth" -gt 0 ] && depth=$((depth - 1)) ;;
        esac
        w="$w$c"; inword=1; i=$((i + 1))
    done
    [ "$inword" -eq 1 ] && TOKS+=("$w")
    TOK_END=$i
}

# An operand is guarded when it holds no expansion, or its first expansion is ${NAME:?...}.
operand_guarded() {
    local op="$1" raw
    case "$op" in "'"*) return 0 ;; esac          # single-quoted: a literal
    raw="${op//\"/}"
    case "$raw" in *'$'*|*'`'*) ;; *) return 0 ;; esac
    [[ "$raw" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*|[0-9]+):\? ]]
}

# check_text TEXT -> 0 if every recursive rm in it is guarded, 1 otherwise. Counts variable rms.
rm_re='(^|[[:space:];&|({`"'"'"'])rm[[:space:]]+(.*)$'
VARRMS=0; EXEMPT=0
check_text() {
    local s="$1" whole="$1" trimmed rest w opts_done recursive bad=0 has_var pos
    trimmed="${s#"${s%%[![:space:]]*}"}"
    case "$trimmed" in '#'*) return 0 ;; esac
    if [[ "$s" =~ rm-guard-exempt:[[:space:]]*[^[:space:]] ]]; then
        [[ "$s" =~ $rm_re ]] && EXEMPT=$((EXEMPT + 1))
        return 0
    fi
    while [[ "$s" =~ $rm_re ]]; do
        rest="${BASH_REMATCH[2]}"
        pos=$(( ${#whole} - ${#BASH_REMATCH[0]} + ${#BASH_REMATCH[1]} ))
        qstate "${whole:0:pos}"
        tokenize "$rest" "$QSTATE"
        opts_done=0; recursive=0; has_var=0
        local operands=()
        for w in ${TOKS[@]+"${TOKS[@]}"}; do
            if [ "$opts_done" -eq 0 ]; then
                case "$w" in
                    --) opts_done=1; continue ;;
                    --recursive) recursive=1; continue ;;
                    --*) continue ;;
                    -?*) case "$w" in *[rR]*) recursive=1 ;; esac; continue ;;
                esac
                opts_done=1
            fi
            operands+=("$w")
        done
        if [ "$recursive" -eq 1 ]; then
            for w in ${operands[@]+"${operands[@]}"}; do
                case "${w//\"/}" in *'$'*|*'`'*) has_var=1 ;; esac
                operand_guarded "$w" || bad=1
            done
            [ "$has_var" -eq 1 ] && VARRMS=$((VARRMS + 1))
        fi
        s="${rest:TOK_END}"     # always a suffix of the whole line, so positions stay absolute
    done
    return "$bad"
}

# ---- read: one awk pass emits FILE<TAB>LINE<TAB>TEXT for each candidate line, continuations joined
records="$(awk '
    function flush() { if (pend) { print FILENAME_P "\t" start "\t" buf; pend = 0 } }
    FNR == 1 { flush() }
    {
        line = $0; sub(/\r$/, "", line)
        if (pend) {
            if (line ~ /\\$/) { sub(/\\$/, "", line); buf = buf " " line; next }
            buf = buf " " line; flush(); next
        }
        if (line ~ /(^|[^A-Za-z0-9_.-])rm[ \t]+-/) {
            if (line ~ /\\$/) { sub(/\\$/, "", line); buf = line; start = FNR; FILENAME_P = FILENAME; pend = 1; next }
            print FILENAME "\t" FNR "\t" line
        }
    }
    END { flush() }
' "${files[@]}")" || die "awk could not read the files."

unguarded=0
while IFS=$'\t' read -r f ln text; do
    [ -n "$f" ] || continue
    if ! check_text "$text"; then
        unguarded=$((unguarded + 1))
        trimmed="${text#"${text%%[![:space:]]*}"}"
        echo "UNGUARDED: $f:$ln: $trimmed"
    fi
done <<< "$records"

for f in ${skipped[@]+"${skipped[@]}"}; do
    echo "not read: $f (a frozen copy of a shipped release; see the header)"
done
if [ "$unguarded" -gt 0 ]; then
    echo
    echo "Write the first expansion of each path as \${NAME:?}, for example \"\${T:?}/tmp\" rather than \"\$T/tmp\", so an"
    echo "empty value stops the script instead of deleting from the root or the shared temp folder (the 2026-11-08 temp-folder incident)."
    echo "A line that cannot be written that way carries '# rm-guard-exempt: <reason>' on the same line."
    echo "FAILED: $unguarded unguarded line(s); $VARRMS recursive deletes of variable paths ($EXEMPT exempt) across ${#files[@]} shell files."
    exit 1
fi
echo "OK: $VARRMS recursive deletes of variable paths, all guarded ($EXEMPT exempt), across ${#files[@]} shell files."
