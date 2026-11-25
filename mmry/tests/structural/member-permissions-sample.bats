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
#   E-04  round 2: by the documented matching rules, the sample allows no command that reads a file,
#         writes one or runs another, refuses the named ones outright, and allows the everyday forms.
#   E-05  round 2: the rule helper answers the documentation's own examples.
#   E-06  round 2: the round 1 sample is refused by the same helper.

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
    # Round 2 (Seat A's review, backlog item 1): git OPTIONS, not only words. A wildcard after a git
    # subcommand admits every option of it, and "git diff --no-index /dev/null .env" reads a file past
    # the sample's own Read(./.env) refusal while "git log --output=<path>" writes one. So no allow
    # entry holds a wildcard at all, and none names an option that reads, writes or runs something.
    ! grep -Fq '*' <<< "$allow" || { echo "an allow entry holds a wildcard, which admits every option after it:"; grep -F '*' <<< "$allow"; return 1; }
    ! grep -Eq -e '--no-index|--output|--upload-pack|--receive-pack|--exec|--pathspec|--file|--config-env|[( ]-[cCF][ )]' <<< "$allow" || { echo "an allow entry names an option that reads a file, writes one or runs a command:"; echo "$allow"; return 1; }
    ! grep -Eq '^[A-Za-z]+\((git )?(commit|merge|checkout|restore|switch|branch|worktree|submodule|clean|stash|config|clone|pull)([ )]|$)' <<< "$allow" || { echo "the allow list holds a git command that takes a message file, discards work or runs another program:"; echo "$allow"; return 1; }
    grep -q 'git .*push.*--force' <<< "$deny" || { echo "a forced push is not refused"; return 1; }
    grep -q 'git .*reset.*--hard' <<< "$deny" || { echo "a hard reset is not refused"; return 1; }
    grep -q 'rm -rf' <<< "$deny" || { echo "a recursive delete is not refused"; return 1; }
}

# ---- Round 2: what the rules DECIDE, by the documented matching rules ---------------------------------
# tests/helpers/permission-rule-match.jq is this repository's own small reading of the rules Claude Code
# documents for Bash permission entries (deny, then ask, then allow; * is any text; a compound command
# is split). It is not Claude Code's matcher, so these tests prove the text of the sample, not a live
# session. E-05 pins the helper itself to the documentation's own examples.

_decide() { # $1 settings file, $2 a file of commands, one a line, $3 "0" for the Bash rules alone
    # (no built-in read-only commands). Prints "decision<TAB>command" lines.
    "$JQ" -r --arg tool Bash --arg readonly "${3:-1}" --rawfile cmds "$2" -f "${ROOT}/tests/helpers/permission-rule-match.jq" "$1" | tr -d '\r'
}

@test "E-04 34651 round 2: no command that reads a file, writes one or runs another is allowed by the sample, and the routine ones are" {
    local out bad cmds="${BATS_TEST_TMPDIR}/cmds.txt"
    cat > "$cmds" <<'CMDS'
git diff --no-index /dev/null .env
git diff --no-index -- /dev/null secrets/key.pem
git diff --output=/tmp/x
git log --output=settings.json
git log -1 --output=x --format=%s
git show --output=x HEAD
git -c core.fsmonitor=./evil.sh status
git -c core.pager=./evil.sh log
git -C . -c core.fsmonitor=./evil.sh status
git fetch --upload-pack=./evil.sh origin
git fetch origin --upload-pack=./evil.sh
git ls-remote --upload-pack=./evil.sh origin
git submodule foreach rm -rf .
git rebase --exec ./evil.sh HEAD~1
git commit -m x --pathspec-from-file=.env
git commit -F .env
git add --pathspec-from-file=.env
git status && cat .env
git status; rm -rf .
git log $(cat .env)
git push --force
git push -f origin main
git push -fu origin main
git push origin +main
git push origin main --force-with-lease
git push --mirror
git reset --hard HEAD~1
rm -rf build
npm test -- --prefix /tmp/other
npm test --prefix /tmp/other
dotnet test /tmp/other/evil.csproj
pytest -p evil /tmp/other
pytest --rootdir /tmp/other
CMDS
    out="$(_decide "$SAMPLE" "$cmds")"
    [ "$(grep -c . <<< "$out")" -eq 33 ] || { echo "the helper did not answer for every command:"; echo "$out"; return 1; }
    bad="$(grep -E '^allow' <<< "$out" || true)"
    [ -z "$bad" ] || { echo "the sample ALLOWS:"; echo "$bad"; return 1; }
    # The named forms are refused outright, not merely left to ask.
    for bad in "git diff --no-index /dev/null .env" "git log --output=settings.json" "git -c core.fsmonitor=./evil.sh status" \
               "git fetch --upload-pack=./evil.sh origin" "git submodule foreach rm -rf ." "git rebase --exec ./evil.sh HEAD~1" \
               "git push --force" "git push -fu origin main" "git push origin +main" "git push --mirror" "git reset --hard HEAD~1" "rm -rf build"; do
        grep -qxF -- "deny	${bad}" <<< "$out" || { echo "not refused: ${bad}"; grep -F -- "$bad" <<< "$out"; return 1; }
    done
    # And the sample is still worth copying: the everyday forms run without a prompt.
    cat > "$cmds" <<'CMDS'
git status
git status --short
git diff
git diff --staged
git log
git log --oneline
git show
git fetch
git fetch origin
git add -A
npm test
dotnet test
pytest
CMDS
    out="$(_decide "$SAMPLE" "$cmds")"
    bad="$(grep -v -E '^allow' <<< "$out" || true)"
    [ -z "$bad" ] || { echo "an everyday command is not allowed by the sample:"; echo "$bad"; return 1; }
    [ "$(grep -c . <<< "$out")" -eq 13 ] || { echo "$out"; return 1; }
}

