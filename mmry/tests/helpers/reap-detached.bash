#!/usr/bin/env bash
# reap-detached.bash: end every process a test left running before its temp folder is removed (#31406).
#
# WHY. The hooks under test detach workers on purpose (the Foundation refresh worker, the prepare worker,
# the cksum and jq watchdogs) so a customer's prompt never waits for them. A test that fires such a hook
# ends while its worker may still be running. The worker then writes into the test's temp folder, which
# the teardown is deleting at that moment, and `rm -rf` fails with "Directory not empty". Whether the
# worker is still alive at teardown is a race against the runner's speed, so the failure showed on
# ubuntu-latest in roughly one run in five and never on a developer machine, and it landed on whichever
# test happened to be tearing down (#1395 and #939 in one afternoon, then #1420). It had nothing to do
# with the tests it was reported against.
#
# WHAT IT DOES. Finds every process that still carries the test's temp folder in its environment or its
# command line and is not the test shell, an ancestor of it or a descendant of it, ends it (TERM, then
# KILL after about four seconds), and returns once none remain. Only processes that carry THIS test's
# folder are touched; the folder is unique per test (mktemp -d).
#
# Linux reads /proc/PID/environ and /proc/PID/cmdline with shell builtins. macOS has no /proc: `ps -Eww`
# prints each process's environment after its command, and the same substring match applies. Where
# neither works (Windows Git Bash) nothing is found and teardown behaves exactly as it did.

# Prints the pids to end, one per line.
_mmry_detached_holders() {
    local dir="$1" me="$2" snap pid ppid rest p hops kv found anc
    local -a PP=() CMD=()
    local via_proc=0 hits=" " f
    # Linux: ps for the pid list, /proc for the environment. Git Bash: its own ps (no -o), /proc as
    # well. macOS: no /proc, so ps -Eww carries the environment on each line.
    if [[ -r /proc/self/environ ]]; then
        via_proc=1
        # One grep reads every process's environment and command line; a bash loop doing the same, one
        # process at a time, cost ~1 s a test and doubled the suite's time on the runner.
        while IFS= read -r f; do f="${f#/proc/}"; hits+="${f%%/*} "; done < <(grep -laF -- "$dir" /proc/[0-9]*/environ /proc/[0-9]*/cmdline 2>/dev/null)
        [[ "$hits" != " " ]] || return 0
        snap="$(ps -eo pid=,ppid= 2>/dev/null || ps 2>/dev/null)" || return 0
    else
        snap="$(ps -Eww -axo pid=,ppid=,command= 2>/dev/null)" || return 0
    fi
    while read -r pid ppid rest; do
        [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ ]] || continue
        PP[pid]="$ppid"; CMD[pid]="$rest"
    done <<<"$snap"
    # The test shell and everything above it (bats-exec-test, bats-exec-file, the runner).
    anc=" "
    p="$me"; hops=0
    while [[ -n "$p" && "$p" != 0 && "$p" != 1 && $hops -lt 64 ]]; do
        anc+="$p "; p="${PP[p]:-}"; hops=$(( hops + 1 ))
    done
    for pid in "${!PP[@]}"; do
        [[ "$anc" == *" $pid "* ]] && continue
        # Only a process that has been cut loose from the test is a stray. Anything whose parent chain
        # reaches the test shell or one of its ancestors is still part of the run (a child the test is
        # waiting on, or the pipe helper bats itself keeps beside the test), and ending it would hang or
        # corrupt the run rather than clean it. A detached worker's parent has exited, so its chain
        # reaches init instead.
        p="${PP[pid]:-}"; hops=0
        while [[ -n "$p" && "$p" != 0 && "$p" != 1 && $hops -lt 64 ]]; do
            [[ "$anc" == *" $p "* ]] && continue 2
            p="${PP[p]:-}"; hops=$(( hops + 1 ))
        done
        found=0
        if (( via_proc == 1 )); then
            [[ "$hits" == *" $pid "* ]] && found=1
        else
            [[ "${CMD[pid]}" == *"$dir"* ]] && found=1
        fi
        (( found == 1 )) && printf '%s\n' "$pid"
    done
    return 0
}

# mmry_reap_detached DIR: end what still holds DIR, and return once nothing does (at most about 8 s).
mmry_reap_detached() {
    local dir="$1" pid n=0 holders me="${BASHPID:-$$}"
    [[ -n "$dir" ]] || return 0
    holders="$(_mmry_detached_holders "$dir" "$me")"
    [[ -n "$holders" ]] || return 0
    for pid in $holders; do kill -TERM "$pid" 2>/dev/null || true; done
    while (( n < 40 )); do
        holders="$(_mmry_detached_holders "$dir" "$me")"
        [[ -n "$holders" ]] || return 0
        n=$(( n + 1 ))
        if (( n == 20 )); then for pid in $holders; do kill -KILL "$pid" 2>/dev/null || true; done; fi
        sleep 0.2
    done
    return 0
}


# The teardown every suite shares: reap, then remove. One retry, because a process that was between its
# last write and its exit when the reap returned can still land a file during the first rm.
#
# Git Bash starts a process slowly (about half a second for the scan), so there the reap runs only when
# the first rm left the folder behind, which is exactly the failure being prevented. Linux and macOS
# reap every time (MMRY_TEST_REAP_ALWAYS=1 makes Git Bash do so too; reap-detached.bats sets it): a few milliseconds there, and it is what keeps a worker from outliving its test.
mmry_teardown_tmp() {
    case "${MMRY_TEST_REAP_ALWAYS:+always}$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            rm -rf "$1" 2>/dev/null
            [[ ! -e "$1" ]] && return 0
            ;;
    esac
    mmry_reap_detached "$1"
    rm -rf "$1" 2>/dev/null || { sleep 1; rm -rf "$1"; }
}
