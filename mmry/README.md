# MMRY AI

Persistent memory for Claude Code and OpenAI Codex. On Claude Code it loads memories at session start and prompts to save at session end, before context compression, and when plans are accepted. On Codex the session-start load, the Foundation memories restated each prompt and coordination-group messages all work; the save prompt arrives with your next message when something is unsaved, and there is no prompt at context compression or plan acceptance because Codex gives a plugin no moment for either. See [docs/codex.md](../docs/codex.md).

Claude Code: Windows (Git Bash), macOS and Linux. OpenAI Codex: verified in live sessions on Windows; installation and hooks verified on Linux; macOS not yet verified in a live Codex session.

## Which assistant are you using?

This plugin serves two hosts from one codebase, and they are not set up the same way.

- **Claude Code** - everything below applies as written. Typed slash commands (`/mmry:save`,
  `/mmry:search`, `/mmry:formation`) are available.
- **OpenAI Codex** - see **[docs/codex.md](../docs/codex.md)** for installation, setup, what is
  and is not supported, and how to uninstall. Codex has no typed slash commands; you ask for what
  you want in plain words. Do not follow the Claude Code instructions below on Codex: the setup
  command differs, and running the wrong one writes your credential into the other product's
  account file.

## Requirements

- **Claude Code** (latest version) **or OpenAI Codex**
- **bash** (Git Bash on Windows, native on macOS/Linux)
- **curl** (included with Git Bash, native on macOS/Linux)
- **jq** (ships bundled with the plugin, so nothing to install; a system jq is used automatically when present)

## Installation

### From GitHub Marketplace (recommended)

1. Add the marketplace:
   ```
   /plugin marketplace add MMRY-AI/mmry-plugin
   ```

2. Install the plugin:
   ```
   /plugin install mmry@mmry-plugin
   ```

3. Restart Claude Code. Claude will guide you through setup automatically.

4. Restart Claude Code again after setup completes.

### From Local Directory

For local or LAN installations, run the install script directly:

**macOS / Linux:**
```bash
bash setup/install.sh
```

**Windows:**
Double-click `setup/install.bat`

Then run `setup/mmry-setup.sh` to create your account and API key.

## Setup

When you start Claude Code with the plugin installed but not configured, setup runs automatically. It opens your browser so you can log in or create an account on mmryai.com, then configures everything.

You can also run `/mmry:setup` at any time to reconfigure or if the automatic prompt didn't trigger.

Restart Claude Code after setup completes.

## Uninstall

**From marketplace:**
```
/plugin uninstall mmry@mmry-plugin
```

**From local install:**
```bash
bash setup/uninstall.sh    # macOS/Linux
```
Or double-click `setup/uninstall.bat` on Windows.

## Configuration

Setup creates `~/.claude/mmry-config.json` automatically. You can also create it manually:

```json
{
  "apiUrl": "https://mmryai.com",
  "authMethod": "apikey",
  "apiKey": "your-api-key-here"
}
```

**Environment variable overrides:** `MMRY_API_URL`, `MMRY_API_KEY`

### Foundation re-injection (optional)

Foundation memories are restated to Claude on every prompt so they consistently guide responses. These optional keys tune that behavior:

| Key | Default | Purpose |
|-----|---------|---------|
| `foundationReinject` | `true` | Set to `false` to turn off per-prompt Foundation re-injection. |
| `foundationReinjectTokenCap` | (no longer applied) | Still accepted, so existing config files do not break, but it no longer limits anything. See below. |
| `foundationRefreshSeconds` | `86400` | How often (seconds) the Foundation cache re-fetches mid-session so admin changes propagate without a restart. Default is daily; `0` re-fetches only at session start. |

Env overrides: `MMRY_FOUNDATION_REINJECT`, `MMRY_FOUNDATION_REFRESH_SECONDS`. `MMRY_FOUNDATION_TOKEN_CAP` is still read, for the same compatibility reason as the config key, and has no effect.

**Your Foundation set is never trimmed or cut.** Before MMRY 2.9.2 the set was cut at roughly 6,000 characters, as a raw substring, so the cut landed wherever that character fell: mid-sentence, mid-directive. Anything after it never reached the assistant and you were never told. Now, in Claude Code, a set of up to about 57,000 characters is delivered in full with every prompt, in up to six labelled parts, because Claude Code shows a plugin at most 10,000 characters at a time. A larger set is more than six parts hold, so instead your assistant is pointed to a copy of it, made for that turn, and asked to read it before answering; you are told when that happens, and the assistant may need your permission to read the file. The tokens are spent in your own session, so the cost of a large set is yours to weigh.

