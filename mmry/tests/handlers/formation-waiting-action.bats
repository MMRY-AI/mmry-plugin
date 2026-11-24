#!/usr/bin/env bats
# formation-waiting-action.bats - #34651 (DD-207 in MMRY-AI/mmry, amending DD-206): a member waiting on
# approval tells its lead what KIND of command it waits to run, the program plus an ACTION taken from a
# closed grammar, and nothing else of the command.
#
# THE GRAMMAR (lead rulings: option D of plan-approval-command-B.md, and "closed per-tool subcommand
# list", decisions.md 2026-11-24):
#   subcommand  the program is one of git gh dotnet npm pnpm yarn docker kubectl az cargo go pip winget
#               brew, and the word right after it is one of THAT TOOL'S KNOWN SUBCOMMANDS, a closed
#               list: git push -> "push". Any other word, a lowercase secret in that place included
#               (npm secretx1a2b3), sends the program alone.
#               A flag first (git -C dir push) gives NO action: the list never learns flag arities,
#               so a flag's value can never be taken for the subcommand.
#   script      the program is one of bash sh node pwsh powershell python python3, and the first word
#               that is not a flag is a script file: bash scripts/check-x.sh -> "script check-x.sh",
#               the folder removed.
#   inline      the same programs with -e, -c, -Command or --eval first: "inline", and no code.
#   anything else sends the program alone, as #34519 does.
#
# THE PRIVACY RULE (#34519, kept): no argument, path, flag value, environment value or quoted text of
# the command leaves the machine or is written to local state. Every case below reads the request
# body sent AND every .mmry-* state file written, and looks for the command's own words in both.
#
# WHAT IS PINNED
#   K-01..07  the plan's cases, on a Claude Code payload and on a Codex payload each.
#   K-08      a 1 MB command stays inside the time budget of S-05 (formation-waiting-approvals.bats);
#   K-08b     a 3 KB command is raised with its action.
#   K-09      the grammar alone (the jq program, read out of the handler), row by row.
#   K-10..12  the local ask record: a line outside the vocabulary sends no action; an action never
#             goes without its program; a helper's request raised from the ask carries it.
#   K-13      an older record (no action line) and a prompt with no ask record still raise, program only.
#   K-14      the closed list, end to end: a lowercase word that is not a known subcommand of its tool
#             is never sent, and a script or inline action never goes with a tool that is no interpreter.
#   K-15      the closed lists are the service's, word for word (needs MMRY_SERVICE_REPO).

load '../helpers/test-helper'
load '../helpers/formation-waiting-helpers.sh'

JQ_BIN="$(command -v jq)"
SAID='Claude needs your permission to use Bash'

_sent() { "$JQ_BIN" -r "(.$1 // \"<none>\")" < "$BODIES" | tail -1; }
# Every state file the handlers keep for this session, as it stands now, added to what was seen.
_snap() { cat "$TEST_TMPDIR"/.mmry-* >> "$TEST_TMPDIR/state-seen" 2>/dev/null || true; }
# A shell tool's input holding this command, built by jq so no quoting is done by hand (bash 3.2
# mis-reads \" inside "$( )": the macOS finding of #34519 fix round 1). The command goes in on stdin,
# never as an argument: Git Bash on Windows rewrites an argument that looks like a path (/usr/bin/git).
_input() { printf '%s' "$1" | "$JQ_BIN" -cRs '{command: .}'; }

