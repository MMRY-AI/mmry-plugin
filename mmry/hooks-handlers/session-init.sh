#!/usr/bin/env bash
# session-init.sh — SessionStart hook entry point.
# Discovers the plugin root, copies handler scripts into the host's MMRY directory
# (~/.claude/mmry/ on Claude Code, ~/.codex/mmry/ on Codex), then delegates to
# session-start.sh for memory loading.
#
# Extracted from hooks.json inline command to avoid bash -c quoting issues
# on Windows where cmd.exe misinterprets && and || inside single quotes.
#
# #31245: every destination below comes from lib-host.sh instead of being spelled here. With
# MMRY_HOST unset, which is every existing Claude Code install, mmry_host_state_dir returns
# "${HOME}/.claude/mmry" - the same literal these lines used to carry - so the Claude Code
# behaviour is unchanged rather than merely intended to be.

set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-host.sh"

MMRY_STATE_DIR="$(mmry_host_state_dir)"
MMRY_CONFIG_DIR="$(mmry_host_config_dir)"

# Discover plugin root: prefer CLAUDE_PLUGIN_ROOT, fall back to filesystem search.
# Codex exports CLAUDE_PLUGIN_ROOT to plugin hook processes itself
# (codex-rs/hooks/src/engine/discovery.rs), so the preferred path works on both hosts and the
# fallback search is host-scoped rather than always looking in the Claude plugin cache.
P="${CLAUDE_PLUGIN_ROOT:-}"
P="${P//\\//}"  # Normalize backslashes to forward slashes (Windows)

if [[ -z "$P" ]] || [[ ! -d "$P/hooks-handlers" ]]; then
    # `|| true` is load-bearing under `set -euo pipefail` (#31245 QA round 2). When the plugins
    # directory does not exist, find exits non-zero, pipefail promotes that to the pipeline, and
    # set -e killed this script THERE - before the message below could be printed. The customer
    # got a SessionStart hook that exited 1 and said nothing at all, which is the failure this
    # whole ticket exists to stop. It is likelier on Codex than on Claude Code, where
    # ~/.claude/plugins nearly always exists.
    P="$(find "${MMRY_CONFIG_DIR}/plugins" -path "*/mmry/hooks-handlers" -type d 2>/dev/null | head -1 | sed 's|/hooks-handlers$||' || true)"
fi

if [[ -z "$P" ]]; then
    echo "MMRY AI: Could not locate plugin root. Run $(mmry_host_setup_hint)"
    exit 0
fi

# Clean old hooks dir, create target directories
rm -rf "${MMRY_STATE_DIR}/hooks" 2>/dev/null
mkdir -p "${MMRY_STATE_DIR}/hooks-handlers" "${MMRY_STATE_DIR}/setup"

# WRITE DOWN WHICH HOST THIS INSTALL BELONGS TO, BESIDE THE FILES (#31245 QA round 3).
#
# This is the one moment in the product where the host is known for certain and the files are in
# front of us: this script runs as a Codex hook, with MMRY_HOST exported by codex-hook.sh, and it
# is what puts the handlers in the state directory in the first place.
#
# Every later reader is worse placed. The model invokes
# ${CODEX_HOME:-~/.codex}/mmry/hooks-handlers/save-memory.sh in a shell of its own where MMRY_HOST
# is not set and CODEX_HOME may not be either, and lib-host.sh then has nothing but the path to go
# on. A Codex home relocated somewhere without a ".codex" segment defeated that, and the handler
# loaded the OTHER product's credential (reproduced 2026-09-16). The marker is what it reads first.
#
# It is written for BOTH hosts, and on Claude Code it says "claude" - which lib-host.sh ignores,
# because only "codex" changes any answer. Writing it unconditionally means the file is a statement
# of fact rather than a flag whose absence has to be interpreted.
#
# IT IS WRITTEN BEFORE THE HANDLERS ARE COPIED, NOT AFTER. The marker is the only thing that tells
# a model-invoked handler which product it belongs to when the home was relocated, so a state
# directory must never hold handlers without one. Ordering it first means the only way to get that
# combination is a run that failed before it copied anything.
# AND THE WRITE IS CHECKED, BECAUSE THE COMMENT ABOVE WAS NOT TRUE (#31245 QA round 4).
#
# It said the only way to get handlers without a marker is a run that failed before copying
# anything. It was written with `|| true` and followed by an unconditional `cp`, so a write that
# failed - a read-only state dir, a full disk, a permissions problem, an antivirus lock - exited
# 0, wrote no marker, and copied the handlers anyway. Forced by a reviewer, and confirmed: exit
# 0, no marker, handlers present. That combination is the precondition for the credential defect
# the marker exists to prevent, so the invariant is now enforced rather than asserted in prose.
#
# THE CHECK IS A READ-BACK, not the write's exit status. It is the FILE that later readers
# depend on, not the syscall, and the two can disagree.
_mmry_marker_ok=0
if printf '%s
' "$(mmry_host)" > "${MMRY_STATE_DIR}/.mmry-host" 2>/dev/null; then
    _mmry_marker_readback=""
    read -r _mmry_marker_readback < "${MMRY_STATE_DIR}/.mmry-host" 2>/dev/null || _mmry_marker_readback=""
    _mmry_marker_readback="${_mmry_marker_readback//[[:space:]]/}"
    [[ "$_mmry_marker_readback" == "$(mmry_host)" ]] && _mmry_marker_ok=1
fi

# WHAT FAILURE MEANS DIFFERS BY HOST, so the response does too.
#
# On CODEX the marker is the only signal that survives a relocated home in the shell the model
# actually runs handlers in. Handlers installed without it can resolve the host as Claude and
# reach for the other product's credential, so installing them is worse than not installing
# them. This stops - loudly enough to act on, and with exit 0 so the session still starts.
#
# On CLAUDE CODE the marker changes nothing: lib-host.sh acts only on a marker reading "codex",
# so its absence gives exactly the answer every existing install already has. Refusing to
# install there would break working setups to guard against a risk that does not exist on it.
if (( _mmry_marker_ok == 0 )) && [[ "$(mmry_host)" == "codex" ]]; then
    echo "MMRY AI: could not write the host marker at ${MMRY_STATE_DIR}/.mmry-host." >&2
    echo "  Handlers were NOT installed. Without that file a handler cannot tell which" >&2
    echo "  assistant it belongs to, and may read the wrong account's credential." >&2
    echo "  Check that ${MMRY_STATE_DIR} is writable, then start a new session." >&2
    exit 0
fi

# Copy current handler and setup scripts (all platforms)
cp "$P"/hooks-handlers/*.sh "${MMRY_STATE_DIR}/hooks-handlers/"
cp "$P"/hooks-handlers/*.cmd "${MMRY_STATE_DIR}/hooks-handlers/" 2>/dev/null || true
cp "$P"/setup/*.sh "${MMRY_STATE_DIR}/setup/"
cp "$P"/setup/*.bat "${MMRY_STATE_DIR}/setup/" 2>/dev/null || true
cp "$P"/setup/*.ps1 "${MMRY_STATE_DIR}/setup/" 2>/dev/null || true

# Delegate to the main session-start logic
bash "$P/hooks-handlers/session-start.sh"
