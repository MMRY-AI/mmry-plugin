#!/usr/bin/env bats
# Each formation member is given a rule for its role, and a finished member asks for more work
# (#32683).
#
# WHY THIS FILE EXISTS. In the Magento 1.11.1 Formation a member reported "Idle until..." and
# waited, while the lead worked alone until the person reminded it that members were free. The
# report-to-lead rule (#31744) made members report. Nothing told the lead to answer, and nothing
# told a finished member to ask for more.
#
# WHAT IS PINNED, by the ticket's own test cases:
#   req2  this session's own Done prints the offer line; Accepted, Blocked and Abandoned do not, and
#         neither does a lead recording another member's Done, or a lead's own Done.
#   req3  joining prints the joiner's own role rule after the two standing rules, on Claude Code and
#         on Codex: a member gets the member rule, a returning lead the lead rule, never both.
#         Starting a formation prints the lead rule.
#   req4  one text on every surface: the literals here, the plugin's lib-formation-roles.sh, the
#         command page, the Codex skill, and, given MMRY_SERVICE_REPO, the service's
#         FormationRoleRule.cs and the newest migration that writes each notice.
#
# The report-to-lead rules are pinned by formation-report-rule.bats, which this task does not edit.

# THE RULES, as one literal each. If a surface drifts from these, the surface is wrong.
# #33205, #34521 (DD-202 in MMRY-AI/mmry): cmo-mmry's approved lead rule, item 1 revision 1
# (wording-33205-34521-cmo-approved.md), byte for byte: keep every member working, hand work out with
# assign, check five places before saying there is none, and say so only with the reason.
LEAD_RULE="As the lead, keep every member working. Hand each new piece of work to a member with assign, so MMRY AI knows what it is doing; the brief can still go as a message or a file. When a member is idle or reports Done, give it its next job now. Before deciding there is none, check five places: open quality gaps on work in flight, follow-ups promised to the person, preparation for the next stage, records that do not match what was built, and a hand-back from another member waiting for review. Say there is no work only with the reason, naming what everything is waiting on. Do not do work yourself that an idle member could take; keep the coordinating, the deciding and the reviewing for yourself."
# The rule 2.19 and earlier gave. No copy may still carry it.
OLD_LEAD_RULE="As the lead, delegate and check in: when a member is idle or reports Done, give it the next piece of work or tell it there is none, and do not do work yourself that an idle member could take. Keep for yourself the coordinating, the deciding and the reviewing."
# #34521 requirement 2: the five places, each a phrase of the rule, checked one by one in every copy.
FIVE_CHECKS=(
    "open quality gaps on work in flight"
    "follow-ups promised to the person"
    "preparation for the next stage"
    "records that do not match what was built"
    "a hand-back from another member waiting for review"
)
# #33205, #34521: cmo-mmry's approved item 2, the line the service adds after the offer in the lead's
# PROGRESS notice for a member's own Done. The plugin prints it as the service sends it; this pins the
# service's copies equal to the approved text.
NEXT="Give this member its next job in this turn, with assign. If there is truly none, say why, naming what everything is waiting on."
MEMBER_RULE="As a member, never go idle silently: when you finish, report Done to the lead and end the report by asking whether there is anything else you can do, then keep listening for the answer."
OFFER="Is there anything else I can do?"
OFFER_SENT="Your report to the lead ends with: Is there anything else I can do? Keep listening for the answer."

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    PLUGIN_DIR="${BATS_TEST_DIRNAME}/../.."
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_CODE_SESSION_ID="bats-role-rules-$$"
    export CLAUDE_SESSION_ID="$CLAUDE_CODE_SESSION_ID"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    CODEX_DIR="${BATS_TEST_TMPDIR}/codexhome"
    mkdir -p "${CODEX_DIR}/mmry"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
}

# A fake transport that answers the progress write (and the formation create) with FAKE_BODY and
# every other call with FAKE_BODY_GET, as formation-save-outcome.bats does.
_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""; method="GET"
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$prev" == "-X" ]] && method="$arg"
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
body="${FAKE_BODY:-}"
code="${FAKE_CODE:-200}"
if [[ "$url" != *"/progress"* && "$url" != *"/members"* && ! ( "$method" == "POST" && "$url" == */api/formations ) ]]; then
    body="${FAKE_BODY_GET:-$body}"
    code="${FAKE_CODE_GET:-200}"