# One prompt for COMMAND as HOST sends it. Claude Code: the PermissionRequest hook (the ask record),
# then the permission_prompt Notification (the raise). Codex: its PermissionRequest is the raise.
_prompt() { # $1 claude|codex, $2 command
    local in
    rm -f "$TEST_TMPDIR"/.mmry-waiting-* "$TEST_TMPDIR"/.mmry-asking-* "$TEST_TMPDIR"/.mmry-approved-*
    : > "$BODIES"; : > "$URLS"; : > "$TEST_TMPDIR/state-seen"
    in="$(_input "$2")"
    if [[ "$1" == "codex" ]]; then
        _waiting "$(_codex_ask Bash "" "$in")"
    else
        _ask "$(_cc_ask_in Bash "" "$in")" || true
        _snap
        _waiting "$(_notification permission_prompt "$SAID")"
    fi
    _snap
    [ "$(_puts)" -eq 1 ] || { echo "$1: the prompt was not raised once for [$2]"; cat "$URLS"; return 1; }
}
_expect() { # $1 host, $2 program or <none>, $3 action or <none>
    [ "$(_sent programName)" = "$2" ] || { echo "$1: program [$(_sent programName)], wanted [$2]"; cat "$BODIES"; return 1; }
    [ "$(_sent programAction)" = "$3" ] || { echo "$1: action [$(_sent programAction)], wanted [$3]"; cat "$BODIES"; return 1; }
    [ "$(_sent toolName)" = "Bash" ] || { echo "$1: the tool name was not sent"; cat "$BODIES"; return 1; }
}
# None of these words, each a piece of the command, was sent or kept.
_never() { # $1 host, $2.. words
    local h="$1" w; shift
    for w in "$@"; do
        ! grep -qF -- "$w" "$BODIES" || { echo "$h: [$w] was SENT"; cat "$BODIES"; return 1; }
        ! grep -qF -- "$w" "$TEST_TMPDIR/state-seen" || { echo "$h: [$w] was WRITTEN to local state"; cat "$TEST_TMPDIR/state-seen"; return 1; }
    done
}

# ---- K-01..07: the plan's cases, both hosts -----------------------------------------------------------

@test "K-01 34651 R1 R2: git push origin main --force sends program git and action push, and never origin, main or --force" {
    local h
    for h in claude codex; do
        _prompt "$h" "git push origin main --force" || return 1
        _expect "$h" git push || return 1
        _never "$h" origin main --force force || return 1
    done
}

@test "K-02 34651 R2: an environment prefix (TOKEN=abc git push) sends no program and no action" {
    local h
    for h in claude codex; do
        _prompt "$h" "TOKEN=$PLANTED git push" || return 1
        _expect "$h" "<none>" "<none>" || return 1
        _never "$h" TOKEN "$PLANTED" push || return 1
    done
}

@test "K-03 34651 R2: a flag before the subcommand (git -C dir push) sends git and NO action, whatever the flag's value looks like" {
    local h c
    for h in claude codex; do
        for c in "git -C /secret/dir push" "git -C secretdir push" "git --no-pager log" "git -c user.name=secretname commit"; do
            _prompt "$h" "$c" || return 1
            _expect "$h" git "<none>" || { echo "for [$c]"; return 1; }
            _never "$h" secret push log commit pager user.name || { echo "for [$c]"; return 1; }
        done
    done
}

@test "K-04 34651 R1 R2: a script file sends script and its file name, never its folder or its arguments" {
    local h
    for h in claude codex; do
        _prompt "$h" "bash scripts/check-x.sh --flag $PLANTED" || return 1
        _expect "$h" bash "script check-x.sh" || return 1
        _never "$h" scripts/ scripts --flag flag "$PLANTED" || return 1

        _prompt "$h" "node C:/a/b/run.mjs" || return 1
        _expect "$h" node "script run.mjs" || return 1
        _never "$h" "C:" "a/b" "/run" || return 1

        _prompt "$h" 'pwsh -NoProfile -File C:\Users\seat\repos\rotate-key.ps1 -Key '"$PLANTED" || return 1
        _expect "$h" pwsh "script rotate-key.ps1" || return 1
        _never "$h" Users seat repos NoProfile File -Key "$PLANTED" || return 1
    done
}

@test "K-05 34651 R1 R2: inline code (node -e, bash -c, python -c, pwsh -Command, node --eval) sends inline and none of the code" {
    local h
    for h in claude codex; do
        _prompt "$h" "node -e \"fs.writeFileSync('R:/plans/x.txt', '$PLANTED')\"" || return 1
        _expect "$h" node inline || return 1
        _never "$h" fs writeFileSync plans x.txt "$PLANTED" || return 1

        _prompt "$h" "bash -c \"echo $PLANTED > /tmp/out.txt\"" || return 1
        _expect "$h" bash inline || return 1
        _never "$h" echo "$PLANTED" tmp out.txt || return 1

        _prompt "$h" "python -c 'import os; os.remove(\"secretfile\")'" || return 1
        _expect "$h" python inline || return 1
        _never "$h" import remove secretfile || return 1

        _prompt "$h" "pwsh -Command Remove-Item secretfile" || return 1
        _expect "$h" pwsh inline || return 1
        _never "$h" Remove-Item secretfile Command || return 1

        _prompt "$h" "node --eval process.exit(secretcode)" || return 1
        _expect "$h" node inline || return 1
        _never "$h" process secretcode eval || return 1
    done
}

