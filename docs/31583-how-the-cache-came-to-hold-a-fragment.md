# 31583 requirement 1: how the stored copy came to hold a fragment

Requirement 1 of 31583: Standing directives were replaced by a four-character stub and the
product sent it to the assistant as authoritative asks that this be established and
recorded, and says plainly that if it cannot be answered, the answer is to say so and state
which possibilities were separated and which were not. This is that record.

**Short answer: the plugin's own writer did not write it. Which process did is not
established, and cannot be from the evidence still on the machine.**

## The observed state

The cache at the fixed path in the shared temp directory held four bytes, the literal
`- x`, while the account held twelve Foundation directives. Measured on the same machine on
2026-09-18: the rebuilt cache is 6,279 bytes, 33 newlines, and its first directive begins
`- Cite Task Title with Task #:`.

## What was separated, and how

### 1. The plugin's writer, any version. REFUSED, on format.

Every line the writer emits comes from one jq expression:

    "- \(.topic): \(.content)"

A rendered line therefore always carries a topic followed by `: `. `- x` has no colon, so
it is not output of this expression for any input. There is no memory an account could hold
that renders to `- x`.

### 2. The old writer's truncating redirect, as a partial write. REFUSED, on content.

The pre-fix form was `printf '%s' "$resp" | jq -r '...' > "$cache" 2>/dev/null || true`.
The shell sets up the redirect before jq runs, so the cache is emptied first. That is a real
defect, and it is fixed on this branch, but it does not produce this fragment. Measured, by
replaying the old line against two failure modes:

| Failure mode | What the old writer left |
|---|---|
| jq fails at once (bad input, missing binary, killed early) | **0 bytes**, cache destroyed |
| jq killed part way through the first line | **15 bytes**, `- Cite Task Tit` |

A truncated write is a prefix of the account's real first directive. `- x` is not a prefix
of it. So the writer explains how a good cache gets destroyed, which is worth fixing on its
own and is fixed, but not how this particular content arrived.

### 3. The automated tests. NOT fully separated, but narrowed.

The ticket records that this hypothesis was tested and refused on the grounds that the suite
writes to an isolated location. Two further pieces of evidence, neither conclusive:

- The literal `- x` appears exactly once in the entire history of this repository, in
  commit 924071c on this branch, dated 2026-09-18, which is the test written to reproduce
  the incident **after** it was filed. `git log --all -S"'- x"` returns that commit and no
  other. Nothing in the suite wrote that string before the incident.
- `TMPDIR` has been overridden in `tests/helpers/test-helper.bash` since the rebrand commit
  702898c, long predating the incident, and HOME isolation that a suite cannot decline was
  added in b829385 on 2026-09-16, two days before.

What this does not rule out is a command run by hand, or by an agent, outside the suite.

### 4. Another process writing a fixed name in a shared temp directory. NOT separated.

The cache is a fixed filename in a directory anything on the machine can write. Nothing
recorded who wrote it, and nothing now on the machine can attribute it after the fact. This
possibility remains open and, on the evidence available, cannot be closed.

## Why the product no longer depends on the answer

The manifest makes attribution unnecessary for safety. The writer records what it wrote and
the reader refuses anything that is not byte for byte that, so a file written by something
else is refused whatever wrote it and whatever it contains. That is the part that had to be
true regardless of which of possibilities 3 and 4 actually occurred.

The finding that matters for the product is therefore not "process P did it" but that the
product had no way to tell its own output from anything else's, and now does.
