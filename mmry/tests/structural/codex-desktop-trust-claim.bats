#!/usr/bin/env bats
# codex-desktop-trust-claim.bats - no shipped text tells a customer to trust MMRY's hooks in the
# Codex desktop app (#31245).
#
# WHY THIS FILE EXISTS. v2.10.0's setup finished by printing "Codex desktop app: it does not ask.
# Trust MMRY's hooks in the app before your first conversation." UAT on 2026-10-06 found the desktop
# app's hook settings stall, so nobody has seen that instruction work. The docs had already been
# corrected to "could not be confirmed in this release"; the setup script, which is what a customer
# actually reads at the end of an install, had not.
#
# THE RULE. Any customer-facing text that mentions the desktop app and trust in the same place must
# also say the trust step could not be confirmed. "The same place" is a line and the line after it,
# because both setup's echo pairs and wrapped Markdown split one sentence across two lines. Shell
# comment lines are skipped: they are read by maintainers, not printed to customers.
#
# THE SCOPE is what a customer or their assistant can read: the installed scripts (hooks-handlers,
# setup), both skill and command sets, the plugin README, and the repository README and docs.

load '../helpers/test-helper'

REPO_ROOT=""

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
}

# Prints "file:line: text" for every offending window in the files given. Empty output = clean.
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
                # Every line naming trust, read with the line before and after it.
                for (i = 1; i <= n; i++) {
                    if (low[i] !~ /trust/) continue
                    w = low[i]
                    if (i > 1) w = low[i-1] " " w
                    if (i < n) w = w " " low[i+1]
                    if (w ~ /desktop app/ && w !~ /could not be confirmed/)
                        printf "%s:%d: %s\n", file, num[i], text[i]
                }
            }
        ' "$f"
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

@test "desktop trust: no shipped text tells customers to trust MMRY's hooks in the Codex desktop app" {
    local files=()
    while IFS= read -r f; do [[ -f "$f" ]] && files+=("$f"); done < <(customer_files)
    run desktop_trust_offenders "${files[@]}"
    [[ "$status" -eq 0 ]]
    if [[ -n "$output" ]]; then
        echo "Text instructs trusting hooks in the Codex desktop app, which is unconfirmed:" >&2
        echo "$output" >&2
        return 1
    fi
}

@test "desktop trust: the sweep is reading the files that matter, not an empty set" {
    local files=()
    while IFS= read -r f; do [[ -f "$f" ]] && files+=("$f"); done < <(customer_files)
    [[ "${#files[@]}" -ge 20 ]]
    printf '%s\n' "${files[@]}" | grep -q '/setup/mmry-setup.sh$'
    printf '%s\n' "${files[@]}" | grep -q '/skills-codex/memory-system/SKILL.md$'
    printf '%s\n' "${files[@]}" | grep -q '/docs/codex.md$'
}

@test "desktop trust: the detector refuses the v2.10.0 wording, including across an echo pair" {
    local tmp="$BATS_TEST_TMPDIR/old-setup.sh"
    cat > "$tmp" <<'EOF'
    echo "  - Codex desktop app: it does not ask. Trust MMRY's hooks in the app before your"
    echo "    first conversation."
EOF
    run desktop_trust_offenders "$tmp"
    [[ -n "$output" ]]

    cat > "$tmp" <<'EOF'
    echo "  - Codex desktop app: it does not ask."
    echo "    Trust MMRY's hooks there before your first conversation."
EOF
    run desktop_trust_offenders "$tmp"
    [[ -n "$output" ]]
}

@test "desktop trust: the detector accepts the corrected wording and ignores shell comments" {
    local tmp="$BATS_TEST_TMPDIR/new-setup.sh"
    cat > "$tmp" <<'EOF'
    # the desktop app showed no review; trust is recorded in config.toml
    echo "MMRY has been tested in the Codex command-line tool."
    echo "Trusting MMRY's hooks in the Codex desktop app could not be confirmed in this release."
    echo "Until they are trusted, MMRY appears installed and does nothing."
EOF
    run desktop_trust_offenders "$tmp"
    [[ -z "$output" ]]
}

@test "desktop trust: setup prints the confirmed-scope statement to Codex customers" {
    local f="$PLUGIN_ROOT/setup/mmry-setup.sh"
    grep -q 'echo "MMRY has been tested in the Codex command-line tool."' "$f"
    grep -q 'echo "Trusting MMRY'"'"'s hooks in the Codex desktop app could not be confirmed in this release."' "$f"
}
