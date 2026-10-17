#!/usr/bin/env bats
# codex-desktop-trust-claim.bats - what shipped text says about MMRY in the Codex desktop app
# (#31245, rewritten for #31790).
#
# HISTORY. v2.10.0's setup told customers to trust MMRY's hooks in the Codex desktop app. UAT on
# 2026-10-06 found the app's hook settings page stalls on "Loading hooks...", so v2.10.1 said that
# trusting the hooks in the desktop app "could not be confirmed in this release".
#
# WHAT IS NOW PROVEN (#31790). On a Mac (app 26.1007.30912, runtime 0.163.0-alpha.10.2, plugin
# 2.10.2 and 2.11.0) MMRY's hooks run in the desktop app: memories load at the start of a
# conversation, Foundation memories are re-stated, and save, search, retire and a directed
# formation message worked. The app's hook settings page still hangs on "Loading hooks..." while
# they run. The hooks were trusted in the Codex CLI review; both read the trust in config.toml in
# the Codex home. The Windows desktop app is not confirmed: MMRY's commands could not reach
# mmryai.com from its sandbox in testing.
#
# THE RULES.
#  1. Any customer-facing text that mentions the desktop app and trust in the same place must send
#     the customer to the Codex CLI review, never to the desktop app's own hook settings page. "The
#     same place" is a line and the lines either side of it, because setup's echo pairs and wrapped
#     Markdown split one sentence across lines.
#  2. That same text must not carry the superseded "could not be confirmed" claim.
#  3. Every customer surface (docs/codex.md, both READMEs, the Codex skill and the setup message)
#     states the proven claim: on a Mac it works, the settings page can hang without stopping MMRY,
#     and Windows is not yet confirmed.
# Shell comment lines are skipped: they are read by maintainers, not printed to customers.

load '../helpers/test-helper'

REPO_ROOT=""

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
}

