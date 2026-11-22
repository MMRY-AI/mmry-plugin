#!/usr/bin/env bats
# formation-names-only-docs.bats - the formation command page and the Codex skill describe a
# names-only list and member-only details (#31854, DD-198; requirements 4 and 5).
#
# The sentences are held here as the customer reads them, with line breaks folded, so a page that
# drops one fails by name. Joining from the list is unchanged and is asserted too, because the
# first plan for this ticket removed it.

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    CMD="$(tr '\n' ' ' < "${ROOT}/commands/formation.md" | tr -s ' ')"
    CODEX="$(sed 's/^> \{0,1\}//' "${ROOT}/skills-codex/memory-system/SKILL.md" | tr '\n' ' ' | tr -s ' ')"
}

@test "command page: the list is described as every active formation by id and name only" {
    [[ "$CMD" == *"The list shows every active formation on the account by id and name only."* ]]
}

@test "command page: a formation's details are described as for current members and the starter" {
    [[ "$CMD" == *"A formation's members, messages, claimed areas, work queue and close-out record are shown only to its current members and the person who started it."* ]]
}

@test "command page: roster, status and report each say who can read them and what anyone else gets" {
    local s="Only a current member of the formation, or the person who started it, can read this. For anyone else, including another window of a member, an account administrator who is not in the formation, and a member who has left, the formation is not found."
    local n
    n="$(printf '%s' "$CMD" | grep -o -F "$s" | wc -l | tr -d ' ')"
    [ "$n" -ge 3 ]
}

@test "command page: the list is not said to show an objective or a member count" {
    [[ "$CMD" != *"Show the objective and id of each"* ]] || return 1
    [[ "$CMD" != *"active member(s)"* ]] || return 1
    [[ "$CMD" == *"Show the id and name of each, ask which one, and stop."* ]]
}

@test "command page: joining from the list is still the guidance" {
    [[ "$CMD" == *"If they gave no id, do not guess. List their active formations so they can pick one:"* ]] || return 1
    [[ "$CMD" == *'hooks-handlers/formation-list.sh'* ]]
}

@test "codex skill: the list is names only and everything else is for members and the starter" {
    [[ "$CODEX" == *"\`mmry_formation_list\` shows every Formation running on the account by id and name only. Everything else about a Formation is shown only to its current members and the person who started it."* ]]
}

@test "codex skill: the list script is described as printing ids and names only" {
    [[ "$CODEX" == *"It prints each active formation's id and name and nothing else."* ]]
}

@test "command page: the close-out record is no longer said to be readable by people never in the formation" {
    [[ "$CMD" != *"readable by people who were never in the formation"* ]] || return 1
    [[ "$CMD" == *"this record is read by every current member and by the person who started the formation"* ]]
}
