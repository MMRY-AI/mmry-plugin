# #31245 QA round 8: captured test evidence

Captured 2026-10-03 against branch 31245/codex-platform with codex-cli 0.154.0. These are
excerpts of real sessions, not reconstructions: each file names the rollout it came from. The
repository is public, so only MMRY's own hook lines, the prompts and the model's replies are kept;
Foundation memory contents are removed and the Windows user name is replaced with `<user>`.

## How the Windows runs were made

- An isolated `CODEX_HOME` with the plugin installed from this branch as a local marketplace.
- `codex exec -s danger-full-access --dangerously-bypass-hook-trust`, the headless equivalent of
  "Trust all and continue".
- **The stock PATH** a default Git for Windows install leaves: System32, Windows,
  WindowsPowerShell and Git's `cmd` folder, which holds `git.exe` and no shell. No `sh` on PATH.
- Claude Code's session variables removed from the environment, which is a customer's setup.
- **Self-update held off** for each run. `session-start.sh` runs `self-update.sh`, which replaces
  the installed handlers with the released ones; a run that let it would have tested master, not
  this branch. After every run the installed handlers were compared with the branch, file by file,
  and none differed.

## Files

| File | Test case | What it shows |
|---|---|---|
| `tc1-windows-stock-path.txt` | TC1, R3, R6 | Memories delivered at session start and the Foundation block on the prompt, on a machine with no `sh` on PATH |
| `control-windows-stock-path-HEAD-9e3caba.txt` | control | The same machine with the previous registrations: nothing from MMRY reaches the model |
| `windows-no-git-notice.txt` | R3 | With Git unfindable, the one-line notice reaches the model and the session carries on |
| `tc2-formation-join-and-midturn-delivery.txt` | TC2, R2 | The session joins through the plugin's own script, and a message sent while it is running commands reaches it after its next command, unasked |
| `tc3-unix-clean-profile-install.txt` | TC3 (Unix half) | A fresh Debian user with no Codex history installs from GitHub at this branch; every registered hook runs under the shell Codex uses on Linux |

## What is not proven here, stated

- **TC3 on Unix stops short of a live model session.** Placing a Codex login and an MMRY credential
  inside the container was refused by this environment's permission policy, twice, so the run
  proves installation and every hook's execution, and that a session with no credential is told
  how to set up, but not a signed-in session on Linux.
- **macOS has not been run.** The bash 3.2 guard (`structural/bash32-portability.bats`) and the
  BSD-safe fixes cover what can be checked without a Mac; a Mac run is still owed.
- **A clean Windows profile as a separate Windows account was not created.** The Windows runs use
  an isolated `CODEX_HOME` and the stock machine PATH on this machine instead.
- **The interactive hook-trust prompt** was bypassed with the documented flag, not clicked.