# Prints "file:line: reason: text" for every offending window in the files given. Empty = clean.
desktop_trust_offenders() {
    local f
    for f in "$@"; do
        awk -v file="$f" '
            {
                is_script = (file ~ /\.(sh|bash|cmd|bat|ps1)$/)
                if (is_script && $0 ~ /^[[:space:]]*(#|::|[Rr][Ee][Mm][[:space:]])/) next
                n++; text[n] = $0; low[n] = tolower($0); num[n] = FNR
            }
            END {
                for (i = 1; i <= n; i++) {
                    if (low[i] !~ /trust/) continue
                    w = low[i]
                    if (i > 1) w = low[i-1] " " w
                    if (i < n) w = w " " low[i+1]
                    if (w !~ /desktop app/) continue
                    if (w ~ /could not be confirmed/)
                        printf "%s:%d: superseded claim: %s\n", file, num[i], text[i]
                    else if (w !~ /command-line tool|codex cli/)
                        printf "%s:%d: trust without the CLI review: %s\n", file, num[i], text[i]
                }
            }
        ' "$f"
    done
}

# The proven claim, read with the file folded onto one line so wrapping does not matter.
missing_claim_parts() {
    local f="$1" flat part
    flat="$(tr '\r\n' '  ' < "$f" | tr -s ' ' | tr '[:upper:]' '[:lower:]')"
    for part in "on a mac" "loading hooks" "does not stop mmry working" \
                "desktop app on windows is not yet confirmed"; do
        [[ "$flat" == *"$part"* ]] || echo "$f: missing \"$part\""
    done
}

customer_files() {
    find "$PLUGIN_ROOT/hooks-handlers" "$PLUGIN_ROOT/setup" \
         "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/skills-codex" \
         "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/commands-codex" \
         "$REPO_ROOT/docs" \
         -type f \( -name '*.sh' -o -name '*.cmd' -o -name '*.bat' -o -name '*.ps1' -o -name '*.md' \) \
         2>/dev/null
    echo "$PLUGIN_ROOT/README.md"
    echo "$REPO_ROOT/README.md"
}

claim_surfaces() {
    echo "$REPO_ROOT/docs/codex.md"
    echo "$REPO_ROOT/README.md"
    echo "$PLUGIN_ROOT/README.md"
    echo "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    echo "$PLUGIN_ROOT/setup/mmry-setup.sh"
}

@test "desktop trust: shipped text sends desktop customers to the CLI review and drops the old claim" {
    local files=()
    while IFS= read -r f; do [[ -f "$f" ]] && files+=("$f"); done < <(customer_files)
    run desktop_trust_offenders "${files[@]}"
    [[ "$status" -eq 0 ]] || return 1
    if [[ -n "$output" ]]; then
        echo "Desktop-app trust text that is superseded or skips the Codex CLI review:" >&2
        echo "$output" >&2
        return 1
    fi
}

@test "desktop trust: every customer surface states what the desktop app has proven" {
    local f out="" missing
    while IFS= read -r f; do
        [[ -f "$f" ]] || { out+="$f: not found"$'\n'; continue; }
        missing="$(missing_claim_parts "$f")"
        [[ -z "$missing" ]] || out+="$missing"$'\n'
    done < <(claim_surfaces)
    if [[ -n "$out" ]]; then
        echo "$out" >&2
        return 1
    fi
}

@test "desktop trust: the written surfaces name what works on a Mac" {
    local f
    for f in "$REPO_ROOT/docs/codex.md" "$REPO_ROOT/README.md" "$PLUGIN_ROOT/README.md" \
             "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"; do
        tr '\r\n' '  ' < "$f" | tr -s ' ' \
            | grep -qi "saving, searching and retiring memories and formation messages work" \
            || { echo "$f does not list what works in the desktop app on a Mac" >&2; return 1; }
    done
}

@test "desktop trust: the sweep is reading the files that matter, not an empty set" {
    local files=()
    while IFS= read -r f; do [[ -f "$f" ]] && files+=("$f"); done < <(customer_files)
    [[ "${#files[@]}" -ge 20 ]] || return 1
    printf '%s\n' "${files[@]}" | grep -q '/setup/mmry-setup.sh$'
    printf '%s\n' "${files[@]}" | grep -q '/skills-codex/memory-system/SKILL.md$'
    printf '%s\n' "${files[@]}" | grep -q '/docs/codex.md$'
}

@test "desktop trust: the detector refuses the v2.10.0 wording, including across an echo pair" {
    local tmp="$BATS_TEST_TMPDIR/old-setup.sh"
    printf '%s\n' \
        '    echo "  - Codex desktop app: it does not ask. Trust MMRY'"'"'s hooks in the app before your"' \
        '    echo "    first conversation."' > "$tmp"
    run desktop_trust_offenders "$tmp"
    [[ "$output" == *"trust without the CLI review"* ]] || return 1

    printf '%s\n' \
        '    echo "  - Codex desktop app: it does not ask."' \
        '    echo "    Trust MMRY'"'"'s hooks there before your first conversation."' > "$tmp"
    run desktop_trust_offenders "$tmp"
    [[ "$output" == *"trust without the CLI review"* ]]
}

@test "desktop trust: the detector refuses the v2.10.1 'could not be confirmed' wording" {
    local tmp="$BATS_TEST_TMPDIR/v2101-setup.sh"
    printf '%s\n' \
        '    echo "MMRY has been tested in the Codex command-line tool."' \
        '    echo "Trusting MMRY'"'"'s hooks in the Codex desktop app could not be confirmed in this release."' > "$tmp"
    run desktop_trust_offenders "$tmp"
    [[ "$output" == *"superseded claim"* ]] || return 1

    local md="$BATS_TEST_TMPDIR/v2101.md"
    printf '%s\n' \
        "MMRY has been tested in the Codex command-line tool. Trusting MMRY's hooks in the Codex desktop app" \
        "could not be confirmed in this release." > "$md"
    run desktop_trust_offenders "$md"
    [[ "$output" == *"superseded claim"* ]]
}

@test "desktop trust: the detector accepts the current wording and ignores shell comments" {
    local tmp="$BATS_TEST_TMPDIR/new-setup.sh"
    printf '%s\n' \
        '    # the desktop app showed no review; trust could not be confirmed there in v2.10.1' \
        '    echo "  - Codex desktop app: trust them in the Codex CLI review; the app uses the same trust."' \
        '    echo "MMRY has been tested in the Codex command-line tool, and in the Codex desktop app on a Mac."' > "$tmp"
    run desktop_trust_offenders "$tmp"
    [[ -z "$output" ]]
}

@test "desktop trust: setup prints the proven-scope statement to Codex customers" {
    local f="$PLUGIN_ROOT/setup/mmry-setup.sh"
    grep -qF 'echo "  - Codex desktop app: trust them in the Codex CLI review; the app uses the same trust."' "$f"
    grep -qF 'echo "MMRY has been tested in the Codex command-line tool, and in the Codex desktop app on a Mac."' "$f"
    grep -qF 'stay on \"Loading hooks...\"; that does not stop MMRY working."' "$f"
    grep -qF 'echo "The Codex desktop app on Windows is not yet confirmed."' "$f"
}
