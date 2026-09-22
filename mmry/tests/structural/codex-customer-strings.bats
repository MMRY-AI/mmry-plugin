#!/usr/bin/env bats
# codex-customer-strings.bats — THE LIST OF BAD STRINGS IS COMPLETE, NOT MERELY LONG
# (#31245 QA round 6).
#
# WHY THIS FILE EXISTS. Four rounds of QA have failed this task on the same defect: a
# customer-facing string that names a command the customer cannot type, or the other product's
# config file. Each round, the strings somebody looked at were fixed and the ones beside them
# shipped:
#
#   round 3  session-start.sh's reauth hint, "the last line in the file still naming a Claude Code
#            slash command unconditionally, three host-branched messages after the others"
#   round 4  userpromptsubmit-foundation.sh's UNCONFIGURED branch — leaving the CONFIGURED branch,
#            three lines below it, naming /mmry:load-memories and ~/.claude/mmry-config.json
#   round 5  twenty strings in the four formation handlers "a Codex customer can already reach",
#            scoped deliberately, leaving thirty-odd in the other nine
#   round 6  those thirty-odd, plus the client's two credential messages and visibility.sh
#
# Every one of those was found by a human reading files. This file is the mechanism that makes
# that unnecessary, and it is built on two nets rather than one, because either alone has a hole
# a previous round has already fallen through.
#
# ---------------------------------------------------------------------------------------------
# NET 1 — THE STATIC SWEEP, OVER THE EXACT SET OF FILES A CODEX INSTALL CONTAINS.
#
# The scope is not a judgement call and is not a list maintained by hand. session-init.sh copies
# hooks-handlers/*.sh, hooks-handlers/*.cmd, setup/*.sh, setup/*.bat and setup/*.ps1 into the host
# directory, wholesale (see its "Copy current handler and setup scripts" block). So the set of
# files that can put a string in front of a Codex customer IS that glob, evaluated against the
# filesystem here. Round 5's scoping argument — "only the four handlers a Codex customer can
# already reach" — is the thing this deletes: every handler is reachable, because every handler is
# installed, and the model is told in skills-codex to run them by absolute path.
#
# Within that set, every non-comment line naming a slash command or the other product's config
# path must appear in ALLOWED below, with a reason. The allowlist is the completeness argument:
# it cannot grow without somebody editing this file and writing down why.
#
# ---------------------------------------------------------------------------------------------
# NET 2 — THE DYNAMIC SWEEP, WHICH ASSERTS PRESENCE AND NOT ONLY ABSENCE.
#
# A static sweep cannot tell a message from a comparison, and a sweep that only looks for the
# ABSENCE of "/mmry:" is satisfied by a handler that says nothing at all — QA round 6 demonstrated
# exactly that against the round-5 sweep, by replacing four handlers with an immediate exit and
# watching the test stay green. So net 2 runs each handler TWICE, once per host, with identical
# arguments, and DERIVES what it expects from the Claude run:
#
#     N = the number of commands the Claude Code output names
#     the Codex output must name ZERO slash commands and EXACTLY N runnable scripts,
#     and every script it names must exist on disk
#
# A handler that stops printing its remedy fails, because N is still N on the Claude side and the
# Codex side now has 0. A handler that prints a plausible-looking path to a file that is not there
# fails. A handler that names the wrong NUMBER of commands fails. There is no way to satisfy this
# by going quiet, which was the hole.

