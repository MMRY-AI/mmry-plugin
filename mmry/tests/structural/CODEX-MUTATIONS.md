# The #31245 mutation evidence

Four test files in this suite carry a header saying every assertion in them was seen to REFUSE.
That claim pointed at `codex-mutation-log.md` and `codex-mutation-manifest.md`, **neither of which
was ever committed**. A claim about your own verification that points at a missing document is
worth less than no claim, so this is the document, and it is committed beside the harness that
produces it.

- The harness: [`run-codex-mutations.sh`](run-codex-mutations.sh)
- Run it: `bash mmry/tests/structural/run-codex-mutations.sh` from a clean working tree
- A dry run that only checks the mutations still apply:
  `MMRY_BATS_BIN=/path/to/a/stub bash mmry/tests/structural/run-codex-mutations.sh`

## What a mutation run is, and what it is not

Each experiment applies one deliberate break to the product, runs the test file that is supposed to
notice, and records whether it did. Three outcomes, and they must never be collapsed:

| Outcome | Meaning |
|---|---|
| `REFUSED` | The named test failed. The assertion can fail, so its passing means something. |
| `SURVIVED` | The break was applied and every test still passed. **The assertion cannot fail.** |
| `NOT APPLIED` / `HARNESS ERROR` | The experiment could not be performed. This says nothing at all about the assertion, and must not be read as a result. |

The first version of the harness counted the third case into the number it printed as "survived".
That is why three people got three different answers from the same commit.

## Why the first harness was not reproducible

Recorded here because the next person to disbelieve a mutation result will want to know what was
already ruled out.

| # | Cause | Evidence |
|---|---|---|
| 1 | An experiment that could not be **performed** was counted as a surviving mutant | `NOT APPLIED` incremented `FAIL`, and the summary printed `FAIL` as "survived". A reviewer re-ran the five "survivors" individually and every one reproduced as REFUSED. |
| 2 | The interpreter was unpinned | `python` on this machine is 2.7.2; `python3` is 3.12. Two reviewers ran two different languages against the same fragments. |
| 3 | Pinning by NAME was still not enough | `python3` here is the Windows Store app execution alias. It answers `-c`, reports 3.12, and then ignores the `-` that means "read the program from stdin", running `argv[1]` instead — a `.sh` file, whose shebang it tried to launch. Exit 127 on all 50 experiments, reported as 50 harness errors. The harness now resolves `sys.executable` and *proves* the stdin form works before trusting it. |
| 4 | Any interpreter failure looked like a missing pattern | Exit 3 (pattern absent) was conflated with every other non-zero exit, and the interpreter's own error message was discarded. |
| 5 | Line endings | `.gitattributes` pinned `*.sh` only, so with `core.autocrlf=true` every `.json`, `.md` and `.bats` file in the tree is CRLF and every mutation pattern spanning a newline silently missed. Demonstrated on one commit: the `stop-check` mutations apply against an LF tree and report `MUTATION DID NOT APPLY` against a CRLF one. Matching is now done on a normalised copy. |
| 6 | A killed run left a mutation in the tree | There was no `EXIT` trap. A run stopped by an impatient timeout left the product broken on disk, so the next run started from a state nobody chose — and the dirty-tree guard then refused it, which looks like a different failure entirely. |

A truncated run is now visibly truncated: every line is numbered `[i/N]` and the summary says
`ran R of N` and prints `INCOMPLETE` when they differ. Two of the three original reports (25 and 20
experiments against 37 defined) were truncated runs being read as results.

## Coverage

Sixty-nine experiments across:

- `hooks-handlers/lib-host.sh` — the requirement-4 literals, host detection, the credential refusal
- `hooks-handlers/codex-hook.sh` — the Codex entry point
- `hooks-handlers/lib-jq.sh` — where the host resolver is pulled in and the credential is asserted
- `hooks-handlers/hook-guard.sh`, `stop-check.sh`, `formation-check.sh` — the shared handlers
- `hooks-handlers/session-init.sh`, `session-start.sh` — **added in QA round 2**; both reviewers
  found these had no mutation coverage at all
- `hooks/codex-hooks.json`, `.codex-plugin/plugin.json` — the registration and the manifest
- `setup/mmry-setup.sh` — the one command a new Codex customer runs
- `commands/setup.md`, `tests/e2e/setup-join.bats` — the requirement-4 guards on the Claude surface

- `setup/uninstall.sh`, `setup/uninstall.bat` - **added in QA round 3**; the Codex copy of the
  shell uninstaller destroyed the Claude Code installation, and the Windows guard did not fire on
  a relocated Codex home at all
