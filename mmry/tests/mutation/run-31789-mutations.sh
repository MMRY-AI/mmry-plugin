#!/usr/bin/env bash
# run-31789-mutations.sh - does each #31789 check bite?
#
# For each mutation: copy the checkout (the plugin AND the customer page and README beside it, which
# the documentation checks read) to a scratch directory, break one thing #31789 built, run the suite
# that is supposed to notice, and report REFUSED (the suite failed, as it must) or SURVIVED (nothing
# noticed). A mutation whose text is not found aborts the run rather than scoring a no-op. The
# untouched copy must pass every suite first.
#
# usage: bash mmry/tests/mutation/run-31789-mutations.sh [name ...]     exit 0 only if every one REFUSED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_SRC="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="${TMPDIR:-/tmp}/mmry-31789-mut-$$"
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

SERVER="mmry/hooks-handlers/mcp-server.sh"
LIB="mmry/hooks-handlers/lib-host.sh"
S_MCP="handlers/mcp-server.bats"
S_LEAD="handlers/codex-formation-lead.bats"
S_DOCS="structural/codex-formation-lead-docs.bats"
S_OUT="handlers/codex-tools-first-output.bats"
S_TF="structural/codex-tools-first.bats"

# Replace the first occurrence of $2 with $3 in file $1; fail if $2 is not there.
_rep() {
    local t; t="$(cat "$1"; printf x)"; t="${t%x}"
    [[ "$t" == *"$2"* ]] || return 1
    printf '%s' "${t/"$2"/"$3"}" > "$1"
}

declare -a NAMES=() OLDS=() NEWS=() DESCS=() FILES=() SUITES=()
# add <name> <description> <file> <suite> <old text> <new text>
add() { NAMES+=("$1"); DESCS+=("$2"); FILES+=("$3"); SUITES+=("$4"); OLDS+=("$5"); NEWS+=("$6"); }

# ---- the tool server ----------------------------------------------------------------------------
add sid-guard-lead "the lead's tools run with no conversation id" "$SERVER" "$S_MCP" \
    'if [[ "$name" == formation_* || "$name" == memory_load ]] && [[ -z "$MMRY_SID" ]]; then' \
    'if [[ ( "$name" == formation_* && "$name" != formation_start && "$name" != formation_assign && "$name" != formation_report && "$name" != formation_debrief ) || "$name" == memory_load ]] && [[ -z "$MMRY_SID" ]]; then'
add no-sh-quote "arguments reach the handler unquoted" "$SERVER" "$S_MCP" \
    'MMRY_ARGV=(\($argv | @sh))' 'MMRY_ARGV=(\($argv | join(" ")))'
add debrief-not-destructive "closing out is annotated as harmless, so Codex never asks" "$SERVER" "$S_MCP" \
    '"title": "Close out the coordination group", "readOnlyHint": false, "destructiveHint": true' \
    '"title": "Close out the coordination group", "readOnlyHint": false, "destructiveHint": false'
