#!/usr/bin/env bats
# #31406: the shared teardown ends what a test left running before it removes the test's folder.
#
# The failure this prevents is a race, so these tests do not wait for it to happen. They put a
# detached writer in the folder on purpose, the way a hook's refresh worker is detached, and prove
# the teardown ends it. Without the reap the writer re-creates files while rm -rf runs and the
# folder survives, which is the "Directory not empty" the ubuntu leg showed.

load '../helpers/test-helper'

setup() { export MMRY_TEST_REAP_ALWAYS=1; }

# A writer that is NOT a descendant of this shell: the outer shell exits at once, so the inner one is
# reparented, exactly as a detached hook worker is. It stops itself after 25 s so a broken reap cannot leave it for good. It carries the folder in its environment (TMPDIR).
_detached_writer() {   # $1 = folder it writes into, prints its pid
    local dir="$1" pidfile="$BATS_TEST_TMPDIR/writer.pid"
    TMPDIR="$dir" bash -c '
        bash -c '"'"'echo $$ > "$1"; while (( SECONDS < 25 )); do mkdir -p "$TMPDIR/nested"; : > "$TMPDIR/nested/f$RANDOM"; sleep 0.02; done'"'"' _ "$1" </dev/null >/dev/null 2>&1 &
    ' _ "$pidfile" </dev/null >/dev/null 2>&1
    local i
    for i in $(seq 1 50); do [[ -s "$pidfile" ]] && break; sleep 0.1; done
    cat "$pidfile"
}

@test "reap: a detached process that keeps writing into the folder is ended, and the folder goes" {
    local dir; dir="$(mktemp -d)"
    local pid; pid="$(_detached_writer "$dir")"
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "the writer never started"; return 1; }
    kill -0 "$pid" 2>/dev/null || { echo "control: the writer is not running"; return 1; }
    mmry_teardown_tmp "$dir"
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; echo "the writer was still running after the teardown"; return 1; fi
    sleep 1
    [[ ! -e "$dir" ]] || { echo "the folder is back or never went: $(ls -A "$dir")"; rm -rf "$dir"; return 1; }
}

@test "reap: a process that holds some other folder is left alone" {
    local mine other; mine="$(mktemp -d)"; other="$(mktemp -d)"
    local pid; pid="$(_detached_writer "$other")"
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "the writer never started"; return 1; }
    mmry_teardown_tmp "$mine"
    local alive=1; kill -0 "$pid" 2>/dev/null || alive=0
    kill -9 "$pid" 2>/dev/null || true
    rm -rf "$mine" "$other"
    (( alive == 1 )) || { echo "a process that did not hold the folder was ended"; return 1; }
}

@test "reap: the test's own shell and its children survive the teardown" {
    sleep 30 & local child=$!
    mmry_reap_detached "$TEST_TMPDIR"
    local alive=1; kill -0 "$child" 2>/dev/null || alive=0
    kill "$child" 2>/dev/null || true
    (( alive == 1 )) || { echo "the reap ended a child of the test"; return 1; }
}
