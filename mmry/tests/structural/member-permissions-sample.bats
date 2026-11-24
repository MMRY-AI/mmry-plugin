#!/usr/bin/env bats
# member-permissions-sample.bats - #34651 (DD-207 in MMRY-AI/mmry): the plugin ships a SAMPLE of the
# permission rules a customer may copy so its Formation members stop less often,
# mmry/examples/member-permissions.json. It is documentation. A product default must never widen
# anyone's permissions on its own (DD-187), so nothing in the plugin may read, install or apply it.
#
# WORDING: cmo-mmry's approved W6 (R:/Intranet/ClaudeAI/plans/MMRY/v1.38/wording-approval-command-cmo.md),
# byte for byte, as the file's top-level "_comment".
#
#   E-01  the sample parses, is headed by W6, and holds a permissions block with allow and deny.
#   E-02  the allow list keeps W6's promise: nothing that deletes files, force-pushes or reads secrets,
#         and no push at all; the deny list refuses a forced push, a hard reset and a recursive delete.
#   E-03  the sample is never applied: no handler, hook, setup script, command, skill or connector file
#         names it or its folder, and it is not a settings file of either host.

W6="Sample only. MMRY AI never applies this file. Copy the rules you want into your own Claude Code settings, review each one, and leave commands that delete files, force-push or read secrets out of the allow list."

setup() {
    ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SAMPLE="${ROOT}/examples/member-permissions.json"
    if command -v jq >/dev/null 2>&1; then
        JQ="jq"
    else
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*) JQ="${ROOT}/vendor/jq/jq-windows-amd64.exe" ;;
            Darwin) JQ="${ROOT}/vendor/jq/jq-macos-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" ;;
            *) JQ="${ROOT}/vendor/jq/jq-linux-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" ;;
        esac
    fi
}

@test "E-01 34651 R4: the sample parses, is headed by the approved sentence, and holds allow and deny" {
    [ -f "$SAMPLE" ] || { echo "no sample at $SAMPLE"; return 1; }
    [ "$("$JQ" -r '._comment' < "$SAMPLE" | tr -d '\r')" = "$W6" ] || { echo "the header is not the approved sentence: $("$JQ" -r '._comment' < "$SAMPLE")"; return 1; }
    # The header is the first key, so a person opening the file reads it before any rule.
    [ "$("$JQ" -r 'keys_unsorted[0]' < "$SAMPLE" | tr -d '\r')" = "_comment" ]
    "$JQ" -e '(.permissions.allow | type) == "array" and (.permissions.allow | length) > 0
              and (.permissions.deny | type) == "array" and (.permissions.deny | length) > 0
              and ([.permissions.allow[], .permissions.deny[]] | all(type == "string" and test("^[A-Za-z]+[(].+[)]$")))' < "$SAMPLE" >/dev/null
    "$JQ" -e '(keys_unsorted) == ["_comment", "permissions"] and (.permissions | keys_unsorted) == ["allow", "deny"]' < "$SAMPLE" >/dev/null
}

@test "E-02 34651 R4: the allow list holds nothing that deletes files, force-pushes or reads secrets" {
    local allow deny
    allow="$("$JQ" -r '.permissions.allow[]' < "$SAMPLE" | tr -d '\r')"
    deny="$("$JQ" -r '.permissions.deny[]' < "$SAMPLE" | tr -d '\r')"
    ! grep -Eiq '(^|[( ])(rm|rmdir|del|Remove-Item|unlink|shred)( |[*)])' <<< "$allow" || { echo "the allow list deletes files:"; echo "$allow"; return 1; }
    ! grep -Eiq 'push|--force|reset|clean|rebase' <<< "$allow" || { echo "the allow list pushes, forces or rewrites:"; echo "$allow"; return 1; }
    ! grep -Eiq 'secret|\.env|credential|token|password|\.ssh|\.aws|^Read\(|cat |type |Get-Content' <<< "$allow" || { echo "the allow list reads secrets:"; echo "$allow"; return 1; }
    # Nothing that runs any command at all: no bare tool name, no pattern that is only a wildcard, and
    # no whole multi-purpose program (every git command, every shell, every interpreter).
    ! grep -Eq '^[A-Za-z]+$|\(\*\)|^(Bash|PowerShell)\((git|gh|npm|npx|dotnet|docker|kubectl|bash|sh|node|python3?|pwsh|powershell|sudo|env|curl|wget) ?\*\)$' <<< "$allow" || { echo "the allow list has a catch-all entry:"; echo "$allow"; return 1; }
    grep -q 'git push.*--force' <<< "$deny" || { echo "a forced push is not refused"; return 1; }
    grep -q 'git reset.*--hard' <<< "$deny" || { echo "a hard reset is not refused"; return 1; }
    grep -q 'rm -rf' <<< "$deny" || { echo "a recursive delete is not refused"; return 1; }
}

@test "E-03 34651 R4: the sample is never applied: nothing the plugin runs or tells an assistant names it" {
    local hits
    # Everything installed except the sample itself, the tests and the release list (which lists every file).
    hits="$(grep -rIl -e 'member-permissions' -e 'examples/' "$ROOT" \
            --exclude-dir=tests --exclude-dir=examples --exclude-dir=vendor --exclude-dir=.git \
            --exclude=release-files.txt 2>/dev/null || true)"
    [ -z "$hits" ] || { echo "these files name the sample or its folder:"; echo "$hits"; return 1; }
    # Not a settings file of either host, and not inside a folder a host reads settings from.
    [ "$(basename "$SAMPLE")" != "settings.json" ] && [ "$(basename "$SAMPLE")" != "settings.local.json" ]
    [[ "$SAMPLE" != *"/.claude/"* && "$SAMPLE" != *"/.codex/"* && "$SAMPLE" != *"/.claude-plugin/"* && "$SAMPLE" != *"/hooks/"* ]]
    # The examples folder holds this one file: no script rides along with it.
    [ "$(ls -A "${ROOT}/examples" | wc -l | tr -d ' ')" = "1" ] || { ls -A "${ROOT}/examples"; return 1; }
}