@test "K-06 34651 R2: a bearer-token curl sends curl only" {
    local h
    for h in claude codex; do
        _prompt "$h" "curl -H \"Authorization: Bearer $PLANTED\" https://h.example/x" || return 1
        _expect "$h" curl "<none>" || return 1
        _never "$h" Authorization Bearer "$PLANTED" https h.example || return 1
    done
}

@test "K-07 34651 R2: cat of a secrets file sends cat only: cat is not a subcommand tool" {
    local h
    for h in claude codex; do
        _prompt "$h" "cat ~/.secrets/x.json" || return 1
        _expect "$h" cat "<none>" || return 1
        _never "$h" secrets x.json "~" || return 1
    done
}

# ---- K-08: a 1 MB command ------------------------------------------------------------------------------

# BOUND: the 7 whole seconds S-05 holds the whole check to (formation-waiting-approvals.bats), for one
# whole handler run here: reading the payload, the grammar, the roster read and the PUT. Whole seconds,
# because bash 3.2 has no finer clock (structural/bash32-portability.bats). S-05's bound is known to be
# tight on a loaded Windows PC (its fixed cost alone measured 2.2 to 4.0 s), so a run over 7 s passes
# only when it is no more than 3 s over a ONE-WORD command timed in the same test: what is pinned is
# that the cost does not grow with the command, as S-05 pins that it does not grow with the session.
# The payload is built by hand, not by jq --arg: a 1 MB argument cannot be passed to a program on Windows.
#
# MEASURED, AND NOT CHANGED HERE: the shared payload reader (lib-hookread.sh) reads with bash's read
# under a 2 s deadline. On Windows Git Bash that read measured about 12 KB a second (10 KB in 1.0 s,
# 100 KB in 8.7 s, 2026-11-24), so a 1 MB payload is cut off there, the handler cannot parse what it
# got, and it reports nothing at all, as the #34519 handler does. On Linux and macOS the same read is
# far quicker and the prompt is raised. Both outcomes are accepted below, and the test prints which
# one it saw; neither may send or keep any of the command.
_timed() { local t0=$SECONDS; "$@" || true; TOOK=$(( SECONDS - t0 )); }
_inside_budget() { # $1 seconds taken, $2 seconds a one-word command took, $3 what
    [ "$1" -le 7 ] || [ "$1" -le $(( $2 + 3 )) ] || { echo "$3 took $1 s (a one-word command: $2 s)"; return 1; }
}
@test "K-08 34651 R2: a 1 MB command stays inside the S-05 time budget, and nothing of it is sent or kept" {
    local pad in base raised
    pad="$(printf '%0*d' 1000000 0)"

    # Codex: the PermissionRequest is the raise.
    rm -f "$TEST_TMPDIR"/.mmry-waiting-* "$TEST_TMPDIR"/.mmry-asking-*; : > "$BODIES"; : > "$URLS"
    _timed _waiting "$(_codex_ask Bash "" '{"command":"git status"}')"; base=$TOOK
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"; : > "$URLS"
    in='{"command":"git push origin '"$pad"' --force"}'
    _timed _waiting "$(_codex_ask Bash "" "$in")"
    raised="$(_puts)"
    echo "# K-08 Codex, a ${#in} byte tool_input: ${TOOK} s (one word: ${base} s), raised ${raised}" >&3
    _inside_budget "$TOOK" "$base" "the Codex raise" || return 1
    if [ "$raised" -eq 1 ]; then
        [ "$(_sent programName)" = "git" ] && [ "$(_sent programAction)" = "push" ] || { head -c 300 "$BODIES"; return 1; }
    else
        [ "$raised" -eq 0 ] || { cat "$URLS"; return 1; }
    fi
    [ "$(wc -c < "$BODIES" | tr -d ' ')" -lt 400 ] || { echo "the body sent is $(wc -c < "$BODIES") bytes"; return 1; }
    ! grep -q -e origin -e force -e 0000000000 "$BODIES" || { echo "part of the command was sent"; return 1; }

    # Claude Code: the PermissionRequest hook writes the ask record, the Notification raises.
    rm -f "$TEST_TMPDIR"/.mmry-waiting-* "$TEST_TMPDIR"/.mmry-asking-*; : > "$BODIES"; : > "$URLS"
    _timed _ask "$(_cc_ask_in Bash "" '{"command":"git status"}')"; base=$TOOK
    rm -f "$TEST_TMPDIR"/.mmry-asking-*
    in='{"command":"node -e \"'"$pad"'\""}'
    _timed _ask "$(_cc_ask_in Bash "" "$in")"
    echo "# K-08 Claude Code ask, a ${#in} byte tool_input: ${TOOK} s (one word: ${base} s)" >&3
    _inside_budget "$TOOK" "$base" "the Claude Code ask" || return 1
    _waiting "$(_notification permission_prompt "$SAID")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    echo "# K-08 Claude Code raise sent program [$(_sent programName)] action [$(_sent programAction)]" >&3
    case "$(_sent programName)|$(_sent programAction)" in
        "node|inline"|"<none>|<none>") ;;
        *) head -c 300 "$BODIES"; return 1 ;;
    esac
    [ "$(wc -c < "$BODIES" | tr -d ' ')" -lt 400 ] || { echo "the body sent is $(wc -c < "$BODIES") bytes"; return 1; }
    [ "$(cat "$TEST_TMPDIR"/.mmry-* 2>/dev/null | wc -c | tr -d ' ')" -lt 2000 ] || { echo "local state grew with the command"; return 1; }
    ! grep -q 0000000000 "$BODIES" "$TEST_TMPDIR"/.mmry-* 2>/dev/null || { echo "part of the command was sent or kept"; return 1; }
}