fi
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# Run a handler on the given host ("claude" or "codex") with the fake transport.
_on() {
    local host="$1"; shift
    local bin; bin="$(_fake_curl_dir)"
    if [[ "$host" == "codex" ]]; then
        PATH="${bin}:${PATH}" MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "$@"
    else
        PATH="${bin}:${PATH}" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run env -u MMRY_HOST bash "$@"
    fi
}

# The join answer, with this session's own row carrying role $1 (and, for a return, returnedDate).
_join_body() {
    local role="$1" returned="${2:-null}"
    printf '{"formation":{"id":4242,"objective":"TEST DATA 32683"},"members":[{"id":3,"sessionId":null,"role":"Lead","leftDate":null},{"id":9,"sessionId":"%s","role":"%s","displayName":"Role test","leftDate":null,"returnedDate":%s}]}' \
        "$CLAUDE_CODE_SESSION_ID" "$role" "$returned"
}

_join() {
    local host="$1" role="$2" returned="${3:-null}"
    export FAKE_CODE=200 FAKE_BODY; FAKE_BODY="$(_join_body "$role" "$returned")"
    export FAKE_BODY_GET="$FAKE_BODY"
    _on "$host" "${HANDLERS}/formation-join.sh" 4242
}

# One line of output, exactly, with any CR removed.
_has_line() {
    local want="$1" line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "$line" == "$want" ]] && return 0
    done <<< "$output"
    echo "expected this exact line in the output:"
    echo "  $want"
    echo "output was:"
    echo "$output"
    return 1
}

_lacks() {
    [[ "$output" != *"$1"* ]] || { echo "unexpected in output: $1"; echo "$output"; return 1; }
}

# The roster with THIS session as member 7 (role $1) and somebody else as member 3.
_roster_body() {
    local role="${1:-Wingman}"
    printf '{"formation":{"id":42,"objective":"o"},"members":[{"id":3,"sessionId":"somebody-else","role":"Lead","progress":"Accepted","leftDate":null},{"id":7,"sessionId":"%s","role":"%s","progress":"Accepted","leftDate":null}]}' "$CLAUDE_CODE_SESSION_ID" "$role"
}

# The entry the server reads back: member $1, session $2, state $3, role $4.
_entry_body() {
    printf '{"id":%s,"sessionId":"%s","userId":3,"email":"a@b.c","userIsActive":true,"role":"%s","assignment":"the validator","progress":"%s","progressUpdatedDate":"2026-10-23T13:00:00","joinedDate":"2026-10-23T12:00:00","leftDate":null}' "$1" "$2" "${4:-Wingman}" "$3"
}

# Report $2 for this session on host $1 (this session's role $3).
_progress() {
    local host="$1" state="$2" role="${3:-Wingman}"
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_CODE_SESSION_ID"
    export FAKE_CODE=200 FAKE_BODY_GET; FAKE_BODY_GET="$(_roster_body "$role")"
    export FAKE_BODY; FAKE_BODY="$(_entry_body 7 "$CLAUDE_CODE_SESSION_ID" "$state" "$role")"
    _on "$host" "${HANDLERS}/formation-progress.sh" "$state"
}

# ---- The literals ------------------------------------------------------------------------------

@test "literals: ASCII only and no apostrophes, so a T-SQL N'' literal holds them unescaped" {
    local s
    for s in "$LEAD_RULE" "$MEMBER_RULE" "$OFFER" "$OFFER_SENT" "$NEXT"; do
        [[ "$s" != *"'"* ]] || { echo "apostrophe in: $s"; return 1; }
        ! printf '%s' "$s" | LC_ALL=C grep -q '[^ -~]' || { echo "non-ASCII in: $s"; return 1; }
    done
}

@test "literals: lib-formation-roles.sh holds all four byte for byte" {
    local lib="${HANDLERS}/lib-formation-roles.sh"
    grep -q -F -- "MMRY_FORMATION_LEAD_RULE=\"${LEAD_RULE}\"" "$lib"
    grep -q -F -- "MMRY_FORMATION_MEMBER_RULE=\"${MEMBER_RULE}\"" "$lib"
    grep -q -F -- "MMRY_FORMATION_OFFER=\"${OFFER}\"" "$lib"
    # The sent line is composed from the offer, so the offer is said once.
    run bash -c 'source "$1"; printf "%s" "$MMRY_FORMATION_OFFER_SENT"' _ "$lib"
    [ "$status" -eq 0 ]
    [ "$output" = "$OFFER_SENT" ]
}

