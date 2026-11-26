#!/usr/bin/env bats
# member-permissions-codex-sample.bats - #34651 requirement 4 (Codex parity, DD-207 in MMRY-AI/mmry):
# the plugin ships a Codex form of the permission sample, mmry/examples/member-permissions.codex.rules,
# beside the Claude Code one. Like that one it is documentation: nothing in the plugin may read,
# install or apply it (DD-187: a product default never widens anyone's permissions).
#
#   C-01  the sample exists and is headed by the sample sentence, and every rule has a pattern and one of
#         Codex's three decisions.
#   C-02  the allow rules hold only commands whose every continuation is a read (git status, git rev-parse):
#         nothing that pushes, resets, deletes, prints a file, sets configuration or runs a program.
#   C-03  where Codex is installed, `codex execpolicy check` decides each command in the table below as
#         stated (allowed, asks, refused, or no decision). Skipped where Codex is not installed (CI).
#   C-04  the sample is never applied: nothing the plugin runs or tells an assistant names it.

HEADER="# Sample only. MMRY AI never applies this file. Copy the rules you want into your own Codex rules file, review each one, and leave commands that delete files, force-push or read secrets out of the allow rules."

setup() {
    ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SAMPLE="${ROOT}/examples/member-permissions.codex.rules"
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

@test "C-01 34651 R4 Codex: the sample exists, is headed by the sample sentence, and every rule has a pattern and a decision" {
    [ -f "$SAMPLE" ] || { echo "no Codex sample at $SAMPLE"; return 1; }
    [ "$(head -1 "$SAMPLE" | tr -d '\r')" = "$HEADER" ] || { echo "the first line is not the sample sentence: $(head -1 "$SAMPLE")"; return 1; }
    local rules patterns decisions bad
    rules="$(grep -c '^prefix_rule($' "$SAMPLE")"
    patterns="$(grep -c '^    pattern = \[' "$SAMPLE")"
    decisions="$(grep -Ec '^    decision = "(allow|prompt|forbidden)",$' "$SAMPLE")"
    [ "$rules" -gt 0 ] && [ "$rules" = "$patterns" ] && [ "$rules" = "$decisions" ] || { echo "rules $rules, patterns $patterns, decisions $decisions"; return 1; }
    # No other decision word, and no em or en dash, curly quote or tab anywhere in the file.
    bad="$(grep -n 'decision = ' "$SAMPLE" | grep -Ev 'decision = "(allow|prompt|forbidden)",$' || true)"
    [ -z "$bad" ] || { echo "$bad"; return 1; }
    ! LC_ALL=C grep -nP '\xe2\x80[\x93\x94\x98\x99\x9c\x9d]|\t' "$SAMPLE" || { echo "a dash, curly quote or tab is in the sample"; return 1; }
}

@test "C-02 34651 R4 Codex: the allow rules hold only reads whose every continuation is a read" {
    local allow
    # The pattern line of every rule whose decision is allow.
    allow="$(awk '/^    pattern = /{p=$0} /^    decision = "allow",$/{print p}' "$SAMPLE")"
    [ -n "$allow" ] || { echo "no allow rule at all"; return 1; }
    [ "$allow" = '    pattern = ["git", ["status", "rev-parse"]],' ] || { echo "the allow rules changed; each new one needs a reason it can never write, read a chosen file or run a program:"; echo "$allow"; return 1; }
    ! grep -Eq 'push|reset|rm|-c|config|log|diff|show|fetch|cat|npm|dotnet|pytest|add' <<< "$allow" || return 1
}

# Each line: the decision Codex must give, a tab, then the command's words.
_table() {
    cat <<'EOF'
allow	git status
allow	git status --short
allow	git rev-parse HEAD
prompt	git log
prompt	git log --output=out.txt
prompt	git diff --no-index a.txt b.txt
prompt	git show HEAD
prompt	git fetch --upload-pack=prog origin
prompt	git push
prompt	git push origin feature --force
prompt	git -C some/dir push --force
prompt	git -C some/dir status
prompt	git --no-pager log
prompt	cat .secrets/key.json
forbidden	git push --force
forbidden	git push -f
forbidden	git push --force-with-lease
forbidden	git push origin --force
forbidden	git push -u origin --force
forbidden	git push origin main --force
forbidden	git push origin +main
forbidden	git push --mirror
forbidden	git reset --hard
forbidden	git reset HEAD~1 --hard
forbidden	git -c core.fsmonitor=prog status
forbidden	git --no-pager -c core.pager=prog log
forbidden	git submodule foreach echo
forbidden	rm -rf build
forbidden	rm -r -f build
forbidden	rm -f -r build
none	ls
none	npm test
none	pytest
none	git add -A
EOF
}

@test "C-03 34651 R4 Codex: codex execpolicy check decides every command in the table as stated" {
    command -v codex >/dev/null 2>&1 || skip "Codex is not installed here; C-01 and C-02 still check the text"
    local want cmd out got failed=0 checked=0
    while IFS=$'\t' read -r want cmd; do
        [ -n "$want" ] || continue
        local -a words
        read -ra words <<< "$cmd"
        out="$(codex execpolicy check --rules "$SAMPLE" "${words[@]}" 2>&1 | tr -d '\r')"
        got="$("$JQ" -r '.decision // "none"' <<< "$out" 2>/dev/null | tr -d '\r')"
        checked=$((checked + 1))
        if [ "$got" != "$want" ]; then
            echo "WRONG: '$cmd' gave '$got', expected '$want' (codex said: $out)"
            failed=$((failed + 1))
        fi
    done < <(_table)
    echo "checked $checked commands, $failed wrong"
    [ "$checked" -eq 34 ] || { echo "the table was not read in full"; return 1; }
    [ "$failed" -eq 0 ]
}

@test "C-04 34651 R4 Codex: the sample is never applied: nothing the plugin runs or tells an assistant names it" {
    local hits
    hits="$(grep -rIl -e 'member-permissions' -e 'examples/' "$ROOT" \
            --exclude-dir=tests --exclude-dir=examples --exclude-dir=vendor --exclude-dir=.git \
            --exclude=release-files.txt 2>/dev/null || true)"
    [ -z "$hits" ] || { echo "these files name the sample or its folder:"; echo "$hits"; return 1; }
    [[ "$SAMPLE" != *"/.codex/"* && "$SAMPLE" != *"/rules/"* && "$SAMPLE" != *"/hooks/"* ]] || return 1
}