- `hooks-handlers/self-update.sh` - **added in QA round 3**; it overwrote the other product's
  plugin root from a Codex session
- `hooks-handlers/formation-join.sh`, `formation-start.sh` - **added in QA round 3**; both
  registered every session as `claude-code`
- `docs/codex.md` - **added in QA round 3**; the customer-facing page is the only file mutated
  from outside `mmry/`, which is why the harness now understands a `../` path

## What is NOT covered by any mutation, and why

Stated here so the next reviewer does not have to derive it from absence.

- **The Codex hook payload field names.** `session_id` and `hook_event_name` are Claude Code's
  names. No captured Codex payload exists, so no mutation can prove what happens when Codex sends
  something else. What the handlers now do instead is say so out loud: see the absent-field
  warnings in `session-start.sh` and the breadcrumb in `formation-check.sh`, asserted in
  `tests/handlers/codex-session.bats`. This is a stated assumption, not a verified fact, and one
  real captured payload retires it.
- **Codex itself.** Every route asserted here comes from Codex's own generated schemas and event
  handlers, cited in the test headers. Nothing in this suite runs Codex.

## Runs

| Date | Machine | Result |
|---|---|---|
| 2026-09-16 | Windows 11, Git Bash, CPython 3.12.7, bats 1.13.0 | 49 refused, 1 survived, 0 not performed, 50 of 50 run. The survivor is analysed below and is now closed. |
| 2026-09-16 (QA round 3) | Windows 11, Git Bash, CPython 3.12.7, bats 1.13.0 | 66 refused, 2 survived, 1 not performed, 69 of 69 run. **All three were faults in the EXPERIMENTS, not findings about the tests.** Each was corrected and re-run individually; all three now REFUSE. Detail below. |

### 2026-09-16 (QA round 3) - nineteen new experiments, and what the run found

    === refused: 66   survived: 2   experiments not performed: 1   (ran 69 of 69) ===

Nineteen experiments were added, one for each behaviour changed in QA round 3. The run reported
three problems, and all three were mine rather than the tests':

| Reported | Experiment | What was actually wrong |
|---|---|---|
| NOT APPLIED | session-init writes no host marker | The fragment carried a real newline where the file has the two characters `backslash n` inside a `printf` format string, so the pattern was never in the file. It now redirects the marker write to `/dev/null`. |
| SURVIVED | setup exports its opt-out into everything it spawns | The mutation added `export` but left the `unset` two lines below, so there was nothing left to leak and the test was right to pass. The defect it guards against is the pair; the mutation now removes both. |
| SURVIVED | the Codex skill stops being a document about Codex | Renaming every `Codex` to `Cldx` does not make the file a copy of the Claude Code skill, and the assertion it was aimed at is satisfied by the lower-case `.codex` paths that remain. It now copies the Claude Code skill over it, which is the property the test is about. |

One more label had drifted: `formation-check stops guarding the credential` reported `REFUSED(*)` -
refused, but not by the test the harness named - because the expectation still said "no formation
pays nothing" while the test that fails is "an unconfigured Codex install makes this hook silent,
not noisy". The expectation was corrected.

After the four corrections each was re-run on its own, with the new filter:

    MMRY_MUTATION_FILTER="host marker"                    -> refused: 1  survived: 0
    MMRY_MUTATION_FILTER="opt-out into everything"        -> refused: 1  survived: 0
    MMRY_MUTATION_FILTER="byte-for-byte copy"             -> refused: 1  survived: 0
    MMRY_MUTATION_FILTER="formation-check stops guarding" -> refused: 1  survived: 0

`MMRY_MUTATION_FILTER` is new in this round: a full run is over two hours on Windows, and a
reviewer checking one finding should not have to sit through the other sixty-eight. A filtered run
prints `FILTERED RUN` and does not present itself as a complete one.

**The 69 experiments as the run reported them**, before those four corrections:

