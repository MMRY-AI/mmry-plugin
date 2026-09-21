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

### 1. The plugin's writer, any version. REFUSED, but on a narrower argument than I first gave.

**Corrected 2026-09-21 after QA disproved the original reasoning.** This section used to say
that every line the writer emits carries a topic followed by `: `, so no memory an account
could hold could render to `- x`. That is false, and QA demonstrated it by running the
shipped writer rather than by reading it. I reproduced their counter-example:

    content = "first line
- x"   ->   cache line 1: "- Notes: first line"
                                        cache line 2: "- x"

A memory whose CONTENT contains a newline followed by that text produces exactly the stub as
a subsequent line. The unit test pinning the old claim passed only because no fixture content
contained a newline.

**The argument that does hold** is about the whole file, and it is not about the first line
either. A round-3 review falsified the first-line version by the same mechanism one field
across: with a topic of `x` followed by a newline and then `Notes`, line 1 of the output is
`- x` and carries no colon at all. That is the second time a claim here was stated more
strongly than the evidence supported, so this one is stated as the weakest thing sufficient
to settle the question, and it is checked by running the shipped filter rather than by
reading it.

The filter is `"- \(.topic): \(.content)"`, evaluated once per Foundation entry. The literal
`: ` sits between the two interpolations, so it is present in the text of EVERY entry the
writer emits, wherever newlines fall inside the topic or the content. Therefore any non-empty
file the writer produces contains `: ` at least once, and an input with no Foundation entries
produces a file of zero bytes. The observed artefact was a four-byte file, `- x` and a
newline, which is neither empty nor contains `: `. It cannot be writer output for any input.

Measured against the shipped filter, including the reviewer's own counter-example:

    case                      bytes  contains ': '   is the artefact
    reviewer topic newline       19  yes             no
    content newline              26  yes             no
    leading newline in topic      9  yes             no
    topic ends in a colon         8  yes             no
    empty topic and content       6  yes             no
    two entries                  16  yes             no
    zero entries                  0  no (0 bytes)    no

That is weaker than either earlier version and it is still sufficient to rule the writer out
as the source of what was actually seen. Both earlier versions survived a round of review
because the test guarding them could not fail, which is the real lesson here and is why this
one is pinned by a test that was proven able to refuse.

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

- The literal `- x` appears in three commits repo-wide as of 2026-09-21: 924071c, the test
  written to reproduce the incident **after** it was filed, plus 41aa1bc and 2d66b2d, which
  are this document and its evidence scripts. Scoped to `mmry/` it is one, which is the
  figure this section originally quoted without saying it was scoped. Corrected after QA
  re-ran it and got three. Nothing in the suite wrote that string before the incident, which
  is the point that matters and is unchanged.
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
