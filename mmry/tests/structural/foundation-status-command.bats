#!/usr/bin/env bats
# foundation-status-command.bats - the command SURFACE of /mmry:foundation-status (#31583 req 4).
#
# handlers/foundation-status.bats covers what the handler REPORTS. Nothing covered whether a
# customer can reach it. Requirement 4 is "the customer can tell, without reading a file,
# whether their directives are reaching their assistants", and a handler nobody can invoke
# satisfies none of that. The formation commands have exactly these assertions; this one
# shipped without them.

load '../helpers/test-helper'

setup() {
    CMDS="$PLUGIN_ROOT/commands"
    HANDLERS="$PLUGIN_ROOT/hooks-handlers"
}

@test "command: /mmry:foundation-status exists and is advertised in help" {
    [ -f "$CMDS/foundation-status.md" ]
    [ -s "$CMDS/foundation-status.md" ]
    run grep -c 'mmry:foundation-status' "$CMDS/help.md"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "command: the page names a handler that actually ships" {
    # The document is the only thing that connects the slash command to the script. If it
    # names a path that is not there, the command fails at the moment a customer reaches for
    # it, which is the moment this ticket exists to serve.
    local named
    named="$(grep -o 'hooks-handlers/[a-z-]*\.sh' "$CMDS/foundation-status.md" | sort -u)"
    [ -n "$named" ]
    [ "$named" = "hooks-handlers/foundation-status.sh" ]
    [ -f "$PLUGIN_ROOT/$named" ]
}

@test "command: EVERY command page names handlers that ship, not just this one" {
    # Generalised deliberately. The specific assertion above would have caught this command
    # alone; this catches the next one too, and costs nothing.
    local doc named missing=""
    for doc in "$CMDS"/*.md; do
        for named in $(grep -o 'hooks-handlers/[a-z-]*\.sh' "$doc" | sort -u); do
            [ -f "$PLUGIN_ROOT/$named" ] || missing+="  $(basename "$doc") -> $named"$'\n'
        done
    done
    [ -z "$missing" ] || { echo "command pages naming handlers that do not exist:"; echo "$missing"; return 1; }
}

@test "command: the page resolves the handler the same way every other command does" {
    # A command that invented its own path would work for whoever wrote it and fail on a
    # normal install. This pins it to the convention the shipped commands already use.
    run grep -c 'CLAUDE_PLUGIN_ROOT' "$CMDS/foundation-status.md"
    [ "$output" -ge 1 ]
    run grep -c 'HOME}/.claude/mmry/hooks-handlers' "$CMDS/foundation-status.md"
    [ "$output" -ge 1 ]
}

@test "command: the page tells a customer what to DO when the copy is refused (#31583 req 3)" {
    # Requirement 3 is that a damaged copy is reported to the person who can act on it.
    # Reporting a fault without naming the remedy leaves them informed and stuck, so the page
    # has to carry the remedy and has to say the directives are not being applied until then.
    #
    # Matched against the file with its line breaks flattened, NOT line by line. The first
    # cut of this used `grep -ci 'not being applied'` and went red against a document that
    # says exactly that, because markdown had wrapped the phrase between "being" and
    # "applied". A per-line grep over prose asserts the reflow, not the sentence.
    local doc="$CMDS/foundation-status.md" text
    text="$(tr '
' ' ' < "$doc")"
    [[ "$text" == *'/mmry:load-memories'* ]]
    [[ "$text" == *'not being applied'* ]]
    [[ "$text" == *'DAMAGED'* ]]
}

@test "docs: the README does not still promise the truncation #31411 removed" {
    # The README described the cut as current behaviour: "Beyond this the set is truncated
    # and the drop is logged", against a default of 1500 tokens. That sentence survived the
    # fix, so the one customer-facing document describing this feature told a customer their
    # directives were being trimmed when they no longer are. A stale promise in the docs is
    # the same defect as the behaviour, one surface along.
    local readme text
    readme="$PLUGIN_ROOT/README.md"
    text="$(tr '
' ' ' < "$readme")"
    [[ "$text" != *'the set is truncated and the drop is logged'* ]] || { echo "README still describes the removed cut"; return 1; }
    [[ "$text" == *'delivered in full'* ]]
}

@test "docs: the README tells a customer their copy is verified, and how to ask (#31583)" {
    # Requirements 3 and 4 are customer-facing, and the README is where a customer looks
    # before they know a slash command exists. It has to carry both the refusal behaviour
    # and the name of the command that answers the question on demand.
    local readme text
    readme="$PLUGIN_ROOT/README.md"
    text="$(tr '
' ' ' < "$readme")"
    [[ "$text" == *'mmry:foundation-status'* ]]
    [[ "$text" == *'refused'* ]]
    [[ "$text" == *'mmry:load-memories'* ]]
}

@test "docs: the shipped example config does not seed a setting that does nothing (#31411)" {
    # mmry-config.example.json is what a new install copies. Seeding it with
    # foundationReinjectTokenCap hands every new customer a knob that reads as a working
    # limit and controls nothing. The key is still PARSED, so an existing config keeps
    # working and config-loading.bats keeps its shear canary; it just is not planted in new
    # ones.
    local cfg="$PLUGIN_ROOT/mmry-config.example.json"
    [ -f "$cfg" ]
    run grep -c 'foundationReinjectTokenCap' "$cfg"
    [ "$output" = "0" ]
    # Premise: the file still carries the keys that DO work, so an empty file cannot pass.
    run grep -c 'foundationReinject"' "$cfg"
    [ "$output" -ge 1 ]
    run grep -c 'foundationRefreshSeconds' "$cfg"
    [ "$output" -ge 1 ]
}
