# tracer.bash - loaded through BASH_ENV by every bash the hook starts (#31976).
# Writes one xtrace line per command, stamped with EPOCHREALTIME and the shell's own pid, to
# $MMRY_PROF_LOG. No process is started by the tracing itself.
if [[ -n "${MMRY_PROF_LOG:-}" ]]; then
    exec 9>>"$MMRY_PROF_LOG"
    BASH_XTRACEFD=9
    PS4='+ ${EPOCHREALTIME} ${BASHPID} ${BASH_SOURCE[0]##*/}:${LINENO} [${FUNCNAME[*]}] '
    set -x
fi