add report-not-readonly "reading the record is annotated as a change" "$SERVER" "$S_MCP" \
    '"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
  },
  {
    "name": "formation_debrief",' \
    '"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
  },
  {
    "name": "formation_debrief",'
add assign-args-swapped "assign hands the handler its arguments in the wrong order" "$SERVER" "$S_MCP" \
    '["formation-assign.sh", (int("member_id") | need("member_id")), $work]' \
    '["formation-assign.sh", $work, (int("member_id") | need("member_id"))]'
add assign-role-unchecked "assign accepts any role" "$SERVER" "$S_MCP" \
    'if $role != "" and ($role | IN("Lead","Wingman") | not) then error("role must be Lead or Wingman")' \
    'if false then error("role must be Lead or Wingman")'
add start-task-dropped "start drops the task id" "$SERVER" "$S_MCP" \
    '["formation-start.sh", (str("objective") | need("objective"))] + (if int("task_id") == null then [] else [int("task_id")] end)' \
    '["formation-start.sh", (str("objective") | need("objective"))]'

# ---- what Codex messages name ---------------------------------------------------------------------
add tool-ref-allowlist "the lead's tools are not recognised as tools, so messages name scripts" "$LIB" "$S_OUT" \
    '        formation_start|formation_assign|formation_report|formation_debrief) ;;' ''
add start-ref-script "start is referred to as its script on Codex" "$LIB" "$S_OUT" \
    '        start)
            if (( $# == 0 )); then
                mmry_host_tool_ref formation_start' \
    '        start-off)
            if (( $# == 0 )); then
                mmry_host_tool_ref formation_start'
add access-hint-lead "the sandbox-access hint stops naming the lead's operations in words" "$LIB" "$S_OUT" \
    '        echo "formation start, join, say, assign, progress report, roster, report, debrief or leave,"' \
    '        echo "formation join, say, progress report, roster or leave,"'
# Round 1 found access-hint-lead SURVIVED: nothing pinned the hint's list. The pin added for it is
# also checked against the tool names themselves being dropped.
add access-hint-tools "the sandbox-access hint stops naming the lead's tools" "$LIB" "$S_OUT" \
    '        echo "formation_start, formation_join, formation_say, formation_assign, formation_progress,"
        echo "formation_roster, formation_report, formation_debrief, formation_leave), which needs"' \
    '        echo "formation_join, formation_say, formation_progress,"
        echo "formation_roster, formation_leave), which needs"'

# ---- the lead notice (R0, R3) ---------------------------------------------------------------------
add no-start-notice "the Codex start confirmation says nothing about the lead limit" "$LIB" "$S_LEAD" \
    '            printf '"'"'%s\n'"'"' "Tell the customer' \
    '            return 1; printf '"'"'%s\n'"'"' "Tell the customer'
add notice-ungated "the lead notice is printed on Claude Code too" "$LIB" "$S_LEAD" \
    '    [[ "$_MMRY_HOST_V" == "codex" ]] || return 1
    case "$1" in
        start)' \
    '    case "$1" in
        start)'
add no-recommendation "the start notice stops recommending a Claude Code lead" "$LIB" "$S_LEAD" \
    'rec="Codex is fine for joining a formation, but we recommend it does not lead one: start the formation from a Claude Code session, which hears its members while idle, and join it from here."' \
    'rec="Codex is fine for joining a formation."'
add no-assign-notice "the Codex assign confirmation says nothing about the next action" "mmry/hooks-handlers/formation-assign.sh" "$S_LEAD" \
    '    mmry_host_lead_notice assign || true' '    :'

# ---- the documentation (R0, R4) --------------------------------------------------------------------
add docs-claim-list "the Codex page claims listing formations" "docs/codex.md" "$S_DOCS" \
    'Start a formation and share its id,' 'List formations, start a formation and share its id,'
add docs-drop-debrief "the Codex page stops claiming the debrief" "docs/codex.md" "$S_DOCS" \
    'close the formation out with a debrief, and leave.' 'and leave.'
add docs-all-of-them "the Codex page claims every formation operation again" "docs/codex.md" "$S_DOCS" \
    '- **Formations work, for the operations tested on Codex.**' '- **Formations work, all of them.** Every formation operation works.'
add docs-no-recommend "the Codex page stops recommending a Claude Code lead" "docs/codex.md" "$S_DOCS" \
    '**This is why we recommend you lead a formation from Claude Code.** ' ''
add skill-no-lead-section "the skill loses its lead section" "mmry/skills-codex/memory-system/SKILL.md" "$S_DOCS" \
    '### Leading a formation on Codex' '### Coordinating on Codex'
add skill-start-script "the skill sends the model to the start script again" "mmry/skills-codex/memory-system/SKILL.md" "$S_TF" \
    'bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-list.sh"' \
    'bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-list.sh"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-start.sh" "Ship the v2 checkout"'

# Round 2 (#31789 QA round 1): the skill and both READMEs are held to the proven set too. The first
# restores the exact passage QA failed.
add skill-old-passage "the skill again tells the model every operation, list and claim included, is available" "mmry/skills-codex/memory-system/SKILL.md" "$S_DOCS" \
    'The formation operations tested on Codex are: start, join, say (to the formation or to one member),
assign, progress, roster, report, debrief and leave, all as tools. Do not tell a customer any of
them is unavailable. Listing the formations and claiming an area have not been tested from Codex
yet: never tell a customer they are proven here, and if you run one of their scripts, say it has
not been tested on Codex. Do tell' \
    'Every formation operation is available here: start, join, say, assign, progress, roster, report,
debrief and leave as tools, and list and claim as scripts. Do not tell a customer any of them is
unavailable. Do tell'
add skill-claims-list "the skill's tested sentence adds listing" "mmry/skills-codex/memory-system/SKILL.md" "$S_DOCS" \
    'debrief and leave, all as tools.' 'debrief, list and leave, all as tools.'
add skill-drops-broadcast "the skill's tested sentence stops claiming a message to the formation" "mmry/skills-codex/memory-system/SKILL.md" "$S_DOCS" \
    'say (to the formation or to one member),' 'say,'
add skill-scripts-untold "the skill's script section stops saying listing and claiming are untested" "mmry/skills-codex/memory-system/SKILL.md" "$S_DOCS" \
    'Listing the active formations and claiming an area have no tool, and neither has been tested
from Codex yet. If a customer asks for one, run it and tell them it has not been tested on Codex:' \
    'Listing the active formations and claiming an area have no tool:'
add readme-every-op "the repository README claims every formation operation on Codex" "README.md" "$S_DOCS" \
    '| Coordination-group messages delivered as you work | yes | yes |' \
    '| Coordination-group messages delivered as you work | yes | yes |
| Every formation operation, including listing and claiming | yes | yes |'
add plugin-readme-claims "the plugin README claims listing and claiming formations on Codex" "mmry/README.md" "$S_DOCS" \
    'the Foundation memories restated each prompt and coordination-group messages all work;' \
    'the Foundation memories restated each prompt, coordination-group messages, and listing and claiming in a formation all work;'

# Round 3 (#31789 QA round 2): live, the lead's reply after formation_assign dropped the next-action
# line. The skill now tells the model to relay it, and the tool labels it for the customer.
add skill-no-relay "the skill stops telling the model to relay the next-action line after start and assign" "mmry/skills-codex/memory-system/SKILL.md" "$S_DOCS" \
    '**Relay the next-action line to the customer, in your own reply, after every `formation_start` and
every `formation_assign`.** Both results include a line that begins "Tell the customer this in
your reply". It is for the customer, not for you: never leave it out, even when the rest of your
reply is a one-line confirmation. After `formation_assign`, tell the customer that the member'"'"'s
report arrives when they next send a message here, not on its own, and to check in then. For
example: "Member 7 has the checkout tests. Their report reaches me only when you next send a
message here, so check in with me once they have had time to work." After `formation_start`, give
the id, say the same of every member, and give the recommendation above.' ''
add skill-relay-start-only "the skill's relay instruction covers start but not assign" "mmry/skills-codex/memory-system/SKILL.md" "$S_DOCS" \
    'after every `formation_start` and
every `formation_assign`.**' 'after every `formation_start`.**'
add assign-unlabelled "the assign line is no longer labelled for the customer" "$LIB" "$S_LEAD" \
    '"Tell the customer this in your reply, every time you assign work, in words like these: \"' '"\"'
add assign-notice-last "the assign line goes back to being the last line" "mmry/hooks-handlers/formation-assign.sh" "$S_LEAD" \
    'if declare -F mmry_host_lead_notice >/dev/null 2>&1; then
    mmry_host_lead_notice assign || true
fi
printf '"'"'They will see it after their next tool call, marked as directed at them. No other member was told.\n'"'"'' \
    'printf '"'"'They will see it after their next tool call, marked as directed at them. No other member was told.\n'"'"'
if declare -F mmry_host_lead_notice >/dev/null 2>&1; then
    mmry_host_lead_notice assign || true
fi'

run_suite() { ( cd "$1/mmry/tests" && ./libs/bats-core/bin/bats "$3" ) > "$2" 2>&1; }

copy() {
    rm -rf "$1"; mkdir -p "$1"
    ( cd "$REPO_SRC" && tar cf - --exclude=.git . ) | ( cd "$1" && tar xf - )
}

want=("$@")
selected() {
    (( ${#want[@]} )) || return 0
    local w; for w in "${want[@]}"; do [[ "$w" == "$1" ]] && return 0; done
    return 1
}

echo "baseline: the untouched copy, every suite a mutation uses"
copy "$WORK/base"
for s in $(printf '%s\n' "${SUITES[@]}" | sort -u); do
    if ! run_suite "$WORK/base" "$WORK/base.out" "$s"; then
        echo "BASELINE FAILED in $s; nothing can be scored"; grep '^not ok' "$WORK/base.out"; exit 2
    fi
    echo "baseline $s: $(grep -c '^ok' "$WORK/base.out") passed"
done

refused=0; survived=0
for i in "${!NAMES[@]}"; do
    n="${NAMES[$i]}"
    selected "$n" || continue
    copy "$WORK/m"
    if ! _rep "$WORK/m/${FILES[$i]}" "${OLDS[$i]}" "${NEWS[$i]}"; then
        echo "ABORT: mutation $n found nothing to change in ${FILES[$i]}"; exit 3
    fi
    if run_suite "$WORK/m" "$WORK/m.out" "${SUITES[$i]}"; then
        echo "SURVIVED  $n: ${DESCS[$i]}"; survived=$(( survived + 1 ))
    else
        echo "REFUSED   $n: ${DESCS[$i]} -- ${SUITES[$i]}: $(grep '^not ok' "$WORK/m.out" | sed 's/^not ok [0-9]* //' | head -3 | paste -sd'|' -)"
        refused=$(( refused + 1 ))
    fi
done
echo "RESULT: $refused refused, $survived survived"
(( survived == 0 ))