| # | Verdict | Mutation |
|---|---|---|
| 1/69 | REFUSED | claude config dir drifts |
| 2/69 | REFUSED | claude client name becomes codex |
| 3/69 | REFUSED | claude script ref becomes absolute |
| 4/69 | REFUSED | default host becomes codex |
| 5/69 | REFUSED | CODEX_HOME ignored |
| 6/69 | REFUSED | codex script ref keeps the variable |
| 7/69 | REFUSED | the double-source guard becomes a no-op |
| 8/69 | REFUSED | shim stops declaring the host |
| 9/69 | REFUSED | shim drops the path-separator guard |
| 10/69 | REFUSED | shim swallows the handler exit code |
| 11/69 | REFUSED | PreCompact gets registered |
| 12/69 | REFUSED | a handler gains asyncRewake |
| 13/69 | REFUSED | the PostToolUse group gains a matcher |
| 14/69 | REFUSED | a handler loses commandWindows |
| 15/69 | REFUSED | a command bypasses the codex entry point |
| 16/69 | REFUSED | the formation poller is registered on Stop |
| 17/69 | REFUSED | additionalContextLimit is emitted |
| 18/69 | REFUSED | Windows command uses POSIX expansion |
| 19/69 | REFUSED | an unknown event name is registered |
| 20/69 | REFUSED | codex manifest points at the Claude skills dir |
| 21/69 | REFUSED | codex manifest points at the Claude hooks file |
| 22/69 | REFUSED | codex manifest hardcodes a version |
| 23/69 | REFUSED | a manifest path loses its ./ prefix |
| 24/69 | REFUSED | codex manifest inherits the default commands dir |
| 25/69 | REFUSED | the compaction sentence fires on Claude Code too |
| 26/69 | REFUSED | the compaction sentence never fires |
| 27/69 | REFUSED | the save prompt stops exiting 2 |
| 28/69 | REFUSED | codex tool delivery reverts to stderr+exit 2 |
| 29/69 | REFUSED | codex idle guard removed, so the poller waits |
| 30/69 | REFUSED(*) | formation-check stops guarding the credential, so a hot-path hook exits 1 |
| 31/69 | REFUSED | a Claude command file gains frontmatter |
| 32/69 | REFUSED | the e2e fixture stops copying lib-host |
| 33/69 | REFUSED | lib-host stops reading the host off its own location |
| 34/69 | REFUSED | lib-host stops exporting MMRY_CONFIG_FILE |
| 35/69 | REFUSED | lib-jq stops sourcing the host resolver |
| 36/69 | REFUSED | location detection overreaches to any CODEX_HOME in the environment |
| 37/69 | REFUSED | hook-guard loses its missing-resolver fallback |
| 38/69 | REFUSED | stop-check loses its missing-resolver fallback |
| 39/69 | REFUSED | lib-jq stops asserting, so the client walks on to the Claude file |
| 40/69 | REFUSED | the assertion always passes |
| 41/69 | REFUSED | the refusal goes quiet |
| 42/69 | REFUSED | the refusal fires on Claude Code too |
| 43/69 | REFUSED | session-init installs into the Claude directory on every host |
| 44/69 | REFUSED | session-init stops copying the Windows entry point |
| 45/69 | REFUSED | session-init loses the pipefail guard on the plugin-root search |
| 46/69 | REFUSED | session-start registers every session as claude-code |
| 47/69 | REFUSED | session-start sources the client before asking about the credential |
| 48/69 | REFUSED | session-start stops reporting an absent session_id field |
| 49/69 | REFUSED | setup forces the host to claude before resolving |
| 50/69 | REFUSED | setup loses its opt-out and can no longer run before a credential exists |
| 51/69 | REFUSED | the shell uninstaller stops refusing on Codex |
| 52/69 | REFUSED | the shell uninstaller destroys the other product's state dir again |
| 53/69 | REFUSED | lib-host stops reading the install marker |
| 54/69 | REFUSED | the marker names the host but not the place |
| 55/69 | REFUSED | any marker content is read as codex |
| 56/69 | REFUSED | the drive-letter spelling is no longer normalised |
| 57/69 | NOT | APPLIED  session-init writes no host marker |
| 58/69 | REFUSED | self-update updates the Claude directory from a Codex session |
| 59/69 | REFUSED | self-update loses its credential opt-out and dies silently |
| 60/69 | REFUSED | the Windows guard forgets the install marker |
| 61/69 | REFUSED | the Windows guard forgets CODEX_HOME |
| 62/69 | REFUSED | the Windows guard refuses on any marker at all |
| 63/69 | REFUSED | the customer-facing page goes back to a hard-coded path |
| 64/69 | REFUSED | the 401 reply names a slash command on Codex too |
| 65/69 | REFUSED | formation-join registers every session as claude-code |
| 66/69 | REFUSED | formation-start registers every session as claude-code |
| 67/69 | SURVIVED | setup exports its opt-out into everything it spawns |
| 68/69 | REFUSED | the tool-call delivery handler does nothing at all |
| 69/69 | SURVIVED | the Codex skill stops being a document about Codex |


### 2026-09-16 — Windows 11, Git Bash, CPython 3.12.7, bats 1.13.0

    === refused: 49   survived: 1   experiments not performed: 0   (ran 50 of 50) ===

