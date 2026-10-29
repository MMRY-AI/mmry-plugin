#!/usr/bin/env bash
# MEASUREMENT ONLY (#33079, branch 33079/measure). Not part of the fix. Logs every process that still
# carries a test's temp folder when its teardown runs, who its parent is, and how long it lives on.
mmry_measure_teardown() {
    local dir="$1" log=/tmp/mmry-measure; mkdir -p "$log"
    local me=$$ f pid line hits=" " t0 n=0
    [[ -d "$dir" ]] || return 0
    if [[ -r /proc/self/environ ]]; then
        while IFS= read -r f; do f="${f#/proc/}"; hits+="${f%%/*} "; done < <(grep -laF -- "$dir" /proc/[0-9]*/environ /proc/[0-9]*/cmdline 2>/dev/null)
        for pid in $hits; do
            [[ "$pid" == "$me" || "$pid" == "$BASHPID" ]] && continue
            [[ -r /proc/$pid/stat ]] || continue
            local pp cmd ppcmd
            pp="$(awk '{print $4}' /proc/$pid/stat 2>/dev/null)"
            cmd="$(tr '\0' ' ' </proc/$pid/cmdline 2>/dev/null | cut -c1-200)"
            ppcmd="$(tr '\0' ' ' </proc/$pp/cmdline 2>/dev/null | cut -c1-120)"
            [[ "$cmd" == *"grep -laF"* ]] && continue
            printf 'LEFTOVER test=%s name="%s" pid=%s ppid=%s cmd=[%s] parent=[%s]\n' "$BATS_TEST_NUMBER" "$BATS_TEST_DESCRIPTION" "$pid" "$pp" "$cmd" "$ppcmd" >> "$log/leftovers.log"
            t0=$SECONDS
            while kill -0 "$pid" 2>/dev/null && (( SECONDS - t0 < 8 )); do sleep 0.05; done
            if kill -0 "$pid" 2>/dev/null; then printf '  pid=%s STILL ALIVE after 8s\n' "$pid" >> "$log/leftovers.log"; else printf '  pid=%s exited %ss later\n' "$pid" "$(( SECONDS - t0 ))" >> "$log/leftovers.log"; fi
        done
    else
        ps -Eww -axo pid=,ppid=,command= 2>/dev/null | grep -F -- "$dir" | grep -v "grep -F" | while read -r pid pp cmd; do
            [[ "$pid" == "$me" || "$pid" == "$BASHPID" ]] && continue
            printf 'LEFTOVER test=%s name="%s" pid=%s ppid=%s cmd=[%s]\n' "$BATS_TEST_NUMBER" "$BATS_TEST_DESCRIPTION" "$pid" "$pp" "${cmd:0:160}" >> "$log/leftovers.log"
        done
    fi
}
