---
name: deep-review
description: Exhaustively review a clean, committed candidate through six independent lenses. Use for large, cross-boundary, or sensitive changes selected by /run; do not use for an ordinary small task.
---

# Deep Review

Review an immutable candidate, not a moving worktree. Find every material problem the evidence supports;
never stop at an arbitrary count. This skill is read-only: report findings, but do not edit code.

## Inputs

Require literal values for:

- candidate commit SHA;
- base commit or target ref;
- committed spec path, when the task has one.

Resolve a supplied target ref to a literal base SHA. If the target has advanced beyond the candidate,
return that fact to the caller for branch synchronization before review; do not rebase or merge in
this read-only skill. Refuse a dirty/mismatched candidate or an unresolved/unrelated base. A later
commit invalidates this result. `/run` prepares and synchronizes the candidate before invoking review.

## Build the review packet

Read before judging:

1. the issue/spec and its acceptance, scope, DoR, test plan, and DoD;
2. `CLAUDE.md`, `AGENTS.md`, applicable rules, and architecture records;
3. the complete `git diff --find-renames <base>...<candidate>` and changed-file list;
4. changed code in context, its callers/consumers, tests, schemas, generated artifacts, and config;
5. verification evidence already produced for this exact candidate.

Do not infer correctness from green CI, a plan checkbox, another review, or the author's summary.

## Review lenses

Run every applicable lens independently and fan them out against the immutable candidate. `/run`
owns the decision to invoke this expensive workflow; once selected, `deep-review` does not degrade
into a second lightweight review.

Before dispatching, write what every lens will read, once, into a scratch directory the briefs can
name: the full diff (`git diff --find-renames <base>...<candidate> > <dir>/candidate.diff`) and the
changed-file list (`git diff --name-status <base>...<candidate> > <dir>/changed-files.txt`). A lens
has no shell, so this is the only way the diff reaches it; it also means six lenses read one file
instead of generating the diff six times.

Dispatch each lens as its own `cc-tuner:deep-review-lens` subagent with the Agent tool, all in one
message. The agent definition (`agents/deep-review-lens.md`) is what makes a lens read-only: its
tool list is `Read, Grep, Glob`, with `Bash`, `Edit`, `Write`, `NotebookEdit` and `Agent` withheld,
so the constraint holds by the tool list and not by the brief, and it runs on `sonnet`. There is no
fallback type: if the host does not list `cc-tuner:deep-review-lens`, the review is incomplete by
construction, and the verdict below says so and returns `REQUEST_CHANGES` — a `general-purpose`
reader would hold every tool the definition withholds, and putting the constraint back into prose
is exactly what this definition replaced. One message for all six is also what lets their first
requests share one cache prefix. Escalate a lens the way `placement.md` escalates any unit — on a
returned result you can point at, not on a feeling about the codebase. A lens is a reading job over
a tree nobody is changing, which is why it may fan out at all — and each brief still carries the
literal candidate SHA, base ref, spec path, the two file paths and the finding format, because a
subagent sees none of this session. What must not fan out is the aggregation
below: one owner reads every lens's findings and produces one verdict.

Say the cost when `/run` selects this route. Each lens is a fresh context: measured on one
repository, a `general-purpose` spawn carried 34k–42k tokens of system prompt, tools and CLAUDE.md
before reading a line of the diff, so six lenses are on the order of 200k tokens of overhead plus
six reads of the diff and spec. That is the price of six independent readers, and it is why the
trigger in `/run` is large or sensitive changes only.

## Sharding

A lens cannot hold a large diff, and since 0.14.0 it cannot spawn help either, so the one that used to
build a rig of its own would now read part of the candidate and report as if it had read all of it.
The owner decides the cut, and the arithmetic is a script, not a sentence:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/shard-diff.sh" <base> <candidate> [--plan <plan>] [--max 4] [--files 300] [--lines 10000]
```

It prints `SIZE`, `MODE	single|sharded` and, when sharded, one `SHARD	<n>	<key>	<path,...>` per
shard: grouped by the plan's Owned paths through `plan-lint.sh owned` (unmatched files in `rest`), or
by first path component without a plan; a group that itself reaches a threshold is split into chunks
below it (`src#1`, `src#2`), and groups are merged smallest-into-neighbour while the pair stays below
the thresholds and more than four remain. A rename is listed with both of its paths. The script
refuses, with exit 1 and nothing on stdout, a bad ref, a path its grammar cannot carry, and a
candidate that cannot be covered in four shards below the thresholds — the message says how many it
needs, and raising `--max` is the owner's stated decision, not a default. Treat any refusal as a
refusal, not as `single`. Run it before any lens is dispatched. `MODE	single` means the dispatch
above, unchanged.

