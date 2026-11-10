# Fresh-machine onboarding and delivery routes beyond GitHub

**Goal:** a user who installs Claude Code and cc-tuner gets a correct, actionable `/cc-tuner:setup`
(companions installed on one yes, no false blockers), and `/cc-tuner:spec` → `/cc-tuner:run` follow
one explicit route in any repository: GitHub through the checked `merge.sh` as today; GitLab, no
remote, or another host through a written route in the repository; with the tracker the repository
chose.
**Issue:** #70
**Architecture:** two repository files say how work moves, and the agent follows them instead of
guessing:

```
 docs/agents/issue-tracker.md          .claude/rules/task-flow.local.md
 (owner: /setup-matt-pocock-skills)    block between cc-tuner:delivery-route
   where issues live; create /          markers (owner: /cc-tuner:setup)
   read / comment commands                how a candidate is opened,
          │                               recorded, checked and merged
          ▼                                        │
   /spec, --groom: tracker steps                   ▼
                                        /run Delivery: host github → merge.sh
                                        (unchanged); any other host → the route
```

**Host.** Detected by the CLI that can reach the remote, so SSH aliases resolve on their own:
`github` when `gh repo view` succeeds, `gitlab` when `glab repo view` succeeds; a remote both fail on
whose URL names github.com/gitlab.com counts as that host with a WARN that its CLI is not
authenticated; no remote at all → `local`; any other remote → ask the user (their answer is `other`
plus the route they describe). `/spec` detects after `/setup-matt-pocock-skills` (which may add a
remote) and records `host:` in Run config. `/run` re-detects before delivery and stops when the
result differs from `host:` or from the route block's host.

**Delivery route.** For `github` nothing is written: the route is `merge.sh`, unchanged. For other
hosts the delivery-route setup node copies a plugin asset into `task-flow.local.md` between
`<!-- cc-tuner:delivery-route <host> vX.Y.Z -->` and `<!-- /cc-tuner:delivery-route -->`; doctor
compares the block with the asset and WARNs on drift; a re-run shows the diff and asks. `other` is
written from the user's own words and never compared. The comment setup puts at the top of a new
`task-flow.local.md` changes from "setup never touches this file" to "setup writes only between
cc-tuner markers". Every route keeps the GitHub gate's order and records — verify → review →
verdict → CI → pinned merge; `cc-tuner-verdict`, `-verified`, `-local-ci`, `-accepted` — and its
first line says these are steps the agent performs, not a script that refuses.

- `route-gitlab.md`: `glab mr create --draft`; records as MR notes; only notes whose author is
  `glab api user` count; latest record about the head wins; under `review: codex`,
  `review-state.sh check <thread>` must print the APPROVE marker for the head; the verify record's SHA
  must be an ancestor of the head; CI from the MR `head_pipeline`, which must belong to the current
  head (merged-results pipelines included); `merge-base --is-ancestor <target tip> <head>` before
  merging; `glab mr update --ready`; `glab mr merge <iid> --sha <head> --auto-merge=false --yes
  [--squash]`; after-merge cleanup keyed on the merged head.
- `route-local.md`: records as `git notes --ref cc-tuner append` on the judged SHA, latest wins;
  `ci: none:<reason>` with a `cc-tuner-local-ci` note; the target tip must be an ancestor of the
  candidate; merge only `--ff-only`, in a clean worktree that has the target checked out, or by
  `git update-ref refs/heads/<target> <candidate> <old tip>` when no worktree has it; a dirty target
  worktree hands the merge to the user; no squash commit is ever made on the target.

`/run --auto` is allowed on every host; outside GitHub it follows the route unattended.
Shared-task preflight: `merge.sh --check-only` for GitHub candidates, every route step up to the
merge for the others, all before the first merge.

**Tracker.** `docs/agents/issue-tracker.md` is the only source. The spec's `tracker:` becomes
`gh|glab|local|other|none`, derived from it. When it is absent, `/spec` asks once: run
`/setup-matt-pocock-skills` now (a user-only command; it asks GitHub / GitLab / local markdown under
`.scratch/` / other) or continue with `tracker: none` (the spec is the record). With `local`, the
spec lives only at the `plan-path.sh spec-dir` path and the issue file links to it; status changes
are committed inside the candidate before review, so they land with the merge; `--groom` appends
under `## Comments` without committing. `--groom` under `glab` posts an MR/issue note, and a later
`/spec` settles only a groom record whose author is a project member.