# A command of a few thousand bytes, which every platform's payload read finishes: raised, with its action.
@test "K-08b 34651 R1: a 3 KB command is raised with its action on both hosts, and none of its text" {
    local h pad
    pad="$(printf '%0*d' 3000 0)"
    for h in claude codex; do
        _prompt "$h" "git push origin $pad --force" || return 1
        _expect "$h" git push || return 1
        _never "$h" origin 0000000000 force || return 1
    done
}

# ---- K-09: the grammar alone ---------------------------------------------------------------------------

# The jq program that derives the action, read out of the handler (the assignment runs from its own
# line to the first line ending in a single quote), so the grammar is pinned apart from the shell's
# second check of what it gives. Prints "<program>|<action>" for a shell tool's command.
_grammar() { # $1 command, $2 tool name (Bash by default)
    local _MMRY_WAITING_ACTION_JQ="" _MMRY_WAITING_SUBCOMMANDS="" _MMRY_WAITING_INTERPRETERS=""
    # The two closed lists first (one line each), then the program that embeds them.
    eval "$(grep -E "^_MMRY_WAITING_(SUBCOMMANDS|INTERPRETERS)='[a-z0-9 =;-]*'\$" "$HH/formation-waiting.sh")"
    eval "$(sed -n "/^_MMRY_WAITING_ACTION_JQ='/,/'\$/p" "$HH/formation-waiting.sh")"
    [ -n "$_MMRY_WAITING_ACTION_JQ" ] || { echo "NO-GRAMMAR"; return 0; }
    printf '%s' "$1" | "$JQ_BIN" -cRs --arg t "${2:-Bash}" '{tool_name: $t, tool_input: {command: .}}' \
        | "$JQ_BIN" -r "$_MMRY_WAITING_ACTION_JQ" | tr -d '\r'
}

