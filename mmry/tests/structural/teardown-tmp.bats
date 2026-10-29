#!/usr/bin/env bats
# #33079: the shared teardown ends what a test started before it removes the test's folder, and says
# which process it was when something would not end.
#
# The failure this prevents is a race (a detached hook worker still writing into the folder while
# rm -rf runs: "Directory not empty"), so these tests do not wait for it to happen. They put the
# process in a private folder on purpose and call the teardown on that folder.

load '../helpers/test-helper'

setup() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) skip "Git Bash has no /proc environ and no usable ps; the teardown there is a plain rm" ;; esac
    DIR="$(mktemp -d)"
}

# A writer cut loose from the test: the outer shell exits at once, so the inner one is reparented to
# init exactly as a hook's detached worker is. $1 = folder, $2 = loop body. Prints nothing.
_detached() {
    TMPDIR="$1" bash -c '( eval "$1" ) </dev/null >/dev/null 2>&1 &' _ "$2" </dev/null >/dev/null 2>&1
    sleep 0.3
}

_alive() { kill -0 "$1" 2>/dev/null; }

@test "teardown: a leftover that keeps writing makes the teardown fail, naming the process, and the folder still goes" {
    _detached "$DIR" 'while :; do : > "$TMPDIR/keeps-writing"; sleep 0.05; done'
    MMRY_TEARDOWN_GRACE=2 run mmry_teardown_tmp "$DIR"
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"LEFTOVER"* && "$output" == *'keeps-writing'* ]] || { echo "the leftover was not named: $output"; return 1; }
    [ ! -e "$DIR" ] || { echo "the folder is still there"; return 1; }
    sleep 0.5
    [ ! -e "$DIR" ] || { echo "the folder came back: a writer survived"; return 1; }
    run pgrep -f 'keeps-writing'
    [ "$status" -ne 0 ] || { echo "the writer is still running: $output"; return 1; }
}

@test "teardown: a leftover the test started itself, not detached, is named too" {
    ( TMPDIR="$DIR" bash -c 'while :; do : > "$TMPDIR/own-child"; sleep 0.05; done' ) </dev/null >/dev/null 2>&1 &
    sleep 0.3
    MMRY_TEARDOWN_GRACE=2 run mmry_teardown_tmp "$DIR"
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *'own-child'* ]] || { echo "the leftover was not named: $output"; return 1; }
    [ ! -e "$DIR" ]
}

@test "teardown: a worker that ends by itself is waited for, and the teardown passes with the folder gone" {
    _detached "$DIR" 'i=0; while [ $i -lt 20 ]; do : > "$TMPDIR/late-$i"; i=$((i + 1)); sleep 0.05; done'
    run mmry_teardown_tmp "$DIR"
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    [ ! -e "$DIR" ]
    sleep 0.5
    [ ! -e "$DIR" ] || { echo "the folder came back"; return 1; }
}

@test "teardown: an idle timer left behind cannot write, so it is ended quietly and the teardown passes" {
    TMPDIR="$DIR" bash -c 'sleep 60 </dev/null >/dev/null 2>&1 & echo $! > "$1"' _ "$BATS_TEST_TMPDIR/sleep.pid" </dev/null
    local pid; pid="$(cat "$BATS_TEST_TMPDIR/sleep.pid")"
    _alive "$pid" || { echo "control: the timer is not running"; return 1; }
    run mmry_teardown_tmp "$DIR"
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    sleep 0.3
    ! _alive "$pid" || { kill "$pid"; echo "the timer was left running"; return 1; }
}

@test "teardown: a stub that waits on a timer, as the hang simulations do, finishes once the timer is ended and passes" {
    printf '#!/usr/bin/env bash\nsleep 60\nexit 0\n' > "$DIR/hang-stub"
    chmod +x "$DIR/hang-stub"
    TMPDIR="$DIR" bash -c '( "$1" ) </dev/null >/dev/null 2>&1 &' _ "$DIR/hang-stub" </dev/null >/dev/null 2>&1
    sleep 0.3
    local t0=$SECONDS
    run mmry_teardown_tmp "$DIR"
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    (( SECONDS - t0 < 8 )) || { echo "it waited out the grace period: $(( SECONDS - t0 )) s"; return 1; }
    [ ! -e "$DIR" ]
}

@test "teardown: a process that does not carry the folder is left alone" {
    env -i /bin/sleep 60 </dev/null >/dev/null 2>&1 &
    local other=$!
    run mmry_teardown_tmp "$DIR"
    local alive=1; _alive "$other" || alive=0
    kill "$other" 2>/dev/null || true
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    [ "$alive" -eq 1 ] || { echo "a process that did not carry the folder was ended"; return 1; }
}

@test "teardown: a folder nothing holds is simply removed" {
    : > "$DIR/file"
    run mmry_teardown_tmp "$DIR"
    [ "$status" -eq 0 ]
    [ ! -e "$DIR" ]
}
