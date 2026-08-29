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

Refuse to review when `HEAD` is not the candidate SHA, the worktree is dirty, the base cannot be
resolved, or the candidate is not a descendant of the base. A later commit invalidates this result.

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

Reject a candidate finding when it is speculative, pre-existing outside the task diff, contradicted
by repository policy, or unsupported by a concrete failure path. Preserve valid findings even when
another reviewer missed them.

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

Return exactly one verdict after the complete finding list:

- `REQUEST_CHANGES <candidate SHA>` when any validated `P0`-`P2` finding remains;
- `APPROVE <candidate SHA>` only when no validated blocking finding remains.

List `P3` findings even with `APPROVE`; `/cc-tuner:run` must record each as fixed, refuted, or
explicitly deferred. Never convert a tool failure, timeout, reviewer cap, or partial lens coverage into
approval. State which lens was incomplete and return `REQUEST_CHANGES`.

Any fix makes this verdict stale. Under `/run`, verify the affected findings and let the authoritative
review judge the final SHA; do not restart all six advisory lenses. A user who directly requested a
new exhaustive review may run the skill again.