**Setup.** New node **companions** after environment: in install mode, one confirmation for what is
missing, then `claude plugin marketplace add <source>` + `claude plugin install <id>` (user scope),
verified with `claude plugin list --json`, then "run `/reload-plugins` or restart". mattpocock-skills
is always offered (required by `/spec` and `/run`); cc-codex-triage only when `codex` is on PATH and
`codex login status` succeeds; otherwise it is optional and specs use `review: none:<reason>`.
Fallbacks: no `claude` on PATH → print the `/plugin …` commands for the user; no jq → "cannot tell
what is installed", install nothing; installed but disabled → `claude plugin enable`. Versions are
not pinned. New node **delivery route** after the task-flow rule (above).

Rejected: host adapters inside `merge.sh` (the user's agent runs `glab`/`git` from a written route);
a live GitLab test (the user's agent exercises the route in their own repository); referencing the
asset instead of copying it (the user chose a self-contained copy plus a drift check); GitLab boards
(`board: none` outside GitHub); cc-tuner writing `docs/agents/issue-tracker.md` (a second owner of
mattpocock's file).

## Definition of Ready
- [x] Problem/baseline: measured 2026-11-10 in an isolated env (`env -i`, fake HOME, fixture plugin
  list): doctor prints `MISS cc-codex-triage … install: /plugin marketplace update …` (wrong without
  the marketplace) and exits 1 "blockers found" for an optional companion; no `codex` check; without
  jq prints "could not list installed plugins" although the list was read; unauthenticated `gh` is a
  `MISS` on any host (`doctor.sh:143`); `/run` Delivery assumes `gh` unconditionally.
- [x] Scope: `scripts/setup/{doctor,prereq-check}.sh`; skills `setup` (+ references), `spec`
  (+ template), `run` (+ `local-ci.md`, `shared-task.md`), `verify-feature`, `task-flow`; new
  `assets/task-flow/route-{gitlab,local}.md`; `assets/task-flow/rule.template.md` (+ its version
  marker); both READMEs; `tests/setup/*`, `tests/contract/test_contract.sh`. Out of scope: `merge.sh`
  (unchanged), GitLab boards, agent teams / cross-session messaging, SessionStart's landed-plan test
  in remote-less repos (`session-start.sh:78`), the uncommitted statusline work on
  `feat/statusline-subagent-models`.
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment, and data are explicit
- [x] Delivery: branch `feat/fresh-machine-delivery`, PR to `main`, tracker gh, CI `validate.yml`

## Acceptance criteria
- [ ] [machine] Without `codex` on PATH, or with `codex login status` failing, doctor reports
  cc-codex-triage as optional (no `MISS`, exit code unaffected), names `codex login` for the second
  case, and says specs use `review: none:<reason>` — checked by: `bash plugins/cc-tuner/tests/setup/test_doctor.sh`
- [ ] [machine] With a logged-in `codex` and no cc-codex-triage, doctor and prereq-check print
  `/plugin marketplace add clicktronix/cc-codex-triage` + `/plugin install cc-codex-triage@cc-codex-triage`
  when the marketplace is not configured, and the `update` hint only for an installed copy missing the
  contract; mattpocock-skills gets `/plugin marketplace add mattpocock/skills` the same way — checked by:
  `test_doctor.sh`, `bash plugins/cc-tuner/tests/setup/test_prereq.sh`
- [ ] [machine] cc-codex-triage installed but `codex` absent → doctor `WARN`s that the review bridge
  cannot run — checked by: `test_doctor.sh`
- [ ] [machine] Without jq, doctor names jq as the reason companion checks were skipped and says the
  SessionStart plan restore is off; "could not list installed plugins" appears only when the list
  command itself failed — checked by: `test_doctor.sh`
- [ ] [machine] doctor prints the detected host: `gh` and its auth are checked (and an
  unauthenticated `gh` is a `MISS`) only for `github`, `glab` and its auth only for `gitlab`; for
  `gitlab`, `local` and `other` it reports whether the delivery-route block exists and matches its
  asset (WARN with `/cc-tuner:setup install delivery-route` when missing or drifted) — checked by: `test_doctor.sh`
- [ ] [machine] prereq-check without a usable `codex`: the missing bridge is a `NOTE` (review: none),
  exit 0 when mattpocock-skills is complete — checked by: `test_prereq.sh`
- [ ] [machine] `merge.sh` and its suite are untouched — checked by:
  `git diff --exit-code origin/main -- plugins/cc-tuner/scripts/merge.sh plugins/cc-tuner/tests/flow/test_merge.sh`
- [ ] [machine] `route-gitlab.md` names the author filter (`glab api user`), `review-state.sh check`,
  the verify-record ancestry, `head_pipeline` at the current head, the target-tip ancestry check,
  `glab mr merge` with `--sha` and `--auto-merge=false`, and the four record lines; `route-local.md`
  names `git notes --ref cc-tuner append`, `ci: none`, the ancestry check, `--ff-only`, the
  `update-ref` compare-and-swap, the dirty-worktree hand-off and "no squash" — checked by:
  `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- [ ] [machine] setup has the companions node (with its three fallbacks and the codex-login gate)
  and the delivery-route node; the spec template carries `host:` and
  `tracker: gh|glab|local|other|none`; `/spec` reads `docs/agents/issue-tracker.md`, asks when it is
  absent, and detects the host after it; `/run` re-detects the host, sends a non-github host to the
  route and stops when the block is missing or the host differs; shared-task names the per-host
  preflight; README no longer claims standalone operation without mattpocock-skills — checked by:
  `test_contract.sh`
- [ ] [eyes] `/cc-tuner:setup install` in a session with an empty `CLAUDE_CONFIG_DIR` and a
  remote-less repository installs the companions on one yes, writes the local route block, and its
  report is correct — checked by: user, per `tests/setup/setup-manual-checks.md`; machine
  replacement: `test_doctor.sh` + `test_contract.sh`; waiver: none

## Test plan
- Regression test: new cases in `plugins/cc-tuner/tests/setup/test_doctor.sh` (codex absent / not
  logged in / logged in; triage present without codex; jq absent; hosts github/gitlab/local/other;
  route block missing/current/drifted) and `test_prereq.sh`; contract assertions in
  `tests/contract/test_contract.sh`. Fixtures: stub `gh`, `glab`, `codex`, `claude` on a restricted
  PATH, as `test_doctor.sh` already does for `gh` and `claude`.
- First failing check: `bash plugins/cc-tuner/tests/setup/test_doctor.sh`; expected failure:
  `FAIL codex-absent-triage-not-miss` because doctor prints `MISS cc-codex-triage@cc-codex-triage not installed`.
- Targeted checks: the suite each slice names.
- Full regression: `bash tests/run.sh`
- Static/build checks: `bash -n` on changed scripts under macOS `/bin/bash` 3.2; SKILL.md ≤ 500 lines
  and relative links are asserted by `tests/run.sh`.
- Runtime/acceptance environment: macOS bash 3.2 and ubuntu (CI matrix); no network.
- Negative/mutation proof: not assigned. The doctor regressions are watched failing on the pre-fix
  code; each contract assertion is watched failing before the prose it checks is written.

## Definition of Done
Recorded on the PR before merge, not ticked here (it would move the reviewed SHA).
- Regression check was observed failing for the expected reason before the fix
- Targeted, full, static/build, runtime, and acceptance checks passed as specified; verify-feature's
  record is on the PR
- Complete diff and formatter/autofix output were read; no unexplained files remain
- One advisory route ran (with at most one escalation to deep-review); valid findings were addressed
  or concretely refuted; the required review `review:` names approved the exact candidate SHA
- PR head equals the reviewed SHA, and CI is green on that SHA under the mode `ci:` declares

## Completion and reconciliation
Reported after merge, not committed.
- PR is merged with the configured method
- Spec/archive, issue, target sync, branches, and worktrees are reconciled

## Run config
branch: feat/fresh-machine-delivery
target: main
merge: squash
auto_ready: no — the live setup check is [eyes] without a waiver; the user merges.
ci: any — `.github/workflows/validate.yml` runs `bash tests/run.sh` on ubuntu-latest and macos-latest
    for every pull request; `main` has no branch protection; observe with `gh pr checks <pr>`.
review: codex — cc-codex-triage is installed and reviews this repository.
target_test: the slice's suite (see plan)
full_test: bash tests/run.sh
full_test_cadence: per-candidate
host: github
tracker: gh
board: none
