#!/usr/bin/env bash
# lib-tool-server.sh - what MMRY knows about its own tool server on Codex (#32602).
#
# WHY THIS EXISTS. On Codex the MMRY tools (memory_save, formation_say and the rest) come from a
# local MCP server Codex starts for itself, hooks-handlers/mcp-server.sh. Formation messages reach a
# conversation through hooks, which do not depend on that server. So a conversation can go on
# receiving Formation messages with no tools to answer them with, and until #32602 nothing said so:
# the customer saw tools missing and had no way to find out why (MMRY feedback item 36, Codex CLI
# 0.163.0 on a Mac).
#
# WHAT IS RECORDED. The server writes small files in the tool-server folder of the MMRY state
# directory (${CODEX_HOME:-~/.codex}/mmry/tool-server):
#
#   launched          the last time Codex started it: epoch, process id, plugin root
#   failed            the last start that could not finish: epoch, reason in plain words
#   server-<pid>      one per server process that is running: epoch it started, plugin version;
#                     removed on exit
#   session-<sid>     one per conversation that has called a tool: process id serving it, epoch
#
# NOT IN TMPDIR, AND NOT NAMED .mmry-formation-*. The Formation gate in hooks/codex-hooks.json and
# codex-hook.cmd opens for any file in TMPDIR whose name starts with .mmry-formation-, so a file of
# ours there would make every hook in every conversation pay for a check. And Codex starts this
# server with an environment of its own choosing, so the state directory, which both the server and
# the hooks resolve from CODEX_HOME or HOME through lib-host.sh, is the place both are sure to agree on.
#
# READERS NEVER WRITE. mmry_ts_status is used by the Formation delivery hook and by tools-check.sh,
# which the assistant may run inside Codex's sandbox where the state directory is not writable. It
# reads files and asks the kernel whether a process exists; it starts no process on the common path.
#
# Sourced, never run. Requires lib-host.sh to have been sourced first.

# The repository convention (structural/file-integrity.bats). Every function below guards its own
# failures, so -e changes nothing about what it does.
set -euo pipefail

# The folder, without a command substitution. Callers have sourced lib-host.sh.
mmry_ts_dir() {
    _mmry_host_resolve
    MMRY_TS_DIR="${_MMRY_HOST_DIR_V}/mmry/tool-server"
}

# A conversation id made safe for a file name. Same rule as formation-state.sh, kept separate so
# this library does not have to source that one.
_mmry_ts_safe() {
    local s="${1:-}"
    if [[ -z "${s//[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]/}" ]]; then
        MMRY_TS_SAFE="$s"
    else
        MMRY_TS_SAFE="$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_')"
    fi
}

# Is process $1 alive? `kill -0` first, which is a builtin and starts nothing. When it fails, the
# reason matters: inside Codex's sandbox the kernel may refuse to signal a process outside it
# ("Operation not permitted"), which means the process EXISTS. Only "no such process" means gone.
mmry_ts_pid_alive() {
    local pid="${1:-}" err
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null && return 0
    err="$(kill -0 "$pid" 2>&1)" && return 0
    [[ "$err" == *ermitted* ]]
}

# Reads the first two lines of a record into MMRY_TS_L1 and MMRY_TS_L2.
_mmry_ts_read2() {
    MMRY_TS_L1="" MMRY_TS_L2=""
    [[ -f "$1" ]] || return 1
    { IFS= read -r MMRY_TS_L1 || true; IFS= read -r MMRY_TS_L2 || true; } < "$1" 2>/dev/null || true
    MMRY_TS_L1="${MMRY_TS_L1%$'\r'}"
    MMRY_TS_L2="${MMRY_TS_L2%$'\r'}"
    return 0
}