# #33847: the roster's availability footer, which tells the lead whom to hand work to, is held once,
# in lib-formation-prompts.sh, ASCII, and the roster and status scripts both read it from there.
AVAIL_FOOTER='Availability is based on the activity MMRY AI has recorded for each member in this Formation. No recent activity means the member holds no work and has shown no activity for the quiet limit; MMRY AI cannot tell why.'

@test "33847 literals: lib-formation-prompts.sh holds the availability footer and label once; no script spells them" {
    local lib="${HANDLERS}/lib-formation-prompts.sh"
    run bash -c 'source "$1"; printf "%s" "$MMRY_FORMATION_AVAILABILITY_FOOTER"' _ "$lib"
    [ "$status" -eq 0 ]
    [ "$output" = "$AVAIL_FOOTER" ]
    ! printf '%s' "$AVAIL_FOOTER" | LC_ALL=C grep -q '[^ -~]' || { echo "non-ASCII footer"; return 1; }
    [ "$(grep -c -F -- 'Availability is based on' "$lib")" -eq 1 ]
    [ "$(grep -c -F -- '"  Availability: "' "$lib")" -eq 1 ]
    local f
    for f in "${HANDLERS}/formation-roster.sh" "${HANDLERS}/formation-status.sh"; do
        grep -q -F 'lib-formation-prompts.sh' "$f" || { echo "$f does not read the held text"; return 1; }
        ! grep -q -F -- 'Availability is based on' "$f" || { echo "$f spells the footer itself"; return 1; }
        ! grep -q -F -- 'Availability: ' "$f" || { echo "$f spells the label itself"; return 1; }
    done
}

# ---- Requirement 3: join and start --------------------------------------------------------------

@test "req3: a member joining on Claude Code is given the member rule and not the lead rule" {
    _join claude Wingman
    [ "$status" -eq 0 ]
    _has_line "$MEMBER_RULE"
    _lacks "$LEAD_RULE"
}

@test "req3: a member joining on Codex is given the member rule and not the lead rule" {
    _join codex Wingman
    [ "$status" -eq 0 ]
    _has_line "$MEMBER_RULE"
    _lacks "$LEAD_RULE"
}

@test "req3: a lead returning to its seat on Claude Code is given the lead rule and not the member rule" {
    _join claude Lead '"2026-10-23T12:30:00"'
    [ "$status" -eq 0 ]
    _has_line "$LEAD_RULE"
    _lacks "$MEMBER_RULE"
}

@test "req3: a lead returning to its seat on Codex is given the lead rule and not the member rule" {
    _join codex Lead '"2026-10-23T12:30:00"'
    [ "$status" -eq 0 ]
    _has_line "$LEAD_RULE"
    _lacks "$MEMBER_RULE"
}

@test "req3: a join whose own row cannot be found gets the member rule; a join never makes a new lead" {
    export FAKE_CODE=200 FAKE_BODY='{"formation":{"id":4242,"objective":"o"},"members":[]}'
    export FAKE_BODY_GET="$FAKE_BODY"
    _on claude "${HANDLERS}/formation-join.sh" 4242
    [ "$status" -eq 0 ]
    _has_line "$MEMBER_RULE"
    _lacks "$LEAD_RULE"
}

@test "req3: the role rule comes after the two standing rules, which are unchanged" {
    _join claude Wingman
    local out; out="$(printf '%s\n' "$output" | tr -d '\r')"
    local ack_at rule_at
    ack_at="$(printf '%s\n' "$out" | grep -n '^When you receive an assignment' | cut -d: -f1)"
    rule_at="$(printf '%s\n' "$out" | grep -n -F -x -- "$MEMBER_RULE" | cut -d: -f1)"
    [ -n "$ack_at" ] && [ -n "$rule_at" ] && [ "$ack_at" -lt "$rule_at" ] || { echo "$out"; return 1; }
    printf '%s\n' "$out" | grep -q '^Report to the lead at every stopping point'
}

@test "req3 control: a refused join prints no role rule" {
    export FAKE_CODE=403 FAKE_BODY='{}' FAKE_CODE_GET=403 FAKE_BODY_GET='{}'
    _on claude "${HANDLERS}/formation-join.sh" 4242
    [ "$status" -ne 0 ]
    _lacks "$MEMBER_RULE"
    _lacks "$LEAD_RULE"
}