@test "K-09 34651 R1 R2: the grammar, row by row: only a subcommand word, script and a file name, or inline ever comes out" {
    [ "$(_grammar "git push")" = "push" ] || { echo "the grammar could not be read out of the handler: [$(_grammar "git push")]"; return 1; }
    local n24="abcdefghijklmnopqrstuvwx" f60 row cmd want got bad=""
    f60="$(printf '%060d' 0)"
    while IFS='|' read -r cmd want; do
        [[ -n "$cmd" ]] || continue
        got="$(_grammar "$cmd")"
        [[ "$got" == "$want" ]] || bad+=$'\n'"  [$cmd] gave [$got], wanted [$want]"
    done <<ROWS
git push|push
git status --short|status
gh pr view 12|pr
dotnet test --filter Name~X|test
npm run build|run
pnpm install|install
yarn add left-pad|add
yarn deploy-prod|
docker compose up|compose
kubectl get pods|get
az login|login
cargo build|build
go test ./...|test
pip install requests|install
winget install x|install
brew upgrade|upgrade
/usr/bin/git status|status
  git   fetch origin|fetch
git|
git Push|
git PUSH|
git 1st|
git push;rm|
git push&&rm|
git "push"|
git 'push'|
git \$(whoami)|
git push=1|
git ${n24}|
git ${n24}y|
git inline|
git script|
git deadbeefcafe|
git pushx|
git pus|
npm secretx1a2b3|
docker abcdef0123456789|
npm push|
git install|
gh auth login --with-token x|auth
env TOKEN=x git push|
sudo git push|
cmd /c git push|
dotnet --roll-forward x test|
git commit -m secretmessage|commit
git -C dir push|
git --git-dir=x push|
cat push|
curl script x.sh|
ls -la|
rm -rf build|
bash check.sh|script check.sh
bash -x scripts/a.sh one two|script a.sh
bash ./deploy.sh|script deploy.sh
sh run.bash|script run.bash
node a/b/c.js --port 1|script c.js
node run.mjs -e x|script run.mjs
node lib.cjs|script lib.cjs
node build.ts|script build.ts
python manage.py migrate|script manage.py
python3 -u tools/x.py|script x.py
pwsh -NoProfile -File sql/prod_108.ps1 -VerifyOnly|script prod_108.ps1
powershell -File x.ps1|script x.ps1
bash -C x.sh|script x.sh
bash scripts/noext|
bash a.txt|
bash a.sh.bak|
bash ./deploy.sh.|
bash "scripts/a b.sh"|
node "C:/a/run.mjs"|
bash a=b.sh|
bash -o pipefail x.sh|
python3 -m pytest t.py|
node ${f60}a.js|script ${f60}a.js
node ${f60}ab.js|
node -e code|inline
node --eval code|inline
bash -c ls|inline
sh -c ls|inline
python -c pass|inline
python3 -c pass|inline
pwsh -c ls|inline
pwsh -Command ls|inline
powershell -Command ls|inline
pwsh -NoProfile -Command ls|
node -p code|
bash -lc ls|
node --evaluate x|
cat -e x|
git -e x|
ROWS
    [ -z "$bad" ] || { echo "the grammar gave:$bad"; return 1; }
    # Never from a tool that is not a shell tool, whatever its arguments are called.
    [ "$(_grammar "git push" mcp__probe__run)" = "" ] || { echo "an MCP tool's argument gave an action"; return 1; }
    [ "$(_grammar "git push" Write)" = "" ] || return 1
    # A backslash path (Windows), given to jq as data.
    [ "$(_grammar 'node C:\a\b\run.mjs')" = "script run.mjs" ] || { echo "backslash path: [$(_grammar 'node C:\a\b\run.mjs')]"; return 1; }
    [ "$(_grammar 'C:\tools\git push')" = "push" ] || return 1
}

# ---- K-10..13: the local ask record, and older shapes --------------------------------------------------

# An ask record as --ask writes it, with the action line given.
_asked() { # $1 program, $2 the whole action line's value
    printf 'asker -\ntool Bash\ninput -\napprove -\nprogram %s\naction %s\nat %s\n' "$1" "$2" "$(date +%s)" > "$TEST_TMPDIR/.mmry-asking-$SID"
}

@test "K-10 34651 R2 guard: an ask record whose action is outside the vocabulary sends the program and no action" {
    local a
    for a in "push origin" "script scripts/a.sh" "script a.sh --flag" "inline code" "Push" "push/main" "$PLANTED" \
             "secretx1a2b3" "install" "inline" "script check.sh"; do
        rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"; : > "$URLS"
        _asked git "$a"
        _waiting "$(_notification permission_prompt "$SAID")"
        [ "$(_puts)" -eq 1 ] || { echo "not raised for [$a]"; return 1; }
        [ "$(_sent programName)" = "git" ] || { echo "for [$a]"; cat "$BODIES"; return 1; }
        [ "$(_sent programAction)" = "<none>" ] || { echo "the record's [$a] was sent as [$(_sent programAction)]"; return 1; }
    done
    # And a record inside the vocabulary is sent as it stands.
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    _asked bash "script check.sh"
    _waiting "$(_notification permission_prompt "$SAID")"
    [ "$(_sent programAction)" = "script check.sh" ] || { cat "$BODIES"; return 1; }
}

