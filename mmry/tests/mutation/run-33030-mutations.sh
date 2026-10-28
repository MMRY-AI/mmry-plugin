#!/usr/bin/env bash
# run-33030-mutations.sh - do the live J-011 specs fail when the journey breaks? (#33030)
#
# The ticket's test case (c): with the plugin changed to deliver nothing, each live spec fails; with
# it changed to read another account's key, each live spec fails. For each spec this copies the
# plugin (the marketplace root: .claude-plugin and mmry, no .git) to a scratch directory, runs the
# spec against the untouched copy first (it must pass, or nothing can be scored), then against each
# mutated copy, and reports REFUSED (the spec failed, as it must) or SURVIVED (nothing noticed). A
# mutation whose text is not found aborts the run rather than scoring a no-op.
#
#   deliver-nothing  session-start.sh ends before it loads or hands over any memory (both hosts).
#   other-account    the client reads the OTHER product's config on this machine, which holds a
#                    second account's key: on Claude Code ~/.codex/mmry-config.json, on Codex
#                    ~/.claude/mmry-config.json (the #31245 defect). The spec planted that account's
#                    own Foundation memory, so a session handed it is caught by name.
#
# Needs what the specs need (see tests/helpers/live-journey.bash and the spec headers): the two
# account keys, and for the Codex spec MMRY_LIVE_CODEX_AUTH and a Codex CLI. Every run is a real
# session against the service, and every Codex run is a real Codex conversation.
#
# usage: bash mmry/tests/mutation/run-33030-mutations.sh [claude] [codex]   (default: both)
# exit 0 only if every baseline passed and every mutation REFUSED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_SRC="$(cd "$PLUGIN_SRC/.." && pwd)"
WORK="${TMPDIR:-/tmp}/mmry-33030-mut-$$"
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

_rep() {
    local t; t="$(cat "$1"; printf x)"; t="${t%x}"
    [[ "$t" == *"$2"* ]] || return 1
    printf '%s' "${t/"$2"/"$3"}" > "$1"
}

copy() {
    rm -rf "$1"; mkdir -p "$1"
    cp -R "$REPO_SRC/.claude-plugin" "$1/"
    cp -R "$PLUGIN_SRC" "$1/mmry"
}

run_spec() { ( cd "$1/mmry/tests" && PLUGIN_ROOT="$1/mmry" ./libs/bats-core/bin/bats "integration/$2" ) > "$3" 2>&1; }

declare -a SPECS=() NAMES=() DESCS=() FILES=() OLDS=() NEWS=()
# add <spec> <name> <description> <file> <old text> <new text>
add() { SPECS+=("$1"); NAMES+=("$2"); DESCS+=("$3"); FILES+=("$4"); OLDS+=("$5"); NEWS+=("$6"); }

for host in claude codex; do
    if [[ "$host" == "claude" ]]; then spec=session-start-live.bats; else spec=codex-session-live.bats; fi
    add "$spec" deliver-nothing "session-start.sh hands the session nothing" \
        hooks-handlers/session-start.sh 'MEM_FILE="${MMRY_TMPDIR}/mmry-memories.md"' 'exit 0'
done
add session-start-live.bats other-account "Claude Code reads the Codex config, another account's key" \
    hooks-handlers/mmry-client.sh 'config_file="${HOME}/.claude/mmry-config.json"' 'config_file="${HOME}/.codex/mmry-config.json"'
add codex-session-live.bats other-account "Codex reads the Claude Code config, another account's key" \
    hooks-handlers/lib-host.sh 'export MMRY_CONFIG_FILE="${_MMRY_HOST_DIR_V}/mmry-config.json"' 'export MMRY_CONFIG_FILE="${HOME}/.claude/mmry-config.json"'

want=("$@"); (( ${#want[@]} )) || want=(claude codex)
selected=()
for w in "${want[@]}"; do
    case "$w" in
        claude) selected+=(session-start-live.bats) ;;
        codex)  selected+=(codex-session-live.bats) ;;
        *) echo "usage: $0 [claude] [codex]" >&2; exit 2 ;;
    esac
done

refused=0; survived=0; bad=0
for spec in "${selected[@]}"; do
    echo "== ${spec}"
    copy "$WORK/base"
    if run_spec "$WORK/base" "$spec" "$WORK/base.out"; then
        echo "GREEN     baseline: untouched plugin, $(grep -c '^ok' "$WORK/base.out") of $(grep -c '^\(not \)\{0,1\}ok' "$WORK/base.out") checks pass"
        grep '^ok' "$WORK/base.out" | sed 's/^/          /'
    else
        echo "BASELINE FAILED for ${spec}; its mutations cannot be scored"
        grep -E '^(not ok|#)' "$WORK/base.out" | head -20 | sed 's/^/          /'
        bad=$(( bad + 1 )); continue
    fi
    for i in "${!NAMES[@]}"; do
        [[ "${SPECS[$i]}" == "$spec" ]] || continue
        copy "$WORK/m"
        if ! _rep "$WORK/m/mmry/${FILES[$i]}" "${OLDS[$i]}" "${NEWS[$i]}"; then
            echo "ABORT: mutation ${NAMES[$i]} found nothing to change in ${FILES[$i]}"; exit 3
        fi
        if run_spec "$WORK/m" "$spec" "$WORK/m.out"; then
            echo "SURVIVED  ${NAMES[$i]}: ${DESCS[$i]}"; survived=$(( survived + 1 ))
        else
            echo "RED       ${NAMES[$i]}: ${DESCS[$i]} -- $(grep -c '^not ok' "$WORK/m.out") of $(grep -c '^\(not \)\{0,1\}ok' "$WORK/m.out") checks fail"
            grep '^not ok' "$WORK/m.out" | sed 's/^/          /'
            refused=$(( refused + 1 ))
        fi
    done
done
echo "RESULT: ${refused} refused, ${survived} survived, ${bad} baseline failures"
(( survived == 0 && bad == 0 ))