@test "req3: starting a formation gives the lead rule and not the member rule, on Claude Code and Codex" {
    export FAKE_CODE=201 FAKE_BODY='{"id":42,"objective":"migrate the billing schema"}'
    export FAKE_BODY_GET='' FAKE_CODE_GET=201
    _on claude "${HANDLERS}/formation-start.sh" "migrate the billing schema"
    [ "$status" -eq 0 ]
    _has_line "$LEAD_RULE"
    _lacks "$MEMBER_RULE"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
    _on codex "${HANDLERS}/formation-start.sh" "migrate the billing schema"
    [ "$status" -eq 0 ]
    _has_line "$LEAD_RULE"
    _lacks "$MEMBER_RULE"
}

@test "req4: the role rule lines are byte-identical on Claude Code and Codex" {
    _join claude Wingman
    local cc; cc="$(printf '%s' "$output" | tr -d '\r' | grep -E '^As (the lead|a member),')"
    _join codex Wingman
    local cx; cx="$(printf '%s' "$output" | tr -d '\r' | grep -E '^As (the lead|a member),')"
    [ -n "$cc" ]
    [ "$cc" = "$cx" ]
}

# ---- Requirement 2: the Done report asks for more work -----------------------------------------

@test "req2: a member reporting its own Done on Claude Code is told its report asks for more work" {
    _progress claude Done
    [ "$status" -eq 0 ]
    _has_line "$OFFER_SENT"
}

@test "req2: and on Codex" {
    _progress codex Done
    [ "$status" -eq 0 ]
    _has_line "$OFFER_SENT"
}

@test "req2: Accepted, Blocked and Abandoned carry no offer" {
    local s
    for s in Accepted Blocked Abandoned; do
        _progress claude "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"recorded as ${s}"* ]] || { echo "$s control: $output"; return 1; }
        _lacks "$OFFER"
    done
}

@test "req2: a lead recording Done for ANOTHER member is not told it asked for more work" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_CODE_SESSION_ID"
    export FAKE_CODE=200 FAKE_BODY_GET; FAKE_BODY_GET="$(_roster_body Lead)"
    export FAKE_BODY; FAKE_BODY="$(_entry_body 3 "somebody-else" Done Wingman)"
    _on claude "${HANDLERS}/formation-progress.sh" 3 Done
    [ "$status" -eq 0 ]
    [[ "$output" == *"Member 3 in formation 42 is now recorded as Done"* ]] || { echo "$output"; return 1; }
    _lacks "$OFFER"
}

@test "req2: a lead reporting its own Done has nobody to ask, so no offer" {
    _progress claude Done Lead
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded as Done"* ]] || { echo "$output"; return 1; }
    _lacks "$OFFER"
}

# ---- Requirement 4: one text on every surface ---------------------------------------------------

@test "req4: the command page and the Codex skill carry both role rules byte for byte" {
    grep -q -F -- "> ${LEAD_RULE}" "${PLUGIN_DIR}/commands/formation.md"
    grep -q -F -- "> ${MEMBER_RULE}" "${PLUGIN_DIR}/commands/formation.md"
    grep -q -F -- "> ${LEAD_RULE}" "${PLUGIN_DIR}/skills-codex/memory-system/SKILL.md"
    grep -q -F -- "> ${MEMBER_RULE}" "${PLUGIN_DIR}/skills-codex/memory-system/SKILL.md"
}

# The newest sql/lib/MigrationNNN.ps1 whose text creates procedure $1.
_newest_migration_for() {
    local proc="$1" f found=""
    for f in "${MMRY_SERVICE_REPO}"/sql/lib/Migration[0-9][0-9][0-9].ps1; do
        [[ -f "$f" ]] || continue
        grep -q -F -- "PROCEDURE [dbo].[${proc}]" "$f" && found="$f"
    done
    printf '%s' "$found"
}

