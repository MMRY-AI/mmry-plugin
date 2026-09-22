# MMRY AI on OpenAI Codex

MMRY gives Codex the same thing it gives Claude Code: your memories, loaded automatically at the
start of every session, and saved back as you work. This page is the honest version of what that
means on Codex, including the four things you do not get here, and what you get instead.

---

## Installing

You need the Codex CLI, and a bash on your machine.

**On Windows, run the setup command from the Git Bash window, not from PowerShell or the Command
Prompt.** If you have the Windows Subsystem for Linux installed, typing `bash` in PowerShell starts
the Linux one, which cannot see your Windows files and fails with "Failed to translate" followed by
`execvpe(/bin/bash) failed`. Git Bash is installed with
[Git for Windows](https://gitforwindows.org) and appears in the Start menu.

**1. Add the MMRY marketplace and install the plugin.**

```
codex plugin marketplace add MMRY-AI/mmry-plugin
codex plugin add mmry@mmry-plugin
```

**2. Restart Codex, and trust the hooks.**

The first time Codex starts after installing, it shows a hook review listing MMRY's handlers and
asks whether to trust them. Choose **Trust all and continue**.

This step is not optional and it is not cosmetic. If you choose "Continue without trusting", MMRY
appears installed and does nothing at all: no memories load, nothing is saved. If you skipped it by
accident, remove and re-add the plugin to see the prompt again.

If your organisation has set `allow_managed_hooks_only = true` in its Codex requirements policy,
MMRY's hooks cannot be installed at all. Ask your administrator.

**3. Sign in.**

Ask Codex to run MMRY setup, or run it yourself:

```
bash "${CODEX_HOME:-$HOME/.codex}/mmry/setup/mmry-setup.sh"
```

If you are on Windows and would rather not open Git Bash, this runs the same thing from PowerShell
by naming the shell explicitly, so it cannot pick the wrong one:

```
& 'C:\Program Files\Git\bin\bash.exe' "$env:USERPROFILE\.codex\mmry\setup\mmry-setup.sh"
```

It opens a browser so you can sign in at [mmryai.com](https://mmryai.com), then writes your
credential to `${CODEX_HOME:-$HOME/.codex}/mmry-config.json`. If the browser does not open, the
script prints a URL to paste.

**Why the command is written that way.** Codex reads `CODEX_HOME` to find its own configuration and
MMRY follows it, so your files are under `$CODEX_HOME` if you have set it and under `~/.codex` if
you have not. `"${CODEX_HOME:-$HOME/.codex}"` resolves to the right one either way, which is why
every runnable command on this page is written with it - paste any of them as they are. MMRY's own
hooks and handlers work this out for themselves and need no help from you.

**4. Restart Codex once more.** Your memories load on the next session start.

### On Windows

The steps are identical. You need **Git for Windows** installed, because MMRY's hooks are shell
scripts and that is where Windows gets a shell.

Every hook is launched with `sh`, deliberately, rather than with `bash`. Windows ships a
`bash.exe` in System32 when the Windows Subsystem for Linux is installed, and that one cannot see
your Windows files, so a hook that asked for `bash` could get the wrong shell and fail with
nothing useful printed. Windows ships no `sh.exe` at all, so `sh` can only be Git's.

If nothing happens at all, check that Git for Windows is installed and on your PATH:

```
where.exe sh
```

That should print a path inside your Git installation, usually `C:\Program Files\Git\usr\bin\sh.exe`.
If it prints nothing, reinstall Git for Windows and choose the option that adds it to your PATH.

---

## What you get

| | |
|---|---|
| **Memories at session start** | Your Foundation memories, your account's shared knowledge, and anything matching the directory you are working in, loaded before you type anything. |
| **Foundation memories restated each turn** | Your standing guidance stays in effect through a long session instead of fading. |
| **Coordination-group messages as you work** | When you are in a formation, messages from other people's assistants reach you on their own, marked so you can tell a message meant for you from one sent to everybody. |
| **A prompt to save what is new** | When you send your next message and something is still unsaved, Codex is reminded to record it. If you have just saved, it stays quiet. |
| **The memory operations** | Save, search, reinforce, link, retire, change who can see a memory, and every formation operation. |
| **Reloading your memories mid-session** | Ask your assistant to reload and it re-runs the session-start load, which also refreshes the Foundation memories it restates each turn. This is the Codex equivalent of Claude Code's `/mmry:load-memories`. |

---

## Where this works

MMRY is a Codex plugin, so it reaches you wherever Codex runs plugins.

| Surface | MMRY |
|---|---|
| Codex CLI | yes, this is what the instructions above install |
| Codex in the ChatGPT desktop app | yes, plugins are supported there |
| The Codex IDE extension | no. OpenAI's plugin documentation states plainly that "the IDE extension doesn't support plugins", so no plugin reaches it, not only ours |
| Codex cloud tasks | not established. OpenAI's plugin documentation does not name it either way, and we have not run a cloud task to find out. Treat it as unsupported until we say otherwise |

Source: OpenAI's plugin documentation at
[learn.chatgpt.com/docs/plugins](https://learn.chatgpt.com/docs/plugins), read 2026-09-21, which
says "Plugins work in Chat and Work across ChatGPT on the web, desktop, and mobile, and in Codex
in the ChatGPT desktop app" and "The IDE extension doesn't support plugins".

## What is NOT available on Codex, and what you get instead

These are real limitations of the platform, not things we have not got round to. They are listed
here so you find out from us rather than from a session that quietly did not do what you expected.

### 1. There are no slash commands to type

On Claude Code you type `/mmry:save`, `/mmry:search`, `/mmry:formation`. **On Codex you cannot type
any of these.** Codex does not give plugins typed slash commands at all: it converts a plugin's
commands into *skills*, which the assistant chooses to use rather than you invoking them.

**What you get instead:** ask in plain words. "Remember this." "What do you know about the refund
flow?" "Make that last one private." "Start a formation for the checkout work." The assistant has a
skill describing every operation and reaches for it. In practice this is how most people already use
MMRY on Claude Code; what you lose is the certainty of typing an exact command.

### 2. There is no prompt before your conversation is trimmed

When a Claude Code conversation is about to be compacted, MMRY interrupts and asks the assistant to
record the session's state first. **Codex has no equivalent moment that a plugin can reach**. The
event exists, but it has no channel to the assistant, so nothing we send would arrive.

**What you get instead:** the save prompt arrives with your next message, and only when there is
unsaved work to record: if you have just saved, it stays quiet. It carries an added warning that
this is the last reliable point before context may be trimmed. It fires more often and earlier than
the Claude Code compaction prompt, so in practice less is at risk, but it is a different moment, and
if you have just done something you would hate to lose, say "remember this" rather than relying on
it.

### 3. A message will not wake an idle session

On Claude Code, a session sitting idle can be woken by a formation message arriving minutes later.
**Codex has no mechanism for this.** A hook that runs in the background there cannot deliver
anything to the assistant, and one that waits would hold up the end of every turn.

**What you get instead:** messages are delivered the next time anything happens: the next tool the
assistant runs, the next thing you type, or the next time you open a session. Nothing is lost; it
arrives later. If you are coordinating something time-sensitive, the person waiting should expect
delivery on activity rather than instantly.

### 4. There is no plan-accepted prompt

Claude Code tells MMRY when you accept a plan, which is a good moment to record the decision.
**Codex has no equivalent tool**, so there is nothing to trigger on.

**What you get instead:** nothing automatic. Say "remember this plan" and it is saved as a Decision
memory.

---

## What is the same

- **Your memories are the same memories.** One account, one store. A memory saved from Codex is
  there in Claude Code and in any connected assistant, and vice versa.
- **Privacy controls are the same.** Global, Private and Group visibility all work, and re-scoping
  is still restricted to whoever saved the memory.
- **Formations work, all of them.** List, start, join, speak to the formation or to one member,
  see the roster, assign work, report progress, claim an area, read the report, debrief and leave.
  Messages reach you as you work.

  Earlier builds of this page said six of those operations had no Codex surface. They do now. The
  reason they were held back was that the instructions they printed when something went wrong
  named typed slash commands, which is worse than nothing on a platform that has none; those
  messages are derived from the platform you are on, so every operation is usable here.
- **Tiers and reinforcement are the same.** Nothing about how memories age or survive differs by
  platform.

---

## Removing MMRY from Codex

Both uninstaller scripts in this plugin remove the **Claude Code** installation, and both refuse
to run when they are started from a Codex directory - so there is no single command here. Removing
it from Codex is three steps:

1. **Remove the plugin through Codex**, the same way you added it.
2. **Delete the MMRY directory** inside your Codex home:
   ```bash
   rm -rf "${CODEX_HOME:-$HOME/.codex}/mmry"
   ```
3. **Delete the credential file**, which is what disconnects this machine from your account:
   ```bash
   rm -f "${CODEX_HOME:-$HOME/.codex}/mmry-config.json"
   ```

Your memories are stored on your account, not on this machine, so none of this deletes anything you
have saved. Setting Codex up again restores access to all of it.

If you also use Claude Code, this leaves that installation completely untouched - the two keep
separate credentials and separate directories on purpose.

---

## If something is not working

| Symptom | First thing to check |
|---|---|
| No memories at session start | Did you answer **Trust all and continue** at the hook review? Restart Codex and look for it. |
| "MMRY AI is installed but needs to be set up" | Run `bash "${CODEX_HOME:-$HOME/.codex}/mmry/setup/mmry-setup.sh"`. |
| Nothing at all happens, on Windows | Run `where.exe sh`. If it prints nothing, Git for Windows is missing from your PATH, and MMRY's hooks have no shell to run in. Reinstall it with the PATH option. |
| Setup says "Failed to translate" or `execvpe(/bin/bash) failed` | You ran it in PowerShell and it picked the Linux subsystem's bash. Use the Git Bash window, or the explicit PowerShell form above. |
| Memories load but nothing saves | Ask the assistant to run the save script directly and show you the output. |
| Your session is not in your session list | Codex sessions are listed as `codex`. Your list shows your own sessions only. |
| A Foundation memory you just changed is not being applied | Ask your assistant to reload your memories. It re-runs the session-start load and refreshes the Foundation cache, which otherwise refreshes daily. |
| "Your Foundation directives were NOT applied to this turn (loading took over Ns and was stopped)" | That one is a slow load, so re-send the prompt. If it keeps happening, ask your assistant to reload your memories; the notice names the exact command for your install. |
| "Your Foundation directives were NOT applied to this turn, the loader exited with code N" | That one is a failure, not a slow load, and the notice says so: re-sending will not help. The usual cause is an incomplete install, so reinstall the plugin. |
| You joined a group but no message ever arrives | You almost certainly joined with the `mmry_formation_*` connector tools. They enrol you under a different identity from the one your hooks poll with, so you appear on the roster and receive nothing, with no error. Leave and rejoin by asking your assistant to run the formation join script. |

To report a problem, ask the assistant to submit feedback (it has a script for it) or write to us
through [mmryai.com](https://mmryai.com).
