#!/usr/bin/env bash
# work-dir.bash: make and remove a script's work folder without ever deleting a shared one (#33618).
#
# WHY. On 2026-11-08 a test script whose work folder had not been created deleted the computer's shared
# temporary folder, taking other work with it. QA of 33363 found the same shape in this plugin's mutation
# runners: WORK="${TMPDIR:-/tmp}/..." made with mkdir -p and removed with rm -rf "$WORK". A TMPDIR that did
# not exist was silently created, an unset one fell back to the shared /tmp, and nothing but the spelling
# of each line stood between an empty value and a delete from the root.
#
# WHAT THIS DOES.
#   mmry_work_dir_new LABEL   Sets MMRY_WORK_DIR to a new folder made by mktemp -d INSIDE an existing
#                             TMPDIR, named mmry-LABEL.XXXXXX. Refuses, with a plain message and status 1,
#                             when TMPDIR is unset (there is no /tmp fallback), does not exist, or mktemp
#                             fails. Call it directly, not in $( ), so the message reaches the caller.
#   mmry_work_dir_remove PATH Deletes PATH only when it is a folder of that name directly inside TMPDIR.
#                             Refuses an empty path, the root, HOME, TMPDIR itself, anything outside it,
#                             anything not named mmry-*.*, and any path that climbs with "..".
#   mmry_work_reset PATH      Empties PATH and makes it again, only when PATH is strictly inside
#                             MMRY_WORK_DIR. The mutation runners use it for each fresh plugin copy.
#
# Written for bash 3.2 (stock macOS). It sets no shell options, so a caller's are left as they were.

# _mmry_wd_refuse MESSAGE: print it on stderr and fail.
_mmry_wd_refuse() { printf '%s\n' "$*" >&2; return 1; }

# _mmry_wd_climbs PATH: true when PATH has a "." or ".." component.
_mmry_wd_climbs() {
    case "/$1/" in */../*|*/./*) return 0 ;; esac
    return 1
}

mmry_work_dir_new() {
    local label="${1:-work}" t="${TMPDIR:-}" d=""
    MMRY_WORK_DIR=""
    if [ -z "$t" ]; then
        _mmry_wd_refuse "REFUSED TO START: TMPDIR is not set. Set it to an existing folder of your own; this script does not fall back to the shared /tmp."
        return 1
    fi
    if [ ! -d "$t" ]; then
        _mmry_wd_refuse "REFUSED TO START: TMPDIR '$t' does not exist, so no work folder can be made in it. Create it, or point TMPDIR at an existing folder of your own."
        return 1
    fi
    case "$label" in *[!A-Za-z0-9._-]*|'') _mmry_wd_refuse "REFUSED TO START: work folder label '$label' is not a plain name."; return 1 ;; esac
    d="$(mktemp -d "${t%/}/mmry-${label}.XXXXXX" 2>/dev/null)" || d=""
    if [ -z "$d" ] || [ ! -d "$d" ]; then
        _mmry_wd_refuse "REFUSED TO START: could not create a work folder in TMPDIR '$t'."
        return 1
    fi
    MMRY_WORK_DIR="$d"
    return 0
}

mmry_work_dir_remove() {
    local p="${1:-}" t="${TMPDIR:-}" h="${HOME:-}" name
    [ -n "$p" ] || { _mmry_wd_refuse "not removing: the work folder path is empty"; return 1; }
    [ -n "$t" ] || { _mmry_wd_refuse "not removing '$p': TMPDIR is not set, so it cannot be shown to be a work folder"; return 1; }
    p="${p%/}"; t="${t%/}"; h="${h%/}"
    [ -n "$p" ] || { _mmry_wd_refuse "not removing the root"; return 1; }
    [ -z "$h" ] || [ "$p" != "$h" ] || { _mmry_wd_refuse "not removing '$p': it is HOME"; return 1; }
    _mmry_wd_climbs "$p" && { _mmry_wd_refuse "not removing '$p': the path climbs with . or .."; return 1; }
    # Strictly inside TMPDIR. This is also what refuses TMPDIR itself: "$t" never matches "$t"/*.
    # (A separate equality test was removed in round 1b: nothing reached it that this did not refuse.)
    case "$p" in "$t"/*) ;; *) _mmry_wd_refuse "not removing '$p': it is TMPDIR itself or not inside it ('$t')"; return 1 ;; esac
    name="${p#"$t"/}"
    case "$name" in */*) _mmry_wd_refuse "not removing '$p': it is not directly inside TMPDIR"; return 1 ;; esac
    case "$name" in mmry-?*.?*) ;; *) _mmry_wd_refuse "not removing '$p': it is not named like a work folder (mmry-LABEL.XXXXXX)"; return 1 ;; esac
    [ -e "$p" ] || return 0
    [ -d "$p" ] || { _mmry_wd_refuse "not removing '$p': it is not a folder"; return 1; }
    rm -rf -- "${p:?}"
}

mmry_work_reset() {
    local p="${1:-}" w="${MMRY_WORK_DIR:-}"
    [ -n "$w" ] && [ -d "$w" ] || { _mmry_wd_refuse "not resetting '$p': there is no work folder (call mmry_work_dir_new first)"; return 1; }
    w="${w%/}"; p="${p%/}"
    case "$p" in "$w"/?*) ;; *) _mmry_wd_refuse "not resetting '$p': it is not inside the work folder '$w'"; return 1 ;; esac
    _mmry_wd_climbs "$p" && { _mmry_wd_refuse "not resetting '$p': the path climbs with . or .."; return 1; }
    rm -rf -- "${p:?}" && mkdir -p -- "$p"
}