**Your local copy is verified before it is used.** Your directives are stored in one file whose first line records their exact byte count and checksum, and the whole file is replaced in a single step, so a prompt that arrives while your directives are being refreshed sees either the old set or the new one, never half of each. On every prompt the hook reads that file once and checks the directives against the record on its first line, and if the two do not agree (damaged, truncated, or replaced without its record) the copy is refused rather than sent to the assistant as your guidance. This is a consistency check, not a signature: it proves the copy is the one its record describes, and it cannot tell MMRY's writing from another program on your machine that deliberately rewrites the whole file. You are told on that turn, in your own terminal, with the remedy: run `/mmry:load-memories` to rebuild it. A valid copy is silent. An account with genuinely no Foundation memories is told so once a session, when the session starts or on its first prompt, rather than warned on every prompt.

**To ask at any time, run `/mmry:foundation-status`.** It reports whether re-injection is on, whether the stored copy still matches the record MMRY wrote when it last fetched your directives, how many directives and bytes it holds, whether the most recent prompt received them in full, in part or by reference, and how long ago they were last sent. It is a local integrity check and makes no network call, so it tells you your copy is intact and being delivered, not that it agrees with the server right now; if you have changed your directives in the account portal since the last fetch, run `/mmry:load-memories` to pick them up. Read-only: it never rebuilds or repairs anything. It exists because a refusal only speaks when something is wrong, and on 2026-09-18 an account ran for hours on a four-character stub with no way to ask.

**If re-injection is ever too slow to finish,** the hook stops itself after 10 seconds instead of letting Claude Code cut it off, and tells you that the turn ran without your Foundation directives so you can re-send the prompt. Previously that turn simply ran with none of your standing directives applied and the only sign was a generic hook-timeout warning.

Override the 10 seconds with the `MMRY_FOUNDATION_DEADLINE_SECS` environment variable. This one is an environment variable only, with no matching config key. The part of the hook that enforces the deadline does read the config file first, but only far enough to answer one question — whether you have switched re-injection off here — and it does that with a deliberately conservative text scan that treats anything it cannot read confidently as “not switched off”. A deadline cannot be read that way: a number that scan misread would either stop a healthy load early or disable the guard altogether, and both are worse than the setting not existing. The full, authoritative parse of the config happens inside the worker, which is the slow step the deadline exists to guard against, so the deadline cannot come from there either.

**If re-injection fails outright** — rather than merely running slowly — you are told that instead, with the exit code, and without the suggestion to re-send the prompt, because re-sending cannot help when the loader is broken. The usual cause is an incomplete install: run `/mmry:load-memories` to rebuild the cache, and reinstall the plugin if that does not clear it. Either way the turn still proceeds, and Claude is told not to claim it is following directives it never received.

Both failures are recorded in `mmry-foundation.log` in your temp directory. Setting `MMRY_DEBUG=1` additionally captures the hook's internal stderr to `mmry-foundation-debug.log` alongside it. Neither is ever printed to your terminal, in debug mode or out of it.

## What It Does

| When | What Happens |
|------|-------------|
| **Session starts** | Your memories load automatically via API (Foundation + directory-matched) |
| **Every prompt** | Foundation memories are re-injected so they consistently guide responses (configurable; see Configuration) |
| **Session ends** | Claude is prompted to save any decisions, issues, or notes before exiting. Claude Code only: on Codex this prompt arrives with your next message instead, and only when something is unsaved |
| **Context compresses** | Claude saves a "Session Continuity" memory so nothing is lost. Claude Code only: Codex gives a plugin no channel at that moment |
| **Plan accepted** | Claude saves the accepted plan as a Decision memory. Claude Code only: Codex has no plan-accepted tool to trigger on |

## Commands

- `/mmry:save` — Save a memory (or just say "remember this")
- `/mmry:setup` — Run or re-run the account setup flow
- `/mmry:load-memories` — Manually reload memories mid-session (e.g., after switching context)

## Skill

- `/mmry:memory-system` — Full documentation on how to store, retrieve, search, link, and manage memories

## Auto-Updates

When installed from the GitHub marketplace, the plugin updates automatically when new versions are pushed.