@test "req4: the service holds the same three literals (FormationRoleRule.cs and the newest migration)" {
    if [[ -z "${MMRY_SERVICE_REPO:-}" ]]; then
        skip "MMRY_SERVICE_REPO is not set; set it to a checkout of MMRY-AI/mmry to compare the service"
    fi
    local cs="${MMRY_SERVICE_REPO}/src/Mnemo.Api/Services/FormationRoleRule.cs"
    [ -f "$cs" ]
    grep -q -F -- "\"${LEAD_RULE}\"" "$cs"
    grep -q -F -- "\"${MEMBER_RULE}\"" "$cs"
    grep -q -F -- "\"${OFFER}\"" "$cs"
    grep -q -F -- "\"Your report to the lead ends with: \" + Offer + \" Keep listening for the answer.\"" "$cs"

    local assign progress
    assign="$(_newest_migration_for usp_Mnemo_UpdateFormationMember)"
    progress="$(_newest_migration_for usp_Mnemo_UpdateFormationMemberProgress)"
    if grep -q -F -- "N'${LEAD_RULE}'" "$assign" 2>/dev/null; then
        # The assignment notice: each role's rule, by the role the notice gives.
        grep -q -F -- "N'${MEMBER_RULE}'" "$assign"
        [ -n "$progress" ]
        grep -q -F -- "N'  offer:      ${OFFER}'" "$progress"
    else
        # Until the migration that writes the notices exists, its edit list is the service's copy.
        local edits="${MMRY_SERVICE_REPO}/sql/lib/Migration080Edits.ps1"
        [ -f "$edits" ] || { echo "neither the newest migration ($assign) nor Migration080Edits.ps1 holds the rules"; return 1; }
        echo "# compared against Migration080Edits.ps1: no migration writes the role rules yet" >&3
        grep -q -F -- "'${LEAD_RULE}'" "$edits"
        grep -q -F -- "'${MEMBER_RULE}'" "$edits"
        grep -q -F -- "'${OFFER}'" "$edits"
        grep -q -F -- "  offer:      " "$edits"
    fi
}

# ---- #33205 and #34521 (DD-202 in MMRY-AI/mmry): keep every member working --------------------------
#
# T1 (33205 requirement 1): the lead rule given at start and on join names assign, on Claude Code and
#    Codex, and every copy is the approved text. T3 (34521 requirement 2): each of the five places to
#    look before saying there is none is in every copy, checked one by one, so a copy that drops one
#    is named. The service copies are compared when MMRY_SERVICE_REPO is set, as req4 above does.

# Every plugin copy of the lead rule, one per line as "label|text". The library is read the way the
# scripts read it (sourced), the pages by their quoted line.
_plugin_lead_rule_copies() {
    local lib="${HANDLERS}/lib-formation-roles.sh" f line
    printf 'lib-formation-roles.sh|%s\n' "$(bash -c 'source "$1"; mmry_formation_role_rule Lead' _ "$lib")"
    for f in "${PLUGIN_DIR}/commands/formation.md" "${PLUGIN_DIR}/skills-codex/memory-system/SKILL.md"; do
        line="$(tr -d '\r' < "$f" | grep -E '^> As the lead,' || true)"
        printf '%s|%s\n' "${f#"${PLUGIN_DIR}/"}" "${line#> }"
    done
}

@test "33205 T1: the lead rule is the approved text and names assign, in every plugin copy" {
    [[ "$LEAD_RULE" == *"Hand each new piece of work to a member with assign"* ]] || return 1
    [[ "$LEAD_RULE" == *"the brief can still go as a message or a file"* ]] || return 1
    local copies label text n=0
    copies="$(_plugin_lead_rule_copies)"
    while IFS='|' read -r label text; do
        n=$((n + 1))
        [ "$text" = "$LEAD_RULE" ] || { echo "$label is not the approved lead rule:"; echo "  $text"; return 1; }
        [[ "$text" == *" with assign"* ]] || { echo "$label does not name assign"; return 1; }
    done <<< "$copies"
    [ "$n" -eq 3 ] || { echo "expected 3 plugin copies, read $n"; echo "$copies"; return 1; }
}

@test "33205 T1: starting a formation and a lead returning both print the approved rule, on Claude Code and Codex" {
    export FAKE_CODE=201 FAKE_BODY='{"id":42,"objective":"migrate the billing schema"}'
    export FAKE_BODY_GET='' FAKE_CODE_GET=201
    local host
    for host in claude codex; do
        bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
        _on "$host" "${HANDLERS}/formation-start.sh" "migrate the billing schema"
        [ "$status" -eq 0 ] || { echo "$host start: $output"; return 1; }
        _has_line "$LEAD_RULE"
    done
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
    for host in claude codex; do
        _join "$host" Lead '"2026-10-23T12:30:00"'
        [ "$status" -eq 0 ] || { echo "$host join: $output"; return 1; }
        _has_line "$LEAD_RULE"
    done
}