# ---------------------------------------------------------------------------------------------
# READ: is a tool server running for this conversation?
#
#   mmry_ts_status [conversation id]
#
# Sets MMRY_TS_STATE to "running" or "not-started", and MMRY_TS_DETAIL to one of:
#   this-conversation  the server that served this conversation's last tool call is alive
#   unattributed       a server is alive that started after this conversation's last record, or
#                      this conversation has no record; it may be this conversation's
#   starting           the last server started is alive and has not finished starting
#   stopped            this conversation's server is gone and none has started since
#   never              no server is alive and none has ever recorded a start here
#   failed             no server is alive and the last start recorded why it could not finish
#   exited             no server is alive; one started before and is no longer running
#
# WHY "unattributed" COUNTS AS RUNNING. Codex says which conversation a tool call belongs to, but
# not which conversation a server was started for, so before a conversation's first tool call no
# server can be tied to it. Calling that "missing" would tell a customer whose tools work that they
# are broken. So the answer errs towards silence there, and is certain where it says not-started.
# ---------------------------------------------------------------------------------------------
mmry_ts_status() {
    local sid="${1:-}" since=0 f pid
    MMRY_TS_STATE="not-started"
    MMRY_TS_DETAIL="never"
    mmry_ts_dir
    if [[ -n "$sid" ]]; then
        _mmry_ts_safe "$sid"
        if _mmry_ts_read2 "${MMRY_TS_DIR}/session-${MMRY_TS_SAFE}"; then
            if [[ -f "${MMRY_TS_DIR}/server-${MMRY_TS_L1}" ]] && mmry_ts_pid_alive "$MMRY_TS_L1"; then
                MMRY_TS_STATE="running"; MMRY_TS_DETAIL="this-conversation"
                return 0
            fi
            [[ "$MMRY_TS_L2" =~ ^[0-9]+$ ]] && since="$MMRY_TS_L2"
            MMRY_TS_DETAIL="stopped"
        fi
    fi
    for f in "${MMRY_TS_DIR}"/server-*; do
        [[ -f "$f" ]] || continue
        pid="${f##*/server-}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        mmry_ts_pid_alive "$pid" || continue
        _mmry_ts_read2 "$f" || continue
        [[ "$MMRY_TS_L1" =~ ^[0-9]+$ ]] || MMRY_TS_L1=0
        if (( MMRY_TS_L1 >= since )); then
            MMRY_TS_STATE="running"; MMRY_TS_DETAIL="unattributed"
            return 0
        fi
    done
    # A server that has been started and is still getting ready counts as running: a reopened
    # conversation's SessionStart delivery can run while Codex is still starting the server, and
    # telling the customer the tools are missing at that moment would be wrong a second later.
    if _mmry_ts_read2 "${MMRY_TS_DIR}/launched"; then
        [[ "$MMRY_TS_L1" =~ ^[0-9]+$ ]] || MMRY_TS_L1=0
        if (( MMRY_TS_L1 >= since )) && mmry_ts_pid_alive "$MMRY_TS_L2"; then
            MMRY_TS_STATE="running"; MMRY_TS_DETAIL="starting"
            return 0
        fi
    fi
    [[ "$MMRY_TS_DETAIL" == "stopped" ]] && return 0
    if [[ -f "${MMRY_TS_DIR}/failed" ]]; then
        MMRY_TS_DETAIL="failed"
    elif [[ -f "${MMRY_TS_DIR}/launched" ]]; then
        MMRY_TS_DETAIL="exited"
    fi
    return 0
}

# The notice the Formation delivery hook adds when this conversation has no MMRY tools (#32602
# requirement 4). One place, so the hook and the tests read the same words. $1 is the conversation id.
mmry_ts_missing_notice() {
    local sid="${1:-}" check resume
    check="bash \"\${CODEX_HOME:-\$HOME/.codex}/mmry/hooks-handlers/tools-check.sh\""
    if [[ -n "$sid" ]]; then
        resume="codex resume ${sid}"
    else
        resume="codex resume, and pick it"
    fi
    MMRY_TS_NOTICE="MMRY TOOLS ARE MISSING FROM THIS CONVERSATION. MMRY's tool server is not running for it, so you cannot answer the Formation with formation_say or report with formation_progress from here. Tell the customer, in these words: \"The MMRY tools are missing from this conversation. To restore them and keep this conversation's place in the Formation, quit Codex completely, then reopen this same conversation (in a terminal: ${resume}). Do not start a new conversation for it, do not leave and rejoin the Formation, and do not use the mmry_formation connector tools: each of those joins as someone else. To see why the tools are missing, run: ${check}\" Do not run MMRY's formation scripts in their place."
}