@test "E-05 34651 round 2: the rule helper answers the Claude Code documentation's own examples" {
    local s="${BATS_TEST_TMPDIR}/doc.json" out
    _one() { # $1 allow rules as a JSON array, $2 deny rules, $3 command. Prints the decision.
        printf '{"permissions":{"allow":%s,"deny":%s}}\n' "$1" "$2" > "$s"
        printf '%s\n' "$3" > "${s}.cmds"
        _decide "$s" "${s}.cmds" "${RO:-0}" | cut -f1
    }
    _is() { # $1 wanted decision, then _one's three arguments
        out="$(_one "$2" "$3" "$4")"
        [ "$out" = "$1" ] || { echo "allow $2 deny $3: [$4] gave [$out], the documentation says [$1]"; return 1; }
    }
    # The wildcard table (permissions page, "Wildcard patterns").
    _is allow '["Bash(npm run build)"]' '[]' 'npm run build' || return 1
    _is none  '["Bash(npm run build)"]' '[]' 'npm run build --watch' || return 1
    _is allow '["Bash(npm run *)"]' '[]' 'npm run build' || return 1
    _is allow '["Bash(npm run *)"]' '[]' 'npm run test --watch' || return 1
    _is allow '["Bash(npm run *)"]' '[]' 'npm run' || return 1
    _is none  '["Bash(npm run *)"]' '[]' 'npm install' || return 1
    _is allow '["Bash(git log * main)"]' '[]' 'git log --oneline main' || return 1
    _is allow '["Bash(git log * main)"]' '[]' 'git log --output=file main' || return 1
    _is none  '["Bash(git log * main)"]' '[]' 'git log main' || return 1
    _is none  '["Bash(git log * main)"]' '[]' 'git push origin main' || return 1
    _is allow '["Bash(git * main)"]' '[]' 'git -c core.fsmonitor=script diff main' || return 1
    _is none  '["Bash(git * main)"]' '[]' 'git log' || return 1
    _is allow '["Bash(* --version)"]' '[]' 'node --version' || return 1
    _is none  '["Bash(* --version)"]' '[]' 'node -v' || return 1
    _is allow '["Bash(ls *)"]' '[]' 'ls -la' || return 1
    _is allow '["Bash(ls *)"]' '[]' 'ls' || return 1
    _is none  '["Bash(ls *)"]' '[]' 'lsof' || return 1
    _is allow '["Bash(ls*)"]' '[]' 'lsof' || return 1
    _is allow '["Bash(* --help *)"]' '[]' 'npm --help x' || return 1
    _is none  '["Bash(* --help *)"]' '[]' 'npm --help' || return 1
    _is allow '["Bash(ls:*)"]' '[]' 'ls -la' || return 1
    _is allow '["Bash(ls:*)"]' '[]' 'ls' || return 1
    _is none  '["Bash(git:* push)"]' '[]' 'git push' || return 1
    # Deny before allow, and an allow entry never carves an exception out of a deny entry.
    _is deny  '["Bash(aws s3 ls)"]' '["Bash(aws *)"]' 'aws s3 ls' || return 1
    _is deny  '["Bash(npm run *)","Bash(git commit *)"]' '["Bash(git push *)"]' 'git push origin main' || return 1
    _is none  '["Bash(npm run *)","Bash(git commit *)"]' '["Bash(git push *)"]' 'git -C . push origin main' || return 1
    # Compound commands: every part must be allowed, and a deny applies to any part.
    _is none  '["Bash(safe-cmd *)"]' '[]' 'safe-cmd && other-cmd' || return 1
    _is allow '["Bash(safe-cmd *)","Bash(other-cmd)"]' '[]' 'safe-cmd && other-cmd' || return 1
    _is deny  '["Bash(cd *)"]' '["Bash(git clean *)"]' 'cd /tmp && git clean -f' || return 1
    _is deny  '["Bash(echo *)"]' '["Bash(git clean *)"]' 'echo "$(git clean -f)"' || return 1
    # Wrappers and leading assignments.
    _is allow '["Bash(npm test *)"]' '[]' 'timeout 30 npm test' || return 1
    _is deny  '[]' '["Bash(rm *)"]' 'FOO=bar rm -rf tmp/' || return 1
    _is none  '["Bash(npm test *)"]' '[]' 'EVIL=1 npm test' || return 1
    # A redirect is never allowed by this helper (Claude Code checks its target against the file rules).
    _is none  '["Bash(gh pr diff *)"]' '[]' 'gh pr diff 1 > out.txt' || return 1
    # More wrappers, and the body of a loop or an if (Seat A's delta, matcher review).
    _is deny  '[]' '["Bash(rm *)"]' 'stdbuf -o0 rm -rf x' || return 1
    _is deny  '[]' '["Bash(rm *)"]' 'xargs rm -rf x' || return 1
    _is deny  '[]' '["Bash(rm *)"]' 'nice -n 5 rm -rf x' || return 1
    _is deny  '[]' '["Bash(rm *)"]' 'for f in a; do rm -rf build; done' || return 1
    _is deny  '[]' '["Bash(rm *)"]' 'if true; then rm -rf x; fi' || return 1
    _is none  '["Bash(npm test *)"]' '[]' 'npm test &&' || return 1
    # Round 3 (delta A3): the built-in read-only commands run with no rule at all, and only a deny stops
    # them. Every row above was answered with them switched off; these are answered with them on.
    RO=1
    _is allow '[]' '[]' 'cat .secrets/x.json' || return 1
    _is allow '[]' '[]' 'git status' || return 1
    _is allow '[]' '[]' 'git log --oneline -1' || return 1
    _is allow '[]' '[]' 'git -C /r status' || return 1
    _is allow '[]' '[]' 'head -5 notes.txt' || return 1
    _is allow '[]' '[]' 'git --no-pager -c core.fsmonitor=./evil.sh status' || return 1
    _is none  '[]' '[]' 'git commit -m x' || return 1
    _is none  '[]' '[]' 'npm test' || return 1
    _is none  '[]' '[]' 'find . -name x -delete' || return 1
    _is none  '[]' '[]' 'cat notes.txt > copy.txt' || return 1
    _is none  '[]' '[]' 'cat notes.txt && npm test' || return 1
    _is deny  '[]' '["Read(./.secrets/**)"]' 'cat .secrets/x.json' || return 1
    _is deny  '[]' '["Read(./.secrets/**)"]' 'cat ./.secrets/a/b.json' || return 1
    _is allow '[]' '["Read(./.secrets/**)"]' 'cat docs/.secrets/x.json' || return 1
    _is deny  '[]' '["Read(./**/.secrets/**)"]' 'cat docs/.secrets/x.json' || return 1
    _is deny  '[]' '["Read(//**/.secrets/**)"]' 'cat R:/Intranet/ClaudeAI/.secrets/mmry/x.json' || return 1
    _is deny  '[]' '["Read(./.env)"]' 'git status && cat .env' || return 1
    _is allow '[]' '["Read(./.env)"]' 'cat .env.local' || return 1
    _is deny  '[]' '["Read(./.env.*)"]' 'head -1 .env.local' || return 1
    _is deny  '[]' '["Bash(git * -c *)"]' 'git --no-pager -c core.fsmonitor=./evil.sh status' || return 1
    RO=0
}