@test "K-11 34651 R2 guard: an action never goes without its program" {
    _asked - push
    _waiting "$(_notification permission_prompt "$SAID")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_sent programName)" = "<none>" ] && [ "$(_sent programAction)" = "<none>" ] || { cat "$BODIES"; return 1; }
    # A program that is not a bare name takes its action with it.
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    _asked "git/x" push
    _waiting "$(_notification permission_prompt "$SAID")"
    [ "$(_sent programName)" = "<none>" ] && [ "$(_sent programAction)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

@test "K-12 34651 R1: a Claude Code helper's request, raised from the ask, carries the action; the ask prints nothing" {
    : > "$TEST_TMPDIR/state-seen"
    run _ask "$(_cc_ask_in Bash "$BG" "$(_input "git push origin main --force")")"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "printed (Claude Code reads it as a decision): $output"; return 1; }
    _snap
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    _expect helper git push || return 1
    _never helper origin main --force || return 1
}

@test "K-13 34651 guard: a record with no action line, and a prompt with no record, still raise as #34519 does" {
    printf 'asker -\ntool Bash\ninput -\napprove -\nprogram git\nat %s\n' "$(date +%s)" > "$TEST_TMPDIR/.mmry-asking-$SID"
    _waiting "$(_notification permission_prompt "$SAID")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_sent programName)" = "git" ] && [ "$(_sent programAction)" = "<none>" ] || { cat "$BODIES"; return 1; }
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"; : > "$URLS"
    _waiting "$(_notification permission_prompt "$SAID")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_sent programName)" = "<none>" ] && [ "$(_sent programAction)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

# ---- K-14, K-15: the closed per-tool list ---------------------------------------------------------------

@test "K-14 34651 R2: a lowercase word that is not a known subcommand of its tool is never sent, on either host" {
    local h c
    for h in claude codex; do
        for c in "npm secretx1a2b3" "docker abcdef0123456789" "git deadbeefcafe" "yarn deploy-secretname"; do
            _prompt "$h" "$c" || return 1
            _expect "$h" "${c%% *}" "<none>" || { echo "for [$c]"; return 1; }
            _never "$h" "${c#* }" || { echo "for [$c]"; return 1; }
        done
        _prompt "$h" "gh auth login --with-token $PLANTED" || return 1
        _expect "$h" gh auth || return 1
        _never "$h" login with-token "$PLANTED" || return 1
    done
}

@test "K-15 34651: the closed lists are the service's, word for word (FormationWaitingActions.cs)" {
    if [[ -z "${MMRY_SERVICE_REPO:-}" ]]; then
        skip "MMRY_SERVICE_REPO is not set; set it to a checkout of MMRY-AI/mmry to compare the service"
    fi
    local cs="${MMRY_SERVICE_REPO}/src/Mnemo.Api/Services/FormationWaitingActions.cs" subs ints
    [ -f "$cs" ] || { echo "not found: $cs"; return 1; }
    subs="$(grep -E "^_MMRY_WAITING_SUBCOMMANDS='[a-z0-9 =;-]*'\$" "$HH/formation-waiting.sh")"
    ints="$(grep -E "^_MMRY_WAITING_INTERPRETERS='[a-z0-9 ]*'\$" "$HH/formation-waiting.sh")"
    subs="${subs#*=\'}"; subs="${subs%\'}"
    ints="${ints#*=\'}"; ints="${ints%\'}"
    [ -n "$subs" ] && [ -n "$ints" ] || { echo "the lists were not read out of the handler"; return 1; }
    grep -q -F -- "\"${subs}\"" "$cs" || { echo "the service's subcommand list differs from the plugin's"; return 1; }
    grep -q -F -- "\"${ints}\"" "$cs" || { echo "the service's interpreter list differs from the plugin's"; return 1; }
}
