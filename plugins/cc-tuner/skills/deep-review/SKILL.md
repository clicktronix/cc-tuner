---
name: deep-review
description: Exhaustively review a clean, committed candidate through independent read-only lenses (six, or more when a large candidate is sharded). Use for large, cross-boundary, or sensitive changes selected by /run; do not use for an ordinary small task.
---

# Deep Review

Review one immutable candidate. This is advisory input to `/cc-tuner:run`; the companion review
remains the authoritative merge gate. Find every material problem supported by evidence, without
editing the candidate; never stop at an arbitrary count of findings.

## Inputs and packet

Require candidate SHA, base commit/target ref, and the committed spec when one exists. Resolve refs
to literal SHAs; refuse dirty/mismatched candidates and unresolved/unrelated bases. An advanced target
returns to run for synchronization. Read the spec, acceptance, rules, architecture and verification
evidence for this candidate; green CI and another review's summary do not prove correctness.

Before dispatch, prepare the full diff and changed-file list once in scratch space outside the
checkout. Use the same reader as the partitioner, so Git settings cannot hide submodule updates or
substitute external diff/text conversion:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-diff.sh" <base-sha> <candidate-sha> > <dir>/candidate.diff
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-diff.sh" <base-sha> <candidate-sha> --name-status > <dir>/changed-files.txt
bash "${CLAUDE_PLUGIN_ROOT}/scripts/shard-diff.sh" <base-sha> <candidate-sha> [--plan <plan>] [--max 4] [--files 300] [--lines 10000]
```

Write `<dir>/toolchain.txt` next to them: the language and runtime versions the repository declares
(`.python-version`, `requires-python`, `.nvmrc`, `engines`, `go.mod`, `rust-toolchain`, the CI image).
A lens has no shell to ask, and a lens that judges syntax by the version it remembers reports valid
code as broken.

Any command failure leaves preparation incomplete: do not dispatch or reuse partial files.

## Sharding

`shard-diff.sh` owns partition arithmetic. It prints SIZE, MODE and, in sharded mode, numbered SHARD
records with comma-separated paths. It groups by the plan's Owned paths when supplied, otherwise by
first path component; splits oversized groups and merges compatible neighbours up to the requested
cap. Renames count once and list both endpoints. Every shard stays strictly below file/changed-line
thresholds; binary changes and pure renames still count as files. These are not token guarantees.

The script also reads the actual filtered packets and checks their budgets and exact combined
coverage. Git errors, unsupported filenames, oversized atomic changes, unsatisfied caps or changed
coverage refuse with empty stdout. Do not treat refusal as single mode. Choose a larger budget/cap
explicitly when context and cost permit, or report incomplete coverage. Never silently skip a
lockfile or generated artifact. Binary contents and changed submodule revisions require appropriate
inspection beyond the marker/gitlink.

For each accepted SHARD, pass its paths as separately quoted arguments, including both rename
endpoints. Do not expand the list with unquoted shell substitution:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-diff.sh" <base-sha> <candidate-sha> -- <paths> > <dir>/shard-<n>.diff
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-diff.sh" <base-sha> <candidate-sha> --name-status -- <paths> > <dir>/shard-<n>-files.txt
```

## Dispatch and coverage

Use one `cc-tuner:deep-review-lens` per applicable lens/packet. Its definition supplies `sonnet`, `effort: high` and
only Read, Grep and Glob: no shell, edits or Agent tool. There is no unrestricted fallback. Each
brief names literal base/candidate, spec, applicable rules, lens, the diff/list/toolchain files and
the finding format. The lens reads changed code and
relevant callers/tests/dependencies beyond its owned paths. Commands needed to settle a finding go
to the owner for a separate probe.

Run these lenses independently:

1. **Correctness and edge cases** — logic, concurrency, errors, compatibility and user behavior.
2. **Specification and scope** — every acceptance criterion, exclusion and affected consumer.
3. **Repository standards** — rules, idioms, public contracts, generated outputs and release duties.
4. **Architecture and systemic effects** — ownership, coupling, dependencies and cross-boundary effects.
5. **Security and data safety** — trust boundaries, unsafe input, authorization, privacy and data loss.
6. **Tests and operability** — regression quality, negative/runtime evidence, diagnostics and recovery.

In single mode all six read the full packet. In sharded mode, Correctness, Standards, Security and
Tests run per shard; Specification and Architecture each read the whole candidate. The total is
`shards × 4 + 2`: 18 at the default four-shard cap, more if the owner explicitly raises it. Calculate
from the accepted result. State model, effort, concurrency and estimated USD using current rates
and token assumptions before dispatch; label unknown pricing as unknown. Historical general-purpose
spawn measurements are not current restricted-lens estimates.

Dispatch independent readers together within available host slots; queue remaining jobs in bounded
batches. They never cut their own shards or delegate. One owner aggregates all returns. A timeout,
tool failure, unread artifact or missing lens is incomplete coverage, never approval: redispatch that
lens once; if it still cannot complete, or the host does not offer the lens type, the result is
`INCOMPLETE` for the named lenses and paths (below).

## Verdict

Validate every candidate finding against live source at the candidate SHA and the agreed scope.
Where a command decides a P0/P1 claim — a runtime version, a test that should fail, a query plan —
run it yourself before the verdict; a lens could only name it.
Apply the repository's task-flow scope contract: an older dependency defect matters when this task
exposes it or needs its fix for acceptance. Refute unsupported or independent improvements. Deduplicate
by root cause and remediation, retaining distinct impacts and evidence across shards.

For each finding report priority, full candidate SHA, path:line and concrete behavior, violated
contract, impact, smallest systemic fix and verifying check. P0 is immediate security/data-loss/outage;
P1 blocks required behavior or safe delivery; P2 is a material defect; P3 is non-blocking improvement
with concrete future cost.

Return `REQUEST_CHANGES <candidate SHA>` for any validated P0–P2. Return `APPROVE <candidate SHA>`
only with complete coverage and no blockers. Return `INCOMPLETE <candidate SHA>` when coverage is
incomplete and no validated blocker exists, naming the missing lenses/paths: run carries that gap
into the required review as a named residual instead of waiting on a finding that does not exist.
List P3 findings in the review summary on the PR; they do not move the candidate, and an issue is
filed only for independent future work. Do not create an additional approval loop: run owns fixes,
evidence reuse and delivery. Changes make this result stale; verify affected
findings and let authoritative review judge the final SHA. Only an explicit new exhaustive-review
request restarts the whole advisory pass.
