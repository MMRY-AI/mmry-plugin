# MMRY AI Plugin for Claude Code and OpenAI Codex

Persistent memory system that gives your assistant long-term recall across sessions.

Using **OpenAI Codex**? Start at **[docs/codex.md](docs/codex.md)** - installation, setup, the
supported surface, and uninstall all differ from the Claude Code instructions below.

| What happens | Claude Code | OpenAI Codex |
|---|---|---|
| Your memories load at session start | yes | yes |
| Foundation memories restated on every prompt | yes | yes |
| Coordination-group messages delivered as you work | yes | yes |
| A prompt to save what is new | at session end | on your next message, when something is unsaved |
| Continuity notes saved before the context is compressed | yes | no channel at that moment |
| An accepted plan saved as a decision record | yes | no plan-accepted event to trigger on |

[docs/codex.md](docs/codex.md) states each Codex gap and what you get instead.

## Setup (macOS)

Copy and paste each step into Terminal. Wait for each step to finish before moving to the next.

### 1. Install Xcode Command Line Tools

```bash
xcode-select --install
```

A popup will appear — click **Install** and wait for it to finish. If it says "already installed", move on.

### 2. Install Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow any prompts. If it says Homebrew is already installed, move on.

> **Important:** After install, Homebrew may tell you to run two commands to add it to your PATH. Copy and run those commands before continuing.

### 3. Install Node.js

```bash
brew install node
```

Verify:
```bash
node --version
```
Should show v22 or higher (anything 18+ is fine).

### 4. Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

Launch and sign in with your Anthropic account:
```bash
claude
```

Once signed in, type `/exit` to close.

### 5. Install the MMRY AI plugin

Launch Claude Code:
```bash
claude
```

Run these two commands inside Claude Code:
```
/plugin marketplace add MMRY-AI/mmry-plugin
/plugin install mmry@mmry-plugin
```

Type `/exit` to close.

### 6. Set up your account

Launch Claude Code:
```bash
claude
```

Claude will detect that MMRY AI is installed but not configured and run setup automatically. It opens your browser so you can log in or create an account on mmryai.com, then configures everything.

If the automatic prompt doesn't appear, type `/mmry:setup` to start manually.

### 7. Restart Claude Code

Type `/exit`, then:
```bash
claude
```

Done! MMRY AI is active. On your first session, Claude will help you create your initial memories. Type `/mmry:help` anytime for a quick reference.

## Setup (Windows)

### 1. Install Node.js

Download from [nodejs.org](https://nodejs.org/) (LTS version). Run the installer with default settings.

### 2. Install Git for Windows

Download from [git-scm.com](https://git-scm.com/download/win). Run the installer with default settings. This provides Git Bash, which the plugin requires.

### 3. Install Claude Code

Open a terminal and run:
```bash
npm install -g @anthropic-ai/claude-code
```

Then follow Steps 4–7 from the macOS instructions above.

## Setup (Existing Claude Code Users)

If you already have Claude Code installed:

```
/plugin marketplace add MMRY-AI/mmry-plugin
/plugin install mmry@mmry-plugin
```

Restart Claude Code. Claude will guide you through setup automatically. Restart again after setup completes. Done.

## Auto-Updates

When installed from the GitHub marketplace, the plugin updates automatically whenever a new version is pushed. No action needed.

## Documentation

See the [plugin README](mmry/README.md) for full documentation on configuration, commands, and the memory skill.

## License

MIT