When sharded, write for every `SHARD` line, next to `candidate.diff`:
`git --literal-pathspecs diff --find-renames <base>...<candidate> -- <paths> > <dir>/shard-<n>.diff`
and `git --literal-pathspecs diff --name-status <base>...<candidate> -- <paths> > <dir>/shard-<n>-files.txt`,
with the script's path list after `--`. `--literal-pathspecs` is load-bearing: `--` stops option
parsing but not pathspec magic, so a file named `:(exclude)x` would otherwise silently drop files
from the packet. Then dispatch **Correctness**, **Repository standards**, **Security**
and **Tests and operability** once per shard, each brief naming that shard's two files and nothing
else of the diff; dispatch **Specification and scope** and **Architecture** once, on the whole
`candidate.diff` and `changed-files.txt`, because their question does not cut along paths. That is
`shards × 4 + 2` agents; say the number and the spawn overhead (each lens is a fresh 34k–42k-token
context) before the first dispatch, so the spend is chosen and not discovered. A lens never cuts its
own shard and never delegates reading; the definition withholds `Agent` for that reason.

Aggregation does not change shape: one owner reads every shard's findings and validates them below.
Deduplicate across shards by cause — the same missing check reported from two shards is one finding
with two evidence lines, not two findings.

Keep the lifecycle outside the review sequential and give every reviewer the same literal base,
candidate, spec, and read-only constraint.

1. **Correctness and edge cases** — logic, state transitions, concurrency, errors, cleanup,
   compatibility, and user-visible behavior.
2. **Specification and scope** — every acceptance criterion and task is actually satisfied; no
   accidental scope, missing consumer, or claim unsupported by the diff.
3. **Repository standards** — applicable instructions, idioms, dependency direction, public API
   conventions, migrations, generated outputs, and release requirements.
4. **Architecture and systemic effects** — ownership, boundaries, coupling, data/control flow,
   invariants, duplicated policy, extensibility, and downstream/upstream consumers.
5. **Security and data safety** — authn/authz, secrets, injection, SSRF, traversal, unsafe parsing,
   privacy, destructive operations, trust boundaries, and rollback/recovery.
6. **Tests and operability** — regression test quality, red-before-green evidence, negative paths,
   integration/runtime coverage, observability, diagnostics, deployability, and failure recovery.

Reviewers may return any number of candidate findings. Do not ask for a top ten and do not truncate,
sample, or summarize away additional findings.

## Validate and aggregate

The owning reviewer reads every candidate finding and checks it against live source at the candidate
SHA. Deduplicate only when two findings have the same root cause and remediation. Keep distinct
symptoms when they require different fixes or prove different impact.

Reject speculative or unsupported findings and independent improvements outside the agreed outcome.
Apply the scope contract in `.claude/rules/task-flow.md`: an older defect in an untouched dependency
still matters when this task exposes it or needs its fix to meet acceptance. Preserve valid findings
even when another reviewer missed them.

For each validated finding report:

```text
<P0|P1|P2|P3> <short imperative title>
candidate: <full SHA>
evidence: <path:line and concrete behavior>
contract: <spec criterion, repo rule, or invariant>
impact: <what breaks and for whom>
fix: <smallest systemic correction>
verify: <test or observation that would prove the correction>
```

Priority meanings:

- `P0`: immediate security/data-loss/outage risk;
- `P1`: blocks the promised behavior, safe delivery, or a required contract;
- `P2`: material defect or architecture/operability regression that should be fixed before merge;
- `P3`: non-blocking maintainability or clarity improvement with concrete future cost.

## Verdict

This verdict is **advisory input to `/cc-tuner:run`, not a merge gate**, and it does not stop the run:
`/run` owns every stop in a run it started. Only the authoritative review
gates a merge, and only `merge.sh` enforces one. `REQUEST_CHANGES` here means the run must address or
concretely refute the blocking findings before it takes the candidate to that review — it does not
open a second approval loop of its own.

Return exactly one verdict after the complete finding list:

- `REQUEST_CHANGES <candidate SHA>` when any validated `P0`-`P2` finding remains;
- `APPROVE <candidate SHA>` only when no validated blocking finding remains.

List `P3` findings even with `APPROVE`; `/cc-tuner:run` must record each as fixed, refuted, or
explicitly deferred. Never convert a tool failure, timeout, reviewer cap, or partial lens coverage into
approval. State which lens was incomplete and return `REQUEST_CHANGES`.

Any fix makes this verdict stale. Under `/run`, verify the affected findings and let the authoritative
review judge the final SHA; do not restart all six advisory lenses. A user who directly requested a
new exhaustive review may run the skill again.
