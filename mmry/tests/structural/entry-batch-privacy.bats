#!/usr/bin/env bats
# entry-batch-privacy.bats - the skills that teach the batch entry save carry the connector's
# privacy instructions (#33317, QA r1 finding (b)3).
#
# WHY. The server holds a plugin batch to the same privacy question and visibility rules as the
# connector batch, but only if the assistant leaves the choice to the user. The connector's
# mmry_entry_save description (mmry src/Mnemo.Api/Mcp/AiDatabaseMcpTools.cs) tells the assistant
# three things: pass visibility only when the user has said who may see the entry, pass
# personal=true when the entry reads personal, and never choose for the user. An assistant taught
# from a skill without them may fill in visibility itself, which skips the question on both doors.
# Codex is also told to wait for the user's answer before sending the entry again. The
# /mmry:database batch path (commands/database.md, ### batch) is a third door and carries the same
# instructions (#33317, QA r2 finding (b)4).
#
# Structural on purpose: no network, no mock. Each assertion names the instruction it looks for,
# so removing any one of them turns this file red. Wrapped lines are joined before matching.

load '../helpers/test-helper'

CC_SKILL="skills/memory-system/SKILL.md"
CODEX_SKILL="skills-codex/memory-system/SKILL.md"
DB_COMMAND="commands/database.md"

# Print the section that starts with the heading $2 in file $1, up to the next ### or ## heading,
# as one line with runs of white space collapsed, so a sentence wrapped over lines still matches.
section_text() {
    awk -v h="$2" '
        $0 == h { on = 1; next }
        on && /^##/ { exit }
        on { print }
    ' "$PLUGIN_ROOT/$1" | tr '\n\t' '  ' | tr -s ' '
}

# Fail naming the instruction and the skill when the phrase is absent (case-insensitive).
must_say() {
    local text="$1" phrase="$2" what="$3" skill="$4"
    if ! printf '%s' "$text" | grep -qiF -- "$phrase"; then
        fail "$skill no longer tells the assistant to $what (looked for: $phrase)"
    fi
}

@test "Claude Code batch section exists and teaches save-entries.sh" {
    local t
    t="$(section_text "$CC_SKILL" '### Several entries in one request')"
    [[ -n "$t" ]] || fail "$CC_SKILL has no '### Several entries in one request' section"
    must_say "$t" 'save-entries.sh' 'use save-entries.sh for a batch' "$CC_SKILL"
}

@test "Claude Code batch: pass visibility only when the user has said who may see the entry" {
    local t
    t="$(section_text "$CC_SKILL" '### Several entries in one request')"
    must_say "$t" 'pass `visibility` only when the user has said who may see' \
        'pass visibility only when the user has said who may see the entry' "$CC_SKILL"
}

@test "Claude Code batch: pass personal true when an entry reads personal" {
    local t
    t="$(section_text "$CC_SKILL" '### Several entries in one request')"
    must_say "$t" 'reads personal' 'recognise an entry that reads personal' "$CC_SKILL"
    must_say "$t" 'pass `"personal": true`' 'pass personal true for it' "$CC_SKILL"
}

@test "Claude Code batch: never choose for the user, and wait for their answer" {
    local t
    t="$(section_text "$CC_SKILL" '### Several entries in one request')"
    must_say "$t" 'never choose for the user' 'never choose for the user' "$CC_SKILL"
    must_say "$t" 'wait for their answer' 'wait for the answer to the question' "$CC_SKILL"
}

@test "Codex AI database section exists and teaches save-entries.sh" {
    local t
    t="$(section_text "$CODEX_SKILL" '### Your AI database')"
    [[ -n "$t" ]] || fail "$CODEX_SKILL has no '### Your AI database' section"
    must_say "$t" 'save-entries.sh' 'use save-entries.sh for a batch' "$CODEX_SKILL"
}

@test "Codex batch: pass visibility only when the customer has said who may see the entry" {
    local t
    t="$(section_text "$CODEX_SKILL" '### Your AI database')"
    must_say "$t" 'pass `visibility` only when the customer has said who may see' \
        'pass visibility only when the customer has said who may see the entry' "$CODEX_SKILL"
}

@test "Codex batch: pass personal true when an entry reads personal" {
    local t
    t="$(section_text "$CODEX_SKILL" '### Your AI database')"
    must_say "$t" 'reads personal' 'recognise an entry that reads personal' "$CODEX_SKILL"
    must_say "$t" 'pass `"personal": true`' 'pass personal true for it' "$CODEX_SKILL"
}

@test "Codex batch: never choose for the customer" {
    local t
    t="$(section_text "$CODEX_SKILL" '### Your AI database')"
    must_say "$t" 'never choose for the customer' 'never choose for the customer' "$CODEX_SKILL"
}

@test "Codex batch: wait for their answer before sending the entry again" {
    local t
    t="$(section_text "$CODEX_SKILL" '### Your AI database')"
    must_say "$t" 'wait for their answer' 'wait for the answer before sending the entry again' "$CODEX_SKILL"
}

@test "/mmry:database batch section exists and teaches the batch command" {
    local t
    t="$(section_text "$DB_COMMAND" '### batch')"
    [[ -n "$t" ]] || fail "$DB_COMMAND has no '### batch' section"
    must_say "$t" 'database.sh" batch' 'run database.sh batch for a batch' "$DB_COMMAND"
}

@test "/mmry:database batch: pass visibility only when the customer has said who may see the entry" {
    local t
    t="$(section_text "$DB_COMMAND" '### batch')"
    must_say "$t" 'pass `visibility` only when the customer has said who may see'         'pass visibility only when the customer has said who may see the entry' "$DB_COMMAND"
}

@test "/mmry:database batch: pass personal true when an entry reads personal" {
    local t
    t="$(section_text "$DB_COMMAND" '### batch')"
    must_say "$t" 'reads personal' 'recognise an entry that reads personal' "$DB_COMMAND"
    must_say "$t" 'pass `"personal": true`' 'pass personal true for it' "$DB_COMMAND"
}

@test "/mmry:database batch: never choose for the customer" {
    local t
    t="$(section_text "$DB_COMMAND" '### batch')"
    must_say "$t" 'never choose for the customer' 'never choose for the customer' "$DB_COMMAND"
}

@test "/mmry:database batch: ask the question, wait for their answer, send again with visibility and questionId" {
    local t
    t="$(section_text "$DB_COMMAND" '### batch')"
    must_say "$t" 'ask the customer the question it carries' 'ask the customer the question a NOT SAVED entry carries' "$DB_COMMAND"
    must_say "$t" 'wait for their answer' 'wait for the answer before sending the entry again' "$DB_COMMAND"
    must_say "$t" 'with their answer as `visibility` and the printed `questionId`'         'send the entry again with the answer as visibility and the printed questionId' "$DB_COMMAND"
}