@test "34521 T3: each of the five places to look is in every plugin copy of the lead rule" {
    [ "${#FIVE_CHECKS[@]}" -eq 5 ]
    local copies label text check
    copies="$(_plugin_lead_rule_copies)"
    for check in "${FIVE_CHECKS[@]}"; do
        [[ "$LEAD_RULE" == *"$check"* ]] || { echo "the approved rule lacks: $check"; return 1; }
        while IFS='|' read -r label text; do
            [[ "$text" == *"$check"* ]] || { echo "$label lacks the check: $check"; return 1; }
        done <<< "$copies"
    done
    [[ "$LEAD_RULE" == *"Before deciding there is none, check five places: "* ]] || return 1
    [[ "$LEAD_RULE" == *"Say there is no work only with the reason, naming what everything is waiting on."* ]]
}

@test "33205 T1: no plugin file still carries the old lead rule or its 'tell it there is none'" {
    local hits
    hits="$(grep -r -l -F -e "give it the next piece of work or tell it there is none" -e "As the lead, delegate and check in" \
        "${PLUGIN_DIR}/hooks-handlers" "${PLUGIN_DIR}/commands" "${PLUGIN_DIR}/skills-codex" "${PLUGIN_DIR}/skills" 2>/dev/null || true)"
    [ -z "$hits" ] || { echo "still carries the old rule:"; echo "$hits"; return 1; }
    [ "$OLD_LEAD_RULE" != "$LEAD_RULE" ]
}

@test "33205 T1 and 34521 T3: the service holds the approved rule and each check in every copy, and the next: line" {
    if [[ -z "${MMRY_SERVICE_REPO:-}" ]]; then
        skip "MMRY_SERVICE_REPO is not set; set it to a checkout of MMRY-AI/mmry to compare the service"
    fi
    local cs="${MMRY_SERVICE_REPO}/src/Mnemo.Api/Services/FormationRoleRule.cs"
    local edits="${MMRY_SERVICE_REPO}/sql/lib/Migration104Edits.ps1"
    local assign progress
    assign="$(_newest_migration_for usp_Mnemo_UpdateFormationMember)"
    progress="$(_newest_migration_for usp_Mnemo_UpdateFormationMemberProgress)"
    [ -f "$cs" ] && [ -f "$edits" ] && [ -n "$assign" ] && [ -n "$progress" ] || { echo "service files missing: $cs $edits $assign $progress"; return 1; }

    # Each copy, as "label|the text it holds", cut out of the file by the form that copy is written in.
    local copies="" f line
    copies+="FormationRoleRule.cs|$(tr -d '\r' < "$cs" | grep -o -F -- "\"${LEAD_RULE}\"" | head -1)"$'\n'
    copies+="$(basename "$assign") literal|$(tr -d '\r' < "$assign" | grep -o -F -- "N'${LEAD_RULE}'" | head -1)"$'\n'
    copies+="Migration104Edits.ps1|$(tr -d '\r' < "$edits" | grep -o -F -- "'${LEAD_RULE}'" | head -1)"$'\n'
    for f in "${MMRY_SERVICE_REPO}/src/Mnemo.web/help.html" "${MMRY_SERVICE_REPO}/src/Mnemo.Api/wwwroot/help.html"; do
        line="$(tr -d '\r' < "$f" | grep -o -F -- "<p>${LEAD_RULE}</p>" | head -1)"
        copies+="${f#"${MMRY_SERVICE_REPO}/"}|${line}"$'\n'
    done
    local label text check
    while IFS='|' read -r label text; do
        [[ -n "$label" ]] || continue
        [ -n "$text" ] || { echo "$label does not hold the approved lead rule byte for byte"; return 1; }
        [[ "$text" == *" with assign"* ]] || { echo "$label does not name assign"; return 1; }
        for check in "${FIVE_CHECKS[@]}"; do
            [[ "$text" == *"$check"* ]] || { echo "$label lacks the check: $check"; return 1; }
        done
    done <<< "$copies"
    ! grep -q -F -- "$OLD_LEAD_RULE" "$cs" || { echo "FormationRoleRule.cs still holds the old rule"; return 1; }

    # The next: line after the offer, in the connector's constant and in the PROGRESS notice.
    grep -q -F -- "\"${NEXT}\"" "$cs" || { echo "FormationRoleRule.cs lacks the next line"; return 1; }
    grep -q -F -- "N'  next:       ${NEXT}'" "$progress" || { echo "$progress lacks the next: line"; return 1; }
}
