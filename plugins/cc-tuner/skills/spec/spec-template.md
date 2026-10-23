# <title>

**Goal:** <what becomes true>
**Issue:** #N | none
**Architecture:** <ownership, data/control flow, and rejected alternatives>

## Definition of Ready
- [x] Problem/baseline: <current failure or missing behavior with evidence>
- [x] Scope: <owned modules and consumers>; out of scope: <boundaries>
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment, and data are explicit
- [x] Delivery: each repository's branch, PR, target, tracker, and CI source are explicit

## Acceptance criteria
- [ ] [machine] <criterion> — checked by: <exact command or MCP step>
- [ ] [eyes] <criterion> — checked by: <human step>; machine replacement: <exact check|none>; waiver: <user/date|none>

## Test plan
- Regression test: <path and test/assertion to add or existing failing check>
- First failing check: <exact command>; expected failure: <specific assertion/error proving the gap>
- Targeted checks: <exact commands>
- Full regression: <exact command>
- Static/build checks: <typecheck/lint/build commands or `not applicable — reason`>
- Runtime/acceptance environment: <services, browser/device, fixtures, test data, credentials boundary>
- Negative/mutation proof (name what the killed test must SAY, not only that it goes red): <how the test is shown to fail without the fix>

## Definition of Done
Recorded with evidence on the PR before merge, not ticked here: ticking would move the reviewed SHA.
- Regression check was observed failing for the expected reason before the fix
- Targeted, full, static/build, runtime, and acceptance checks passed as specified; verify-feature's
  record is on the PR
- Complete diff and formatter/autofix output were read; no unexplained files remain
- One advisory route ran (with at most one escalation to deep-review); valid findings were addressed
  or concretely refuted; the required review `review:` names approved the exact candidate SHA
- PR head equals the reviewed SHA, and CI is green on that SHA under the mode `ci:` declares
  (`../run/references/local-ci.md`)

## Completion and reconciliation
Observed after merge and reported, not committed: the target branch takes no completion commits.
- PR is merged with the configured method
- Spec/archive, issue/board, target sync, branches, and worktrees are reconciled

## Run config
branch: <current task branch>
target: <integration branch>
merge: squash|merge
second-repo: <checkout path>, branch <name>, spec <repo-relative path> — <contribution,
    prerequisites, merge order and why>. Omit for one repository. The companion's local spec
    records its own target, merge and CI policy; the primary test plan owns combined acceptance.
shared-task: <primary repository, branch and spec path>. Only in the companion spec; read that
    primary spec too. This local contribution does not complete the shared issue by itself.
auto_ready: yes|no — <reason when no>
ci: <mode> — <the checks, and how to observe them>
    mode is required (default), any, or none:<reason>; ../run/references/local-ci.md owns what each
    means and what `none` must record
review: codex|none:<reason> — codex when cc-codex-triage reviews this repository (merge.sh then
    requires its exact-candidate approval); none records why no second-provider review is required
target_test: <exact command>
full_test: <exact command>
full_test_cadence: per-candidate|per-batch — per-candidate by default; per-batch for a full suite
    cheap enough to run after every integrated batch. ../run/SKILL.md (Test cadence) owns what each means
tracker: gh|none — gh when the repository tracks work in GitHub issues; none makes this spec the record
board: <project title + owner | none>
