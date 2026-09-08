# Continuous review: remediation of `05bebb3`

Review findings were becoming separate backlog issues instead of completed work. The first remedy
used changed filenames and a deferral counter as scope decisions. The accepted design is a short
semantic contract in the installed rules, with findings handled inside the existing continuous run.

Baseline: `05bebb3a1858c5bfdba6236d44d5c1d4d6a08eec`, already pushed before these fixes.
PR: [#25](https://github.com/clicktronix/cc-tuner/pull/25). History is additive; no commits were amended
or squashed during this remediation.

## Fixes by commit

| Commit | Change | Findings addressed |
|---|---|---|
| `1371d90` | Fix confirmed defects of the agreed outcome in the run; remove the counter and size-based deferral; workers return findings to the orchestrator | Counter changed authority; large missing acceptance could become backlog |
| `5e6d956` | Search and reuse issues, group related work, honour `board: none` | One issue per finding; unconditional project requirement |
| `8e39249` | Keep one shared task with local execution contracts and checked candidates per repository | One-PR readiness conflict; reversed merge order; companion PR outside checked delivery |

The baseline's filename criterion was already corrected and was not reported again. These changes
remove the remaining filename recipe and incident-specific numbers from the procedure. Optional
improvements are not automatically requirements; an issue link does not resolve an unmet criterion.

## Shared task delivery

The primary spec owns the common result, prerequisites and combined acceptance. Each repository has
a local spec, a repository-relative plan, a PR and its own candidate evidence. The orchestrator
maintains one visible task list with cross-repository dependencies and reviews the assembled result.

Before the first merge, every participant must pass the existing `merge.sh --check-only` in its own
checkout with its own PR, SHA, review thread and CI policy. This mode refuses a PR without a plan;
the existing unchecked path for unrelated PRs cannot serve as a companion's preflight. Merges then
follow the declared order. Rollout prerequisites require environment evidence, and a partial merge
leaves the task open for completion. No new script, hook or controller was introduced.

## Independent review

**Standards:** reviewed `05bebb3..8e39249`; all five previously identified contract contradictions
closed, no new findings. Checked optional-board handling, readiness, scope/authority, candidate
coverage and merge order against neighbouring instructions.

**Spec:** reviewed the same range against the accepted continuous-flow requirements; all seven
previous findings closed, no new findings. Checked grouping and reuse, no deferral by count or size,
shared acceptance and task projection, and strict delivery for each participant.

Both reviews establish instruction consistency. Neither is a claim that a model has executed the
entire workflow successfully.

## Validation

- Two real temporary Git repositories: each local plan passed `plan-path.sh resolve`, `plan-lint.sh
  check --spec ... --branch ...` and `ready-batches`, without cross-checkout Owned paths.
- Nine assertions using the repository's existing GitHub/reviewer fixture builders: preflight
  refuses a missing plan, failing CI and missing required review; a ready candidate passes, invokes
  its required reviewer, and never merges during preflight. GitHub was stubbed; no real PR merged.
- `bash tests/run.sh` on implementation commit `8e39249`: exit 0, 23 checks over 11 shell suites.
  `git diff --check 05bebb3...HEAD` also passed. Hosted CI validates the published head separately.
- The Codex skill validator accepts `task-flow` and `verify-feature`. It rejects the unchanged
  Claude-specific `argument-hint` and `disable-model-invocation` fields in `run` and `spec`; those
  fields were preserved and are covered by this repository's Claude plugin validation.

No live model eval was run: `EVALUATED_SHA` remains unchanged and the ADR remains `proposed`.
Testing-runbook setup, actual Task-tool availability probing and measured delegation cost remain
open. Installed plugin caches and repository rules were not updated by these source commits; an
active session may still contain the old instructions.
