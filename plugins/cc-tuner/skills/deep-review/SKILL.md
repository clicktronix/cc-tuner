---
name: deep-review
description: Review a clean, committed candidate before delivery using independent correctness, specification, standards, architecture, systemic, security/data, and testing/operability lenses. Use when a task needs exhaustive code review bound to an exact candidate SHA, especially before a cc-tuner run can proceed to PR or merge.
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
resolved, or the candidate is not a descendant of the base. Record the candidate tree with
`git rev-parse <candidate>^{tree}`. A later commit or tree invalidates this result.

## Build the review packet

Read before judging:

1. the issue/spec and its acceptance, scope, DoR, test plan, and DoD;
2. `CLAUDE.md`, `AGENTS.md`, applicable rules, and architecture records;
3. the complete `git diff --find-renames <base>...<candidate>` and changed-file list;
4. changed code in context, its callers/consumers, tests, schemas, generated artifacts, and config;
5. verification evidence already produced for this exact candidate.

Do not infer correctness from green CI, a plan checkbox, another review, or the author's summary.

## Review lenses

Run every applicable lens independently. Always perform the review; small-diff thresholds only decide
execution shape. The owning reviewer may run all lenses serially for a candidate that changes **at most
50 lines across at most 5 files** and touches no sensitive surface. Otherwise fan them out to parallel
reviewer agents against the immutable candidate.

**The sensitive surfaces, named — because "sensitive" is not self-evident and size is not the test:**

- authentication, authorization, secrets, and cryptography;
- migrations and destructive data operations;
- public APIs, persisted schemas, and cross-service contracts;
- money, payments, pricing, billing, and entitlements;
- infrastructure, CI, deployment, and release configuration;
- security-relevant input handling: injection, SSRF, path traversal, unsafe deserialization, and
  server-side allowlists.

**Classify the surface first, and only then look at size.** Asking "is this small" before asking "what
does it touch" settles the question with the wrong fact, and the answer is then defended rather than
revisited.

**A candidate touches a sensitive surface when it changes code, values, configuration, fixtures or
schemas that decide behaviour on that surface.** It does not have to touch that surface's control flow.
A constant, a default, a fixture row and a migration file are all the surface.

**A match requires fan-out, and nothing downgrades it.** Not size, not simplicity, not that the change
is obvious, not that it is "only" a value. Thresholds decide execution shape for candidates that match
no surface; they do not overrule a match.

Both the numbers and the list above lived only in a JSON file that nothing loads at runtime, so this
section asked the reviewer to respect a boundary it had no way to see. That is why they are written
out here. Keep the lifecycle outside the review sequential and give every reviewer the same literal
base, candidate, tree, spec, and read-only constraint.

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

- `REQUEST_CHANGES <candidate SHA> <tree SHA>` when any validated `P0`-`P2` finding remains;
- `APPROVE <candidate SHA> <tree SHA>` only when no validated blocking finding remains.

List `P3` findings even with `APPROVE`; `/cc-tuner:run` must record each as fixed, refuted, or
explicitly deferred. Never convert a tool failure, timeout, reviewer cap, or partial lens coverage into
approval. State which lens was incomplete and return `REQUEST_CHANGES`.

Any fix requires a new candidate commit, fresh verification, and a full new review. An approval for an
older SHA or tree is stale evidence and must not be reused.
