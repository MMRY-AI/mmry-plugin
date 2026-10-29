#!/usr/bin/env bash
# teardown-tmp.bash: end everything a test started, then remove its temp folder (#33079).
#
# WHY. The hooks under test detach workers on purpose, so a customer's prompt never waits for them: part 1
# of the Foundation hook starts a refresh worker (userpromptsubmit-foundation.sh --part 1, parent init) on
# the first prompt of a session, and a test that fires the hook ends while that worker may still be
# running. It then writes into the test's temp folder (the cache, the stamp, the lock) while the teardown's
# `rm -rf` is deleting it, and rm fails with "Directory not empty". Measured on ubuntu-latest (#33079):
# the worker is alive at teardown in about one test in thirty of those that fire part 1, and it ends within
# a second, so whether rm wins is a coin the runner's load tosses. It showed on whichever test happened
# to be tearing down (1395, then 939), never on a developer machine, and had nothing to do with the test
# it was reported against.
#
# WHAT THIS DOES. Before the folder goes it finds every process that still carries the folder in its
# environment or command line (a test's TMPDIR is its folder, so everything the test started, directly or
# through a hook, carries it), apart from this shell and the shells above it.
#   1. An idle timer, a bare `sleep`, cannot write anything. It is ended at once, because the hook
#      stubs that simulate a hang wait on one, and ending it lets the stub finish.
#   2. Anything else is given MMRY_TEARDOWN_GRACE seconds (default 10) to finish by itself. A hook's
#      worker ends inside one second, so waiting for it is the right end for it: nothing is killed that
#      was about to finish, and nothing is left to race the delete.
#   3. What is still running after that is a leftover: it is killed, the folder is removed, and the
#      teardown FAILS NAMING IT, so the test is red and the message says which process. A leftover is
#      the test's to end, not the harness's to hide.
#
# bats' own helpers are not touched: they were started before the test exported its TMPDIR, so they
# carry neither the folder in their environment nor in their command line.
#
# Linux reads /proc (one grep for every process); macOS has no /proc and uses `ps -Eww`, which prints each
# process's environment after its command. Windows Git Bash has neither a usable environ nor a reliable
# ps, so there it removes the folder as the teardown always did.

# This shell and everything above it, as " pid pid ... ".
_mmry_td_ancestors() {
    local p=$$ hops=0 s anc=" $$ "
    while [[ -n "$p" && "$p" != 0 && "$p" != 1 && $hops -lt 64 ]]; do
        if [[ -r "/proc/$p/stat" ]]; then
            s="$(<"/proc/$p/stat")"; s="${s##*) }"
            set -- $s
            p="${2:-}"
        else
            p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
        fi
        [[ -n "$p" ]] && anc+="$p "
        hops=$(( hops + 1 ))
    done
    printf '%s' "$anc"
}

# Writes "pid<TAB>command" for each process that carries $1, to $2. Empty when none.
_mmry_td_scan() {
    local dir="$1" out="$2" anc pid cmd rest ppid f seen=" " s
    : > "$out"
    anc="$(_mmry_td_ancestors)"
    if [[ -r /proc/self/environ ]]; then
        # Redirected, not captured: a $(...) would be a shell of the test's own that carries the folder.
        grep -laF -- "$dir" /proc/[0-9]*/environ /proc/[0-9]*/cmdline > "$out.hits" 2>/dev/null
        while IFS= read -r f; do
            f="${f#/proc/}"; pid="${f%%/*}"
            [[ "$seen" == *" $pid "* || "$anc" == *" $pid "* ]] && continue
            seen+="$pid "
            [[ -r "/proc/$pid/stat" ]] || continue
            s="$( { IFS= read -r s < "/proc/$pid/stat"; printf '%s' "$s"; } 2>/dev/null )"
            [[ -n "$s" ]] || continue
            s="${s##*) }"
            [[ "${s:0:1}" == "Z" ]] && continue
            # The braces keep the redirect's own error quiet: the process may be gone by now.
            cmd="$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null )"
            [[ -n "$cmd" ]] || continue
            printf '%s\t%s\n' "$pid" "${cmd:0:200}" >> "$out"
        done < "$out.hits"
        rm -f "$out.hits"
    else
        ps -Eww -axo pid=,ppid=,command= > "$out.hits" 2>/dev/null || true
        while read -r pid ppid rest; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            [[ "$rest" == *"$dir"* ]] || continue
            [[ "$anc" == *" $pid "* ]] && continue
            case "$rest" in "ps "*|*"/bin/ps "*) continue ;; esac
            printf '%s\t%s\n' "$pid" "${rest:0:200}" >> "$out"
        done < "$out.hits"
        rm -f "$out.hits"
    fi
    return 0
}

# End every pid listed in $1 (a scan file): TERM, then KILL after two seconds.
_mmry_td_kill() {
    local out="$1" pid cmd i alive
    while IFS=$'\t' read -r pid cmd; do kill "$pid" 2>/dev/null || true; done < "$out"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        alive=0
        while IFS=$'\t' read -r pid cmd; do kill -0 "$pid" 2>/dev/null && alive=1; done < "$out"
        (( alive == 0 )) && return 0
        sleep 0.1
    done
    while IFS=$'\t' read -r pid cmd; do kill -9 "$pid" 2>/dev/null || true; done < "$out"
    return 0
}

# mmry_teardown_tmp <folder>: see the top of the file. Returns 1, naming each leftover, when the test
# left something running; the folder is removed either way.
mmry_teardown_tmp() {
    local dir="${1:-}" out pid cmd a0 t0 grace="${MMRY_TEARDOWN_GRACE:-10}" report="" n=0
    [[ -n "$dir" ]] || return 0
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            rm -rf "$dir" 2>/dev/null
            [[ ! -e "$dir" ]] || { sleep 1; rm -rf "$dir"; }
            return 0 ;;
    esac
    [[ -d "$dir" ]] || return 0
    # Outside the folder: the test's TMPDIR IS the folder, so a bare mktemp would put this inside it.
    out="$(TMPDIR=/tmp mktemp /tmp/mmry-td.XXXXXX)" || { rm -rf "$dir"; return 0; }
    t0="$(date +%s)"
    while :; do
        _mmry_td_scan "$dir" "$out"
        [[ -s "$out" ]] || break
        while IFS=$'\t' read -r pid cmd; do
            a0="${cmd%% *}"; a0="${a0##*/}"
            [[ "$a0" == sleep ]] && kill "$pid" 2>/dev/null
        done < "$out"
        (( $(date +%s) - t0 >= grace )) && break
        sleep 0.1
    done
    if [[ -s "$out" ]]; then
        # Again, so a leftover that went in the last instant is not named, and one that is idle is.
        _mmry_td_scan "$dir" "$out"
        while IFS=$'\t' read -r pid cmd; do
            # A timer is never the leftover: it is what a leftover loop is sleeping on, and it cannot write.
            a0="${cmd%% *}"; a0="${a0##*/}"
            [[ "$a0" == sleep ]] && continue
            n=$(( n + 1 ))
            report+="  pid $pid: ${cmd}"$'\n'
        done < "$out"
        _mmry_td_kill "$out"
    fi
    rm -f "$out"
    rm -rf "$dir" 2>/dev/null || { sleep 1; rm -rf "$dir"; }
    if (( n > 0 )); then
        printf 'LEFTOVER: %d process(es) this test started were still running %ss after it ended, and carry its temp folder:\n%s' "$n" "$grace" "$report" >&2
        return 1
    fi
    return 0
}