# ---- Round 3 (delta A3, Seat C gap 3): reads Claude Code runs without asking ---------------------------
# cat, head, grep and the read-only forms of git need no allow entry, so "the allow list reads no
# secrets" (W6) is kept only by DENY entries. These are the commands a member's assistant could run
# with no prompt at all if the sample did not refuse them.
SECRET_READS='cat .secrets/x.json
cat ./.secrets/mmry/db.json
head -3 .secrets/x.json
grep password .secrets/x.json
cat config/.secrets/x.json
cat .env
cat ./.env
cat .env.local
head -1 .env.production
grep KEY config/.env
cat services/api/.env.local
tail -5 secrets/key.pem
git --no-pager -c core.fsmonitor=./evil.sh status
git --git-dir=.git -c core.fsmonitor=./evil.sh status
git -P -c core.pager=./evil.sh log
git -C . -c core.fsmonitor=./evil.sh status'

@test "E-07 34651 round 3: the sample refuses every read of .secrets and of an .env file that Claude Code would otherwise run without asking, and a config value behind a git option" {
    local out bad cmds="${BATS_TEST_TMPDIR}/reads.txt"
    printf '%s\n' "$SECRET_READS" > "$cmds"
    out="$(_decide "$SAMPLE" "$cmds")"
    [ "$(grep -c . <<< "$out")" -eq 16 ] || { echo "the helper did not answer for every command:"; echo "$out"; return 1; }
    bad="$(grep -v -E '^deny' <<< "$out" || true)"
    [ -z "$bad" ] || { echo "not refused by the sample (allow means it runs with no prompt):"; echo "$bad"; return 1; }
    # The everyday reads stay free: a deny that swallowed them would make the sample useless.
    printf '%s\n' 'cat README.md' 'git status' 'git log --oneline -1' 'grep -rn TODO src' 'ls -la' 'cat src/environment.ts' > "$cmds"
    out="$(_decide "$SAMPLE" "$cmds")"
    bad="$(grep -v -E '^allow' <<< "$out" || true)"
    [ -z "$bad" ] || { echo "an everyday read is not allowed:"; echo "$bad"; return 1; }
}