**The one survivor was a real finding, and it was mine.** `formation-check stops guarding the
credential, so a hot-path hook exits 1` was applied and every test in
`structural/codex-formation-delivery.bats` still passed, because every other test in that file
supplies a credential through the environment and therefore never reaches the guard. The guard is
what keeps an unconfigured Codex install from producing a failing hook after every single tool
call. Two assertions were added - the silent case and its control - and the same mutation was then
applied by hand and seen to fail the named test. That pair is experiment 30 in the current harness.

The two mutations the QA round flagged as UNPROVEN - `lib-host stops reading the host off its own
location` (33) and `hook-guard loses its missing-resolver fallback` (37) - both REFUSED in this
run. They were never survivors; they were experiments the old harness had failed to perform.

| # | Verdict | Mutation |
|---|---|---|
| 1/50 | REFUSED | claude config dir drifts |
| 2/50 | REFUSED | claude client name becomes codex |
| 3/50 | REFUSED | claude script ref becomes absolute |
| 4/50 | REFUSED | default host becomes codex |
| 5/50 | REFUSED | CODEX_HOME ignored |
| 6/50 | REFUSED | codex script ref keeps the variable |
| 7/50 | REFUSED | the double-source guard becomes a no-op |
| 8/50 | REFUSED | shim stops declaring the host |
| 9/50 | REFUSED | shim drops the path-separator guard |
| 10/50 | REFUSED | shim swallows the handler exit code |
| 11/50 | REFUSED | PreCompact gets registered |
| 12/50 | REFUSED | a handler gains asyncRewake |
| 13/50 | REFUSED | the PostToolUse group gains a matcher |
| 14/50 | REFUSED | a handler loses commandWindows |
| 15/50 | REFUSED | a command bypasses the codex entry point |
| 16/50 | REFUSED | the formation poller is registered on Stop |
| 17/50 | REFUSED | additionalContextLimit is emitted |
| 18/50 | REFUSED | Windows command uses POSIX expansion |
| 19/50 | REFUSED | an unknown event name is registered |
| 20/50 | REFUSED | codex manifest points at the Claude skills dir |
| 21/50 | REFUSED | codex manifest points at the Claude hooks file |
| 22/50 | REFUSED | codex manifest hardcodes a version |
| 23/50 | REFUSED | a manifest path loses its ./ prefix |
| 24/50 | REFUSED | codex manifest inherits the default commands dir |
| 25/50 | REFUSED | the compaction sentence fires on Claude Code too |
| 26/50 | REFUSED | the compaction sentence never fires |
| 27/50 | REFUSED | the save prompt stops exiting 2 |
| 28/50 | REFUSED | codex tool delivery reverts to stderr+exit 2 |
| 29/50 | REFUSED | codex idle guard removed, so the poller waits |
| 30/50 | SURVIVED | formation-check stops guarding the credential, so a hot-path hook exits 1   <-- THIS ASSERTION CANNOT FAIL |
| 31/50 | REFUSED | a Claude command file gains frontmatter |
| 32/50 | REFUSED | the e2e fixture stops copying lib-host |
| 33/50 | REFUSED | lib-host stops reading the host off its own location |
| 34/50 | REFUSED | lib-host stops exporting MMRY_CONFIG_FILE |
| 35/50 | REFUSED | lib-jq stops sourcing the host resolver |
| 36/50 | REFUSED | location detection overreaches to any CODEX_HOME in the environment |
| 37/50 | REFUSED | hook-guard loses its missing-resolver fallback |
| 38/50 | REFUSED | stop-check loses its missing-resolver fallback |
| 39/50 | REFUSED | lib-jq stops asserting, so the client walks on to the Claude file |
| 40/50 | REFUSED | the assertion always passes |
| 41/50 | REFUSED | the refusal goes quiet |
| 42/50 | REFUSED | the refusal fires on Claude Code too |
| 43/50 | REFUSED | session-init installs into the Claude directory on every host |
| 44/50 | REFUSED | session-init stops copying the Windows entry point |
| 45/50 | REFUSED | session-init loses the pipefail guard on the plugin-root search |
| 46/50 | REFUSED | session-start registers every session as claude-code |
| 47/50 | REFUSED | session-start sources the client before asking about the credential |
| 48/50 | REFUSED | session-start stops reporting an absent session_id field |
| 49/50 | REFUSED | setup forces the host to claude before resolving |
| 50/50 | REFUSED | setup loses its opt-out and can no longer run before a credential exists |

After the survivor was closed, the affected experiment was re-run individually:

    mutation applied
    not ok 1 codex: an unconfigured Codex install makes this hook silent, not noisy
    (restored)
    ok 1 codex: an unconfigured Codex install makes this hook silent, not noisy

