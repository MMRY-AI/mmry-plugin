#!/usr/bin/env bash
# lib-waiting-actions.sh - the closed lists behind the waiting notice's ACTION (#34651, DD-207 in
# MMRY-AI/mmry, amending DD-206). Sourced, never run: it sets four variables and one function, starts
# no process and prints nothing.
#
# WHY A FILE OF ITS OWN (#34651 fix round 1). Two handlers must hold a word to the SAME lists:
#   formation-waiting.sh   derives the action from a waiting command and sends it (the member's side);
#   formation-check.sh     shows the person at the lead window the line the service sent (the lead's
#                          side), and may show a subcommand only when it is on that program's list.
# formation-waiting.sh is a hook handler and cannot be sourced, so the lists live here, once.
#
# THE CLOSED LISTS, word for word the same text as the service's FormationWaitingActions.Subcommands
# and .Interpreters (MMRY-AI/mmry; formation-waiting-action.bats K-15 compares them when
# MMRY_SERVICE_REPO is set). One entry per tool: "tool= word word ... ;", every word with a space on
# each side. Lowercase letters, digits, dashes, spaces, = and ; only, so the text is safe inside a jq
# program. Adding a subcommand is a change to both repositories.
_MMRY_WAITING_SUBCOMMANDS='git= add am apply bisect blame branch checkout cherry-pick clean clone commit config describe diff fetch gc grep init log ls-files ls-remote merge mv pull push rebase reflog remote reset restore rev-list rev-parse revert rm show stash status submodule switch tag worktree ;gh= api auth browse gist issue label pr release repo run search secret status variable workflow ;dotnet= add build build-server clean dev-certs ef format list msbuild new nuget pack publish remove restore run sln test tool user-secrets watch workload ;npm= audit ci config exec init install link ls outdated pack publish rebuild run start test uninstall update version view ;pnpm= add audit dlx exec init install link list outdated publish rebuild remove run start test update ;yarn= add audit dlx exec init install link remove run start test up upgrade workspace workspaces ;docker= build compose container cp exec image images inspect kill login logout logs network ps pull push restart rm rmi run start stop system tag volume ;kubectl= apply config cp create delete describe edit exec explain get label logs patch port-forward rollout scale top ;az= account acr ad aks appservice deployment functionapp group keyvault login logout monitor network resource role storage vm webapp ;cargo= add bench build check clean clippy doc fmt init install new publish remove run test update ;go= build clean doc env fmt generate get install list mod run test tool version vet work ;pip= check config download freeze install list show uninstall wheel ;winget= export import install list search show source uninstall upgrade ;brew= cleanup doctor info install link list outdated reinstall search services uninstall update upgrade ;'
_MMRY_WAITING_INTERPRETERS=' bash sh node pwsh powershell python python3 '
# THE FLAGS THAT TAKE NO VALUE, per interpreter (#34651 fix round 1, Seat D early read item 2). A
# script's file name is taken only when it is the word RIGHT AFTER the interpreter, or after flags
# from this list and nothing else. Any other flag first gives no action at all, because the word
# after an unknown flag may be that flag's VALUE (node --require ./loader.js app.js named the loader).
# The same entry shape as the subcommand list; plugin only (the service is sent the result, never a
# flag). Exact case, one flag a word: -NoProfile is listed, -noprofile and -ex are not, and give the
# program alone. For pwsh and powershell, -File may follow these flags and the script follows it
# (written into the grammar, not this list: it is a marker, and the word after it IS the script).
# NOT on the list because each takes a value: -ExecutionPolicy, -WorkingDirectory,
# -ConfigurationFile and the rest of pwsh's; bash -o, -O, --rcfile, --init-file; python -X, -W, -m;
# every node flag (--require, -r, --import, --loader, --env-file; node's value-less flags are
# left off too, there are hundreds and the list would never be closed).
_MMRY_WAITING_SCRIPT_FLAGS='bash= -e -u -x -l -v ;sh= -e -u -x -l -v ;python= -u -B -E -s -I ;python3= -u -B -E -s -I ;pwsh= -NoProfile -NonInteractive -NoLogo ;powershell= -NoProfile -NonInteractive -NoLogo ;node= ;'
# The service's shape rule for an action (FormationWaitingNotice.IsProgramAction; ERE, bash 3.2).
_MMRY_WAITING_ACTION_RE='^([a-z][a-z0-9-]{0,23}|script [A-Za-z0-9_.-]{1,64}|inline)$'
# _mmry_waiting_action_ok PROGRAM ACTION: 0 when ACTION is one of the three shapes AND belongs to
# PROGRAM by the closed lists above: a subcommand that tool is known to have, or script and inline for
# an interpreter. The shell's second check of whatever the grammar printed, and of whatever an ask
# record on disk says, so nothing else is ever sent. No process is started.
_mmry_waiting_action_ok() {
    local p="${1:-}" a="${2:-}" seg IFS
    [[ "$p" =~ ^[a-z0-9]+$ && "$a" =~ $_MMRY_WAITING_ACTION_RE ]] || return 1
    case "$a" in
        inline|"script "*)
            [[ "$_MMRY_WAITING_INTERPRETERS" == *" ${p} "* ]]
            return ;;
    esac
    IFS=';'
    for seg in $_MMRY_WAITING_SUBCOMMANDS; do
        if [[ "$seg" == "${p}= "* && "$seg" == *" ${a} "* ]]; then return 0; fi
    done
    return 1
}