@test "E-08 34651 round 3: without its .secrets and .env denies the sample lets those reads run unasked (the proof E-07 can fail)" {
    local s="${BATS_TEST_TMPDIR}/no-read-denies.json" out cmds="${BATS_TEST_TMPDIR}/reads.txt"
    "$JQ" '.permissions.deny |= map(select(test("[.]secrets|[.]env|^Bash[(]git [*] -c ") | not))' < "$SAMPLE" > "$s"
    [ "$("$JQ" '.permissions.deny | length' < "$s")" -lt "$("$JQ" '.permissions.deny | length' < "$SAMPLE")" ] || { echo "the sample holds no .secrets or .env deny to take away"; return 1; }
    printf '%s\n' "$SECRET_READS" > "$cmds"
    out="$(_decide "$s" "$cmds")"
    [ "$(grep -c '^allow' <<< "$out")" -ge 14 ] || { echo "the helper no longer shows these reads as running unasked:"; echo "$out"; return 1; }
    # And with the built-in read-only commands switched off, the old blind spot: nothing is flagged.
    out="$(_decide "$s" "$cmds" 0)"
    [ "$(grep -c '^allow' <<< "$out")" -eq 0 ] || { echo "$out"; return 1; }
}

@test "E-06 34651 round 2: the round 1 sample is what these tests refuse (the proof they can fail)" {
    # The entries round 1 shipped, kept here so the refusal stays proven after the sample was narrowed.
    local s="${BATS_TEST_TMPDIR}/round1.json" out cmds="${BATS_TEST_TMPDIR}/cmds1.txt"
    printf '%s\n' '{"permissions":{"allow":["Bash(git status *)","Bash(git log *)","Bash(git diff *)","Bash(git show *)","Bash(git fetch *)","Bash(git add *)","Bash(git commit *)","Bash(npm test *)","Bash(npm run test *)","Bash(dotnet test *)","Bash(pytest *)"],"deny":["Bash(git push*--force*)","Bash(git push* -f)","Bash(git push* -f *)","Bash(git reset*--hard*)","Bash(rm -rf*)","Bash(rm -fr*)","Read(./.env)","Read(./.env.*)","Read(./secrets/**)"]}}' > "$s"
    cat > "$cmds" <<'CMDS'
git diff --no-index /dev/null .env
git log --output=settings.json
git fetch --upload-pack=./evil.sh origin
git commit -m x --pathspec-from-file=.env
CMDS
    out="$(_decide "$s" "$cmds")"
    [ "$(grep -c '^allow' <<< "$out")" -eq 4 ] || { echo "the helper no longer shows what was wrong with the round 1 sample:"; echo "$out"; return 1; }
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
    [[ "$SAMPLE" != *"/.claude/"* && "$SAMPLE" != *"/.codex/"* && "$SAMPLE" != *"/.claude-plugin/"* && "$SAMPLE" != *"/hooks/"* ]] || return 1
    # The examples folder holds this one file: no script rides along with it.
    [ "$(ls -A "${ROOT}/examples" | wc -l | tr -d ' ')" = "1" ] || { ls -A "${ROOT}/examples"; return 1; }
}
