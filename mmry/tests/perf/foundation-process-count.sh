#!/usr/bin/env bash
# foundation-process-count.sh - processes and wall clock per prompt for the six Foundation parts
# (#31893). Windows only: counts with tests/helpers/count-processes.ps1, the job-object counter
# #31746 and #31844 used, so every process the OS creates for a prompt is counted, by any route.
#
# One "prompt" is a driver bash that starts the six registered commands together, each with its own
# copy of a UserPromptSubmit payload, and waits for all of them, as Claude Code does. The driver's
# own cost is measured the same way with six empty bash starts in place of the hook and subtracted,
# so the number reported is what the Foundation hooks themselves start, the six bash processes the
# host launches included.
#
# usage: bash tests/perf/foundation-process-count.sh <hook.sh> [prompts] [lines]
#   run from the plugin's mmry/ directory. <hook.sh> is the userpromptsubmit-foundation.sh to measure;
#   it must sit in a hooks-handlers/ directory with the files it sources. Defaults: 5 prompts,
#   600 lines (about 53 KB, six parts). Output: one line per prompt and a median.
#   MMRY_COUNT_VERIFY=1 also checks that the six parts rejoin into the set, whole and in order.
set -u
HOOK="${1:?usage: foundation-process-count.sh <hook.sh> [prompts] [lines]}"; RUNS="${2:-5}"; LINES="${3:-600}"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) echo "Windows only"; exit 2 ;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"
COUNTER="$(cygpath -w "$HERE/../helpers/count-processes.ps1")"
WINBASH="$(cygpath -w "$(command -v bash)")"
HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/.claude"
now_ms() { local s; s=$(date +%s%N); printf '%d' $(( s / 1000000 )); }

seed() { # a fresh temp dir with a sealed set of $LINES directives and a realistic config
    local d="$1" s b
    rm -rf "$d"; mkdir -p "$d"
    awk -v n="$LINES" 'BEGIN { for (i = 1; i <= n; i++) printf "- Directive %04d: keep every sentence short and every claim backed by something you ran.\n", i }' > "$d/body"
    read -r s b < <(cksum < "$d/body")
    { printf 'mmry-foundation v2 entries=%s bytes=%s cksum=%s\n' "$LINES" "$b" "$s"; cat "$d/body"; printf 'END OF FOUNDATION SET'; } > "$d/mmry-foundation-set.md"
    printf 'sess-count' > "$d/mmry-foundation.session"
    # A configured install: an API key, so part 1 takes its refresh-age path as a customer's does;
    # the set was just written, so no refresh actually starts. The URL is a discard port.
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"count-key","foundationReinject":"true"}' > "$d/mmry-config.json"
}

driver() { # $1 = command per part (k substituted), $2 = temp dir
    local d="$2"
    {
        printf 'export TMPDIR=%q MMRY_TMPDIR=%q HOME=%q MMRY_CONFIG_FILE=%q\n' "$d" "$d" "$W/home" "$d/mmry-config.json"
        printf 'p=%q\n' '{"session_id":"sess-count-1","transcript_path":"/x","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}'
        local k; for k in 1 2 3 4 5 6; do printf '%s\n' "printf '%s' \"\$p\" | ${1//@K@/$k} > \"$d/out.$k\" 2>/dev/null &"; done
        printf 'wait\n'
    } > "$d/driver.sh"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$COUNTER" -CommandLine "\"$WINBASH\" \"$(cygpath -w "$d/driver.sh")\"" < /dev/null | tr -d '\r'
}
num() { sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$1"; }
median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

verify() { # the six parts rejoin into the set, whole and in order
    local d="$1" k got="" ctx n=0 want
    for k in 1 2 3 4 5 6; do
        [[ -s "$d/out.$k" ]] || continue
        # A dot after the text, so the command substitution cannot drop a part's trailing newline.
        ctx="$(jq -j '(.hookSpecificOutput.additionalContext // "") + "."' "$d/out.$k" | tr -d '\r')" || return 1
        ctx="${ctx%.}"
        [[ "$ctx" == *"This is PART $k OF "* ]] || { echo "part $k unlabelled"; return 1; }
        got+="${ctx#*$'\n\n'}"; n=$(( n + 1 ))
    done
    want="$(cat "$d/body"; printf .)"; want="${want%.}"
    [[ "$got" == "${want%$'\n'}" ]] || { echo "the parts did not rejoin into the set ($n parts, ${#got} of ${#want} bytes)"; return 1; }
    echo "rejoined: $n parts, ${#got} bytes, in order"
}

base_all=""; hook_all=""; ms_all=""; first_all=""
i=1
while (( i <= RUNS )); do
    seed "$W/b"; rb="$(driver "bash -c 'exit 0'" "$W/b")"
    # The first prompt on a freshly written set, then the next prompt on the same set: the first is
    # the one a session pays once (and whenever the set changes), the next is every other prompt.
    seed "$W/h"; rf="$(driver "bash \"$HOOK\" --part @K@" "$W/h")"
    t0=$(now_ms); rh="$(driver "bash \"$HOOK\" --part @K@" "$W/h")"; t1=$(now_ms)
    nb=$(num "$rb"); nh=$(num "$rh"); nf=$(num "$rf")
    first_all+=" $(( nf - nb + 6 ))"
    line="prompt $i: first prompt on the set $(( nf - nb + 6 )) processes; next prompt $(( nh - nb + 6 )) processes (driver+hooks $nh, driver+6 empty bash $nb), ${rh##* }, $(( t1 - t0 )) ms"
    [[ "${MMRY_COUNT_VERIFY:-}" == 1 ]] && line="$line | $(verify "$W/h")"
    echo "$line"
    base_all+=" $nb"; hook_all+=" $(( nh - nb + 6 ))"; ms_all+=" $(( t1 - t0 ))"
    i=$(( i + 1 ))
done
echo "median processes started by the six Foundation hooks: first prompt on a set $(printf '%s\n' $first_all | median) (runs:$first_all); every next prompt $(printf '%s\n' $hook_all | median) (runs:$hook_all); median wall clock of a next prompt $(printf '%s\n' $ms_all | median) ms"