setup() {
    PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
    HANDLERS="${PLUGIN_ROOT}/hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-custstr-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true

    # A Codex home that is NOT the default, because the customer this feature exists for is the one
    # who moved it, and a message built from a hardcoded "~/.codex" would pass against the default.
    CODEX_DIR="${BATS_TEST_TMPDIR}/codexhome"
    mkdir -p "${CODEX_DIR}/mmry"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------
# The installed file set, read off session-init.sh's own copy globs rather than restated.
_installed_files() {
    local f
    for f in "$PLUGIN_ROOT"/hooks-handlers/*.sh \
             "$PLUGIN_ROOT"/hooks-handlers/*.cmd \
             "$PLUGIN_ROOT"/setup/*.sh \
             "$PLUGIN_ROOT"/setup/*.bat \
             "$PLUGIN_ROOT"/setup/*.ps1; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
}

# Emitting lines only: a comment cannot reach a customer. Shell comments, batch REM and ::.
_emitting_hits() {
    local f="$1"
    awk '
        { line = $0; sub(/^[ \t]+/, "", line)
          if (line ~ /^#/) next
          if (line ~ /^(rem|REM|::)/) next
          if ($0 ~ /\/mmry:/ || $0 ~ /\.claude\/mmry-config\.json/ || $0 ~ /~\/\.claude/)
              printf "%d\t%s\n", NR, $0
        }' "$f"
}

# ---------------------------------------------------------------------------------------------
# THE ALLOWLIST. Keyed by "<basename> <exact trimmed line>". Every entry names a reason, and the
# reasons are of exactly three kinds:
#
#   (D) it IS the derivation — the one place allowed to spell a command out
#   (F) it is the FALLBACK inside a `declare -F` guard, taken only when lib-host.sh is absent, in
#       which case the literal is what the file printed before #31245 (requirement 4's floor)
#   (B) it is the CLAUDE BRANCH of a host conditional, unreachable on Codex
#   (R) it is in a file that REFUSES to run on Codex before reaching the line
#   (N) it is not a message at all — a path comparison or a discovery branch
_allowed_reason() {
    local base="$1" line="$2"
    case "${base}|${line}" in
        # (D) lib-host.sh is the single derivation. These two lines are the Claude answers.
        "lib-host.sh|printf '/mmry:formation %s%s' \"\$sub\" \"\$rest\"")         printf 'D'; return 0 ;;
        "lib-host.sh|printf '/mmry:%s%s' \"\$cmd\" \"\$rest\"")                   printf 'D'; return 0 ;;
        # (D) and the plugin-root recovery remedy, whose Claude answer is develop's own literal.
        "lib-host.sh|printf '/mmry:setup'")                                       printf 'D'; return 0 ;;

        # (F) fallbacks behind `declare -F` guards, for the curated-copy case hook-guard.sh documents.
        "mmry-client.sh|printf '/mmry:setup'")                                    printf 'F'; return 0 ;;
        "userpromptsubmit-foundation.sh|_FOUND_RELOAD_REF='/mmry:load-memories'") printf 'F'; return 0 ;;
        "userpromptsubmit-foundation.sh|_FOUND_CONFIG_REF='~/.claude/mmry-config.json'") printf 'F'; return 0 ;;
        "lib-jq.sh|echo \"  bash ~/.claude/mmry/setup/mmry-setup.sh\"")           printf 'F'; return 0 ;;

        # (B) the Claude branch of an if/else on mmry_host.
        "session-start.sh|help_line='Mention /mmry:help for a quick reference.'") printf 'B'; return 0 ;;
        "session-start.sh|_mmry_report_hint=\"ask them to report it with /mmry:feedback\"") printf 'B'; return 0 ;;
        "session-start.sh|_mmry_reauth_hint=\"run /mmry:setup\"")                 printf 'B'; return 0 ;;
        "session-start.sh|_mmry_onboard_hint=\"they can always say remember this to save something new, or /mmry:help for a quick reference\"") printf 'B'; return 0 ;;
        "mmry-setup.sh|echo \"Anytime you need help, type: /mmry:help\"")         printf 'B'; return 0 ;;

        # (R) both uninstallers refuse outright on Codex; see their header blocks.
        "uninstall.sh|echo \"  Removed ~/.claude/mmry/\"")                        printf 'R'; return 0 ;;
        "uninstall.bat|\"  Write-Host '  Removed ~/.claude/mmry/'\" ^")           printf 'R'; return 0 ;;

        # (N) credential DISCOVERY, not a message. lib-host.sh points MMRY_CONFIG_FILE at the right
        #     file ahead of these, and refuses rather than letting the chain reach them on Codex.
        "mmry-client.sh|elif [[ -f \"\${HOME}/.claude/mmry-config.json\" ]]; then") printf 'N'; return 0 ;;
        "mmry-client.sh|config_file=\"\${HOME}/.claude/mmry-config.json\"")        printf 'N'; return 0 ;;
        "userpromptsubmit-foundation.sh|elif [[ -f \"\${HOME:-}/.claude/mmry-config.json\" ]]; then") printf 'N'; return 0 ;;
        "userpromptsubmit-foundation.sh|cfg=\"\${HOME}/.claude/mmry-config.json\"") printf 'N'; return 0 ;;
    esac
    return 1
}

@test "sweep: no installed file names a command or the other product's config file undeclared" {
    local f base hits lineno text trimmed unexplained="" count=0
    while IFS= read -r f; do
        base="$(basename "$f")"
        hits="$(_emitting_hits "$f")"
        [[ -n "$hits" ]] || continue
        while IFS=$'\t' read -r lineno text; do
            [[ -n "$lineno" ]] || continue
            # STRIP THE CARRIAGE RETURN BEFORE ANYTHING COMPARES THE LINE (#31245, 2026-09-21).
            #
            # .gitattributes pins *.bat to CRLF, deliberately, because that is what a Windows
            # customer must receive. So every line read out of uninstall.bat ends in a CR, and an
            # allowlist key written by hand does not. The key could therefore never match the
            # file as SHIPPED, on any platform.
            #
            # It looked green on Windows only because this worktree still held a stale LF copy of
            # uninstall.bat from before the attribute was added: git does not re-normalise files
            # already in the working tree. A fresh clone on Debian 12 failed immediately, which is
            # how this was found, and a fresh clone on Windows would have failed the same way.
            text="${text%$'\r'}"
            trimmed="${text#"${text%%[![:space:]]*}"}"
            count=$((count + 1))
            _allowed_reason "$base" "$trimmed" >/dev/null || \
                unexplained="${unexplained}
  ${base}:${lineno}: ${trimmed}"
        done <<< "$hits"
    done < <(_installed_files)

    # The sweep must have found SOMETHING, or a broken scanner reads as a clean bill of health.
    # That is how a green suite has twice been reported against a file full of bad strings.
    [ "$count" -gt 0 ]

    [ -z "$unexplained" ] || {
        echo "these lines name a slash command or ~/.claude and are not in the allowlist:${unexplained}" >&2
        echo "" >&2
        echo "Derive them with mmry_host_command_ref / mmry_host_formation_ref /" >&2
        echo "mmry_host_config_file_ref, or add an entry to _allowed_reason with a reason." >&2
        return 1
    }
}

@test "sweep: the scanner is looking at the whole installed set, not a corner of it" {
    # A scope this test gets wrong is a scope nobody notices, because the result looks the same:
    # green. So the file set is asserted to contain the files each previous round's defect lived
    # in, and to be the size of the real handler directory.
    local files n
    files="$(_installed_files)"
    n="$(printf '%s\n' "$files" | grep -c . )"
    [ "$n" -ge 35 ]
    printf '%s\n' "$files" | grep -q 'hooks-handlers/userpromptsubmit-foundation.sh$'   # round 4 + 6
    printf '%s\n' "$files" | grep -q 'hooks-handlers/mmry-client.sh$'                   # round 6
    printf '%s\n' "$files" | grep -q 'hooks-handlers/visibility.sh$'                    # round 6
    printf '%s\n' "$files" | grep -q 'hooks-handlers/session-start.sh$'                 # round 3
    printf '%s\n' "$files" | grep -q 'hooks-handlers/formation-progress.sh$'            # round 6
    printf '%s\n' "$files" | grep -q 'setup/mmry-setup.sh$'
}

@test "sweep: every allowlist entry is still a real line, so the list cannot rot into fiction" {
    # An allowlist entry whose line no longer exists is a permission granted to nothing, and it is
    # how the next genuine occurrence of that text gets waved through. The five stale mutation
    # patterns this same round had to repair are the same failure in a different file.
    local f base hits present="" lineno text trimmed
    while IFS= read -r f; do
        base="$(basename "$f")"
        hits="$(_emitting_hits "$f")"
        [[ -n "$hits" ]] || continue
        while IFS=$'\t' read -r lineno text; do
            [[ -n "$lineno" ]] || continue
            text="${text%$'\r'}"
            trimmed="${text#"${text%%[![:space:]]*}"}"
            present="${present}
${base}|${trimmed}"
        done <<< "$hits"
    done < <(_installed_files)

    # Every key _allowed_reason recognises must be somewhere in `present`. The keys are listed
    # here rather than parsed out of the case statement, because a test that reads its subject's
    # source to decide what to assert agrees with it by construction.
    local k missing=""
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        printf '%s' "$present" | grep -Fqx "$k" || missing="${missing}
  ${k}"
    done <<'KEYS'
lib-host.sh|printf '/mmry:formation %s%s' "$sub" "$rest"
lib-host.sh|printf '/mmry:%s%s' "$cmd" "$rest"
lib-host.sh|printf '/mmry:setup'
mmry-client.sh|printf '/mmry:setup'
userpromptsubmit-foundation.sh|_FOUND_RELOAD_REF='/mmry:load-memories'
userpromptsubmit-foundation.sh|_FOUND_CONFIG_REF='~/.claude/mmry-config.json'
lib-jq.sh|echo "  bash ~/.claude/mmry/setup/mmry-setup.sh"
session-start.sh|help_line='Mention /mmry:help for a quick reference.'
session-start.sh|_mmry_report_hint="ask them to report it with /mmry:feedback"
session-start.sh|_mmry_reauth_hint="run /mmry:setup"
session-start.sh|_mmry_onboard_hint="they can always say remember this to save something new, or /mmry:help for a quick reference"
mmry-setup.sh|echo "Anytime you need help, type: /mmry:help"
uninstall.sh|echo "  Removed ~/.claude/mmry/"
mmry-client.sh|elif [[ -f "${HOME}/.claude/mmry-config.json" ]]; then
mmry-client.sh|config_file="${HOME}/.claude/mmry-config.json"
userpromptsubmit-foundation.sh|elif [[ -f "${HOME:-}/.claude/mmry-config.json" ]]; then
userpromptsubmit-foundation.sh|cfg="${HOME}/.claude/mmry-config.json"
KEYS

    [ -z "$missing" ] || {
        echo "these allowlist entries no longer match any line, and must be deleted:${missing}" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# NET 2 — the dynamic sweep. Expectation derived from the Claude run, so silence cannot pass.

_env_common=(MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL=http://fake.invalid)

# Count occurrences of a fixed string.
_count() { printf '%s' "$1" | grep -o -F "$2" | grep -c . || true; }

# Run one handler on both hosts with identical arguments and hold both to the derived rule.
_compare_hosts() {
    local script="$1"; shift

    local claude_out codex_out
    claude_out="$(env "${_env_common[@]}" CLAUDE_SESSION_ID="$CLAUDE_SESSION_ID" \
        bash "$script" "$@" 2>&1 || true)"
    codex_out="$(env "${_env_common[@]}" CLAUDE_SESSION_ID="$CLAUDE_SESSION_ID" \
        MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" \
        bash "$script" "$@" 2>&1 || true)"

    local n_claude n_codex_slash n_codex_runnable
    n_claude="$(_count "$claude_out" '/mmry:')"
    n_codex_slash="$(_count "$codex_out" '/mmry:')"
    n_codex_runnable="$(_count "$codex_out" "bash ${CODEX_DIR}/mmry/")"

    # Nothing to compare if the Claude path names no command; such a message has no defect to have.
    if [[ "$n_claude" -eq 0 ]]; then
        [[ "$n_codex_slash" -eq 0 ]] || {
            echo "$(basename "$script"): Codex names a slash command the Claude path does not" >&2
            return 1
        }
        return 0
    fi

    [[ "$n_codex_slash" -eq 0 ]] || {
        echo "$(basename "$script"): ${n_codex_slash} slash command(s) survive on Codex:" >&2
        printf '%s\n' "$codex_out" >&2
        return 1
    }

    # THE ASSERTION OF PRESENCE. Derived from the Claude output, so a handler that fixes this by
    # saying nothing fails here rather than passing.
    [[ "$n_codex_runnable" -eq "$n_claude" ]] || {
        echo "$(basename "$script"): Claude names ${n_claude} command(s), Codex names ${n_codex_runnable} runnable one(s)." >&2
        echo "  claude: ${claude_out}" >&2
        echo "  codex:  ${codex_out}" >&2
        return 1
    }

    # And every script the Codex message names is really there. A remedy pointing at
    # formation-rooster.sh reads perfectly plausibly in a diff and helps nobody.
    local named f
    named="$(printf '%s' "$codex_out" | grep -o "${CODEX_DIR}/mmry/[A-Za-z0-9./_-]*" | sort -u)"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        # Sentence punctuation is not part of a path. These messages end in "." far more often
        # than not, and a check that fails on the full stop is a check nobody can read.
        f="${f%%[.,;:)]}"
        local rel="${f#"${CODEX_DIR}/mmry/"}"
        [[ -f "${PLUGIN_ROOT}/${rel}" ]] || {
            echo "$(basename "$script"): message names ${rel}, which does not exist" >&2
            return 1
        }
    done <<< "$named"
    return 0
}

@test "hosts: every formation handler hands each host a command that host can use" {
    # Enumerated from the filesystem. A handler added tomorrow is covered without anyone
    # remembering to add a case here — which is how the round-5 scope left nine behind.
    local f base op failures=""
    for f in "$PLUGIN_ROOT"/hooks-handlers/formation-*.sh; do
        base="$(basename "$f")"
        op="${base#formation-}"; op="${op%.sh}"
        case "$op" in state|check) continue ;; esac
        _compare_hosts "$f" || failures="${failures} ${op}"
        _compare_hosts "$f" "not-a-number" || failures="${failures} ${op}(bad-arg)"
    done
    [ -z "$failures" ] || {
        echo "handlers whose two hosts disagree:${failures}" >&2
        return 1
    }
}

@test "hosts: and the sweep above is really seeing commands, not an empty transcript" {
    # The control for the control. If the Claude runs named nothing at all, every comparison above
    # is vacuous and the file is decoration. Count what the sweep actually had to check.
    local f base op total=0 n out
    for f in "$PLUGIN_ROOT"/hooks-handlers/formation-*.sh; do
        base="$(basename "$f")"
        op="${base#formation-}"; op="${op%.sh}"
        case "$op" in state|check) continue ;; esac
        out="$(env "${_env_common[@]}" CLAUDE_SESSION_ID="$CLAUDE_SESSION_ID" bash "$f" 2>&1 || true)"
        n="$(_count "$out" '/mmry:')"
        total=$((total + n))
    done
    # Nine of the eleven print a remedy on their no-argument path; the real figure at round 6 is
    # well above this floor, which is set low enough not to break on a wording change.
    [ "$total" -ge 8 ]
}

@test "client: the credential messages name the host's own setup command" {
    local out
    out="$(MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_API_KEY=k MMRY_API_URL=http://fake.invalid \
        bash -c 'source "'"${HANDLERS}"'/mmry-client.sh" >/dev/null 2>&1
                 MMRY_AUTH_METHOD=none MMRY_API_KEY=""
                 _mmry_get_auth_header >/dev/null 2>&1 || true
                 printf "%s" "$MMRY_RESPONSE"' 2>&1)"
    [[ "$out" != *"/mmry:"* ]]
    [[ "$out" == *"bash ${CODEX_DIR}/mmry/setup/mmry-setup.sh"* ]]

    # The Claude control, byte for byte as this message has always read.
    local claude_out
    claude_out="$(MMRY_API_KEY=k MMRY_API_URL=http://fake.invalid \
        bash -c 'source "'"${HANDLERS}"'/mmry-client.sh" >/dev/null 2>&1
                 MMRY_AUTH_METHOD=none MMRY_API_KEY=""
                 _mmry_get_auth_header >/dev/null 2>&1 || true
                 printf "%s" "$MMRY_RESPONSE"' 2>&1)"
    [ "$claude_out" = "No API key configured. Run /mmry:setup to configure your account." ]
}

@test "client: and so does the 401 re-authenticate message" {
    local out
    out="$(MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_API_KEY=k MMRY_API_URL=http://fake.invalid \
        bash -c 'source "'"${HANDLERS}"'/mmry-client.sh" >/dev/null 2>&1
                 MMRY_HTTP_CODE=401 MMRY_RESPONSE=unauthorized
                 _mmry_format_error "save"' 2>&1)"
    [[ "$out" != *"/mmry:"* ]]
    [[ "$out" == *"bash ${CODEX_DIR}/mmry/setup/mmry-setup.sh"* ]]

    local claude_out
    claude_out="$(MMRY_API_KEY=k MMRY_API_URL=http://fake.invalid \
        bash -c 'source "'"${HANDLERS}"'/mmry-client.sh" >/dev/null 2>&1
                 MMRY_HTTP_CODE=401 MMRY_RESPONSE=unauthorized
                 _mmry_format_error "save"' 2>&1)"
    [[ "$claude_out" == *"Run /mmry:setup to re-authenticate."* ]]
}

@test "foundation: the worker-failure notice is covered where its harness lives" {
    # The 725-byte string QA reproduced on a CONFIGURED Codex install hitting the deadline is
    # driven end to end by "a CONFIGURED Codex install past the deadline is told something it can
    # do" in handlers/userpromptsubmit-foundation.bats, which has the slow-jq shim and the config
    # fixtures this file does not. Duplicating it here with a weaker driver would be a test that
    # skips - which reads as coverage and is not. What IS asserted here is that the two literals
    # are gone from the handler's emitting lines, which the static sweep above already does, and
    # that the coverage exists rather than being assumed.
    local f="${BATS_TEST_DIRNAME}/../handlers/userpromptsubmit-foundation.bats"
    [ -f "$f" ]
    grep -q 'CONFIGURED Codex install past the deadline' "$f"
    grep -q "output\" != \*'/mmry:load-memories'" "$f"
    grep -q 'session-start.sh' "$f"
}

@test "refuse: a command with no Codex equivalent gets no invented one" {
    # mmry_host_command_ref must not answer for "help". A plausible path here is the defect this
    # whole mechanism exists to prevent, reintroduced inside the mechanism.
    run env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_ALLOW_NO_CREDENTIAL=1 \
        bash -c 'source "'"${HANDLERS}"'/lib-host.sh"
                 if mmry_host_command_ref help; then echo "answered"; else echo "rc=$?"; fi'
    [ "$output" = "rc=1" ]

    # And on Claude Code it still answers, because there IS a /mmry:help to type.
    run bash -c 'source "'"${HANDLERS}"'/lib-host.sh"; mmry_host_command_ref help'
    [ "$output" = "/mmry:help" ]
}

@test "refuse: load-memories is answered, because it now HAS a Codex surface" {
    # QA round 6 item 2: either give it a surface or list it as a gap. It has one — the same
    # session-start.sh that commands/load-memories.md tells a Claude Code customer to run.
    run env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_ALLOW_NO_CREDENTIAL=1 \
        bash -c 'source "'"${HANDLERS}"'/lib-host.sh"; mmry_host_command_ref load-memories'
    [ "$output" = "bash ${CODEX_DIR}/mmry/hooks-handlers/session-start.sh" ]
    [ -f "${HANDLERS}/session-start.sh" ]

    run bash -c 'source "'"${HANDLERS}"'/lib-host.sh"; mmry_host_command_ref load-memories'
    [ "$output" = "/mmry:load-memories" ]
}

@test "surface: load-memories is documented where a Codex customer and their assistant will find it" {
    # Item 2 again, on the customer-facing side: the substitute has to be findable, not merely to
    # exist. Both Codex surfaces name the script, and the customer page says what it is for.
    local skill="${PLUGIN_ROOT}/skills-codex/memory-system/SKILL.md"
    local page="${PLUGIN_ROOT}/../docs/codex.md"
    grep -q 'hooks-handlers/session-start.sh' "$skill"
    grep -qi 'reloading memories mid-session' "$skill"
    grep -qi 'reload' "$page"
}

@test "config: the file a customer is told to edit is their own host's" {
    run env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_ALLOW_NO_CREDENTIAL=1 \
        bash -c 'source "'"${HANDLERS}"'/lib-host.sh"; mmry_host_config_file_ref'
    [ "$output" = "${CODEX_DIR}/mmry-config.json" ]

    # Requirement 4: the Claude spelling is the literal every message has always carried.
    run bash -c 'source "'"${HANDLERS}"'/lib-host.sh"; mmry_host_config_file_ref'
    [ "$output" = "~/.claude/mmry-config.json" ]
}

@test "setup: an exported MMRY_HOST_ARG is not treated as a typed --host flag" {
    # A value arriving from somewhere nobody expected, deciding which product's account file gets
    # the credential. Same shape as the case-folding defect this script already carries a fix for.
    #
    # THE FIRST VERSION OF THIS TEST COULD NOT FAIL, AND THE MUTATION RUN SAID SO (#31245 QA
    # round 6). It invoked the script with `--help`, which exits at line 14 INSIDE the argument
    # parsing loop - while the MMRY_HOST_ARG validation this is about lives at line 85, seventy
    # lines later. The assertion "no --host refusal was printed" was therefore true of every
    # possible tree, fixed or broken, and experiment 91 SURVIVED against it. It is the exact
    # defect this whole round is about - a check that cannot fail - written by me, into the
    # round that was meant to end them, which is why the note stays here rather than being
    # quietly corrected.
    #
    # IT NOW REACHES THE CODE UNDER TEST. The CI-style arguments carry it past the parse loop,
    # past the validation, and into the login attempt, which is pointed at a closed local port so
    # nothing leaves the machine and the outcome is the same on every box.
    #
    # AND IT ASSERTS PRESENCE, NOT ONLY ABSENCE. "Unrecognised did not appear" is satisfied by a
    # script that dies before it gets there; "Logging in... appeared" is the proof it got past
    # the validation rather than never arriving.
    run env MMRY_HOST_ARG=codx bash "${PLUGIN_ROOT}/setup/mmry-setup.sh" \
        --email a@b.c --password 'Xx1!' --api-url http://127.0.0.1:9
    [[ "$output" != *"Unrecognised --host value"* ]]
    [[ "$output" == *"Logging in"* ]]

    # And the flag itself still refuses, so the fix did not disarm the validation. This half was
    # always sound: --host IS consumed by the parse loop, so it does reach line 85.
    run bash "${PLUGIN_ROOT}/setup/mmry-setup.sh" --host codx
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unrecognised --host value"* ]]
}
