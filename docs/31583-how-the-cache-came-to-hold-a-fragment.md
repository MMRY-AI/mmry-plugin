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

- The literal `- x` appears in eight commits repo-wide as of 2026-10-02, six of them under
  `mmry/` (`git log -S'- x'`). The count has been wrong twice: this section first quoted one,
  scoped to `mmry/` without saying so, then three, and QA round 5 measured eight. Every one of
  the eight cites #31583 in its message, so every one was written after the ticket the incident
  produced was filed. Nothing in the repository wrote that string before the incident, which is
  the point that matters and is unchanged.
- `TMPDIR` has been overridden in `tests/helpers/test-helper.bash` since the rebrand commit
  702898c, long predating the incident, and HOME isolation that a suite cannot decline was
  added in b829385 on 2026-09-16, two days before.

What this does not rule out is a command run by hand, or by an agent, outside the suite.

### 4. Another process writing a fixed name in a shared temp directory. NOT separated.

The cache is a fixed filename in a directory anything on the machine can write. Nothing
recorded who wrote it, and nothing now on the machine can attribute it after the fact. This
possibility remains open and, on the evidence available, cannot be closed.

## Why the product no longer depends on the answer

The manifest makes attribution unnecessary for THIS failure. The writer records what it
wrote and the reader refuses a cache that is not byte for byte what its record describes. The
observed artefact was a four-byte cache beside nothing that described four bytes, so whichever
of possibilities 3 and 4 produced it, it is now refused and reported rather than delivered.

What the manifest does NOT do, corrected after QA round 4 showed the earlier wording claimed
it: it is a plaintext checksum written beside the cache by anything able to write the cache.
A process that replaces the cache AND writes a matching manifest is accepted, and Compliance
demonstrated exactly that. So the claim is mutual consistency, not provenance. The product can
now tell a damaged, truncated, half-written or orphaned copy from a sound one. It still cannot
tell its own output from a deliberate impostor's, and nothing in a shared, world-writable temp
directory can, without a key or a private location. Restricting where these files live and who
may write them is recorded as its own piece of work rather than claimed here.

## What is deliberately NOT closed here, and where it lives

**The torn read is #31597, and it is scheduled in this release rather than deferred.**

The cache and the manifest are two files. Each is replaced safely on its own, so neither is
ever half-written, but there is no way to replace BOTH as one act. A reader arriving between
the two renames sees a new manifest against an old cache, refuses a set that is in fact
healthy, and the turn runs with no directives. QA measured it at 225 of 2,808 reads, about 8
percent, on a live refresh loop.

It was attempted inside this ticket and reverted, which produced two results worth keeping,
because the obvious fix is not sufficient on its own:

- Storing everything in ONE self-describing file removes the disagreement, but measured
  WORSE than the two-file arrangement on its own: 46 of 177 reads refused, 26 percent,
  because the reader opened that single file three times during one check.
- Reading the whole file once into memory and answering every question from that one copy
  took it to 0 refusals in 290 reads. Both halves are required.

The change also alters what several verifier states MEAN, so about a dozen checks need
rewriting rather than re-fixturing; thirty were measured red against the attempted version.
That is why it is its own task rather than a fix inside this one.

**Related, and not closed here either:** a torn or otherwise bad manifest has no recovery
path, so it warns on every prompt by the same shape the no-manifest case did until it was
given one. Raised by QA round 4 and recorded here so the next person reading this file finds
it beside the defect rather than only in a ticket.
