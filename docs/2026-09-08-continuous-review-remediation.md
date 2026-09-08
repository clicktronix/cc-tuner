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

## Editorial follow-up to `cbb2abe`

The accepted follow-up keeps the same continuous lifecycle and removes conditional detail from
the default reading path. It introduces no runtime script, hook, counter or approval gate.

| Commit | Change |
|---|---|
| `a897324` | Clarify the scope contract and future-work introduction; preserve the dated Stokli incident in the existing case studies |
| `65e52f6` | Load shared-task, mutation and local-CI procedures when applicable; move delegation details into the existing placement reference; standardize `primary spec` |
| `80af216` | Remove exact-prose assertions for run policy while retaining helper invocation, machine-marker and executable checks |

`run/SKILL.md` shrank from 391 to 177 lines (4,246 to 1,578 words). Including all of its
references, the directory shrank from 515 to 421 lines (5,725 to 4,205 words). These are text
measurements, not measured token or dollar savings. `spec` and standalone `verify-feature` have
their own shared-task loaders; each entry point reads the reference before the relevant work.
Related decisions needing user input are grouped while independent work continues. There is no
finding-count threshold.

Independent Standards and Spec reviews compared the complete old and new flow, including the
references: no confirmed loss of requirements or new findings. Both also reviewed the test change.
The first full suite at `65e52f6` failed 18 assertions tied to old wording; the other ten shell
suites passed. `80af216` removes 19 prose assertions, including one that still passed, rather than
substituting new wording regexes. This removes an automatic signal for literal policy-text deletion;
semantic preservation for this change was checked by review, not established by those assertions.

`bash tests/run.sh` at `80af216` passed: exit 0, 23 checks over 11 shell suites. All six directly
linked local references from the changed entry points resolve. Hosted CI checks the final published
head separately. The live model eval and installed-version propagation remain unverified; this
editorial pass does not close the outstanding items above.


## Continuous execution corrections after `0960386`

The user retained manual merge without `--auto` and chose actual target synchronization over merely
reviewing against a merge-base. The remaining findings were corrected within the same PR:

- `6fdf9eb`: notify and merge/rebase an advanced target, resolve conflicts before candidate evidence;
  keep published history and the required thread's base stable. Prepare archive paths and links before
  the first review. Preserve independent WIP and continue work not blocked by a real decision.
- Direct non-code checks and existing tests may prove their own acceptance criteria. Reuse observed
  evidence only when its inputs still match the integrated result; changed or uncertain inputs need
  new checks. Final authoritative approval and CI remain bound to the candidate SHA.
- One CI policy covers candidate checks, including push/manual workflows. The existing merge helper
  still rejects missing approval, failing checks and `none` over reported checks.
- One advisory workflow: ordinary Matt review or sensitive/large deep-review, followed by required
  Codex review. Escalate once if a fix introduces a deep-review trigger. At the required cap, paid
  reviews and delivery stop; safe remaining fixes may continue without inventing approval.
- Grilling addresses unresolved decisions in batches. Typecheck/lint are no longer mandatory after
  every formatter, and unsupported claims are distinguished from reusable observed evidence.
- `019de7e`: align the remaining scope/CI checklist, allow Matt's read-only parallel lenses and remove
  the ADR's obsolete three-review requirement. Issue linking remains conditional on an issue existing.

Both independent review axes approved the final instruction changes with no remaining findings.
Standards initially found four residual contradictions; Spec also noted the CI wording. These were
fixed additively in `019de7e`, then re-reviewed. Runtime scripts and their tests were unchanged.

### Official Claude Code review comparison

Checked the [official command source at `db8834ba`](https://github.com/anthropics/claude-code/blob/db8834ba1d72e9a26fba30ac85f3bc4316bb0689/plugins/code-review/commands/code-review.md),
alongside Context7 documentation. It is an official plugin, not cc-tuner's authoritative gate.
It dispatches four main reviewers plus finding validators, focuses on diff bugs and CLAUDE.md
compliance, skips some PRs, and publishes only with `--comment`. Deep-review uses six applicable
lenses spanning the spec, callers, architecture, security and verification; its owner validates the
findings and returns an advisory verdict. Both use independent agents, but their scope differs.
The official command's narrow pre-existing-issue filter is unsuitable as cc-tuner's task-scope rule.

### Verification and limits

- Full `bash tests/run.sh` at `6fdf9eb`: exit 0, 23 checks over 11 shell suites.
- Static contract suite and `git diff --check` passed after `019de7e`; hosted CI checks the final head.
- Temporary real Git fixture: conflict-producing target merge, explicit resolution, archive relocation,
  updated plan validation and resolver-based resume all passed. The installed cc-codex-triage 0.11.0
  checker accepted the archived spec before the first round and a later target merge with the same
  pinned review contract. Only local state claims ran; no paid review or approval was fabricated.
- Text size: run 177 → 208 lines, spec 190 → 185, placement 140 → 128. The run growth names previously
  missing synchronization/archive steps; conditional details stay in references. Token/dollar savings
  are not measured. The live model eval and installed-cache propagation remain open.
