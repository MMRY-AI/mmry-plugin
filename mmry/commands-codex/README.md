# There are deliberately no commands here

This directory is named by `.codex-plugin/plugin.json` as the plugin's `commands` path, and it
contains no command files on purpose.

**Why it exists rather than being omitted.** When a Codex plugin manifest does not name a `commands`
path, Codex falls back to `<plugin-root>/commands`
(`codex-rs/core-plugins/src/command_migration/plugin.rs`, `PLUGIN_COMMANDS_DIR = "commands"`). That
is the Claude Code command directory, and pointing Codex at it would be wrong in both directions: it
would try to convert nine files written for a different host, and any future edit made for Codex's
benefit would change what Claude Code customers see. Naming an empty directory is how this plugin
says "no migrated commands" in a way that cannot drift.

**Why this file is safe to leave here.** The migrator skips a file whose stem is `README`
outright (`command_skill_name_if_supported` in `codex-rs/core-plugins/src/command_migration.rs`
returns `None` for it before anything else is considered), so this file is never converted into a
skill.

**What Codex customers get instead.** Skills, in `../skills-codex/`. Codex does not give plugins
typed slash commands at all: it converts a plugin's `commands/*.md` into skills, which the model
chooses to use rather than the customer typing. Given that, authoring skills directly is both
honest and better - a migrated command carries template syntax (`$ARGUMENTS`, `@file`) that has no
meaning once there is nobody typing arguments, and the migrator rejects a file containing it.

See `docs/codex.md` for the customer-facing statement of what is and is not available here.
