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
- PR head equals the reviewed SHA, and CI is green on that SHA under the mode `ci:` declares —
  under `none:` that means no checks exist and a PR comment records the local result for that SHA

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
    mode is one of:
      required          the target branch has required checks on GitHub (the default; strongest)
      any               CI runs here but nothing is required — every reported check must pass
      none:<reason>     this repository runs no CI on a pull request; the reason is recorded and
                        printed at merge. Honoured only when GitHub reports no checks at all AND a
                        PR comment records `cc-tuner-local-ci: <sha> <what ran, and what it
                        returned>`. Prefer `any` where a workflow can be dispatched by hand.
review: codex|none:<reason> — codex when cc-codex-triage reviews this repository (merge.sh then
    requires its exact-candidate approval); none records why no second-provider review is required
target_test: <exact command>
full_test: <exact command>
tracker: gh|none — gh when the repository tracks work in GitHub issues; none makes this spec the record
board: <project title + owner | none>
