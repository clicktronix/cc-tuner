# <title>

**Goal:** <what becomes true>
**Issue:** #N | none
**Architecture:** <ownership, data/control flow, and rejected alternatives>

## Definition of Ready
- [x] Problem/baseline: <current failure or missing behavior with evidence>
- [x] Scope: <owned modules and consumers>; out of scope: <boundaries>
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment, and data are explicit
- [x] Delivery: one branch, one PR, target, tracker, and CI source are explicit

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
- Negative/mutation proof: <how the test is shown to fail without the fix>

## Definition of Done
- [ ] Regression check was observed failing for the expected reason before the fix
- [ ] Targeted, full, static/build, runtime, and acceptance checks passed as specified
- [ ] Complete diff and formatter/autofix output were read; no unexplained files remain
- [ ] Applicable advisory reviews ran once; valid findings were addressed or concretely refuted; authoritative Codex review approved the exact candidate SHA
- [ ] PR head equals the reviewed SHA and required CI is green on that SHA

## Completion and reconciliation
- [ ] PR is merged with the configured method
- [ ] Spec/archive, issue/board, target sync, branches, and worktrees are reconciled

## Run config
branch: <current task branch>
target: <integration branch>
merge: squash|merge
auto_ready: yes|no — <reason when no>
ci: <mode> — <the checks, and how to observe them>
    mode is one of:
      required          the target branch has required checks on GitHub (the default; strongest)
      any               CI runs here but nothing is required — every reported check must pass
      none:<reason>     this repository runs no CI on a pull request; the reason is recorded and
                        printed at merge. Honoured only when GitHub reports no checks at all.
target_test: <exact command>
full_test: <exact command>
tracker: gh
board: <project title + owner | none>