# ---------------------------------------------------------------------------------------------
# WRITE: used by mcp-server.sh only. Every one is best effort and returns 0: a server that cannot
# write its record must still serve its tools.
# ---------------------------------------------------------------------------------------------
_mmry_ts_now() {
    MMRY_TS_NOW="$(date +%s 2>/dev/null)" || MMRY_TS_NOW=0
    [[ "$MMRY_TS_NOW" =~ ^[0-9]+$ ]] || MMRY_TS_NOW=0
}

# Start-up has begun. $1 plugin root.
mmry_ts_record_launch() {
    mmry_ts_dir
    [[ -d "$MMRY_TS_DIR" ]] || mkdir -p "$MMRY_TS_DIR" 2>/dev/null || return 0
    _mmry_ts_now
    printf '%s\n%s\n%s\n' "$MMRY_TS_NOW" "$$" "${1:-}" > "${MMRY_TS_DIR}/launched" 2>/dev/null || true
    # Records of servers that are gone are cleared by the next server to start, never by a reader.
    local f pid
    for f in "${MMRY_TS_DIR}"/server-*; do
        [[ -f "$f" ]] || continue
        pid="${f##*/server-}"
        mmry_ts_pid_alive "$pid" || rm -f -- "$f" 2>/dev/null || true
    done
    return 0
}

# Start-up could not finish. $1 the reason, in plain words.
mmry_ts_record_failure() {
    mmry_ts_dir
    [[ -d "$MMRY_TS_DIR" ]] || mkdir -p "$MMRY_TS_DIR" 2>/dev/null || return 0
    _mmry_ts_now
    printf '%s\n%s\n' "$MMRY_TS_NOW" "${1:-unknown}" > "${MMRY_TS_DIR}/failed" 2>/dev/null || true
    return 0
}

# Start-up finished; the server is about to serve. $1 plugin version. Removed by mmry_ts_record_exit.
mmry_ts_record_running() {
    mmry_ts_dir
    [[ -d "$MMRY_TS_DIR" ]] || mkdir -p "$MMRY_TS_DIR" 2>/dev/null || return 0
    _mmry_ts_now
    printf '%s\n%s\n' "$MMRY_TS_NOW" "${1:-}" > "${MMRY_TS_DIR}/server-$$" 2>/dev/null || true
    rm -f -- "${MMRY_TS_DIR}/failed" 2>/dev/null || true
    return 0
}

mmry_ts_record_exit() {
    mmry_ts_dir
    rm -f -- "${MMRY_TS_DIR}/server-$$" 2>/dev/null || true
    return 0
}

# A tool call arrived for conversation $1. Written once per conversation per server process, so a
# busy conversation does not rewrite the file on every call.
_MMRY_TS_SEEN=" "
mmry_ts_record_session() {
    local sid="${1:-}"
    [[ -n "$sid" ]] || return 0
    _mmry_ts_safe "$sid"
    [[ "$_MMRY_TS_SEEN" == *" ${MMRY_TS_SAFE} "* ]] && return 0
    mmry_ts_dir
    [[ -d "$MMRY_TS_DIR" ]] || mkdir -p "$MMRY_TS_DIR" 2>/dev/null || return 0
    _mmry_ts_now
    printf '%s\n%s\n' "$$" "$MMRY_TS_NOW" > "${MMRY_TS_DIR}/session-${MMRY_TS_SAFE}" 2>/dev/null || return 0
    _MMRY_TS_SEEN="${_MMRY_TS_SEEN}${MMRY_TS_SAFE} "
    return 0
}
