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
