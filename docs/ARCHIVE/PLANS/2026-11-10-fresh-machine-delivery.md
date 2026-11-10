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

**Host.** One program owns it, `scripts/setup/host.sh`, and doctor, `/spec`, `/run` and setup call
it instead of restating the rule (deep-review H1). It is offline: the remote is `origin`, or the only
remote; several remotes and no `origin` is `ambiguous` and the caller asks. The remote's host is parsed
exactly from the URL (scp-like, `ssh://`, `https://`), an SSH alias is resolved with `ssh -G`, and the
host is `github` for github.com or a host `gh` is configured for, `gitlab` for gitlab.com or a host
`glab` is configured for; no remote → `local`; anything else → `other`, with the
`gh/glab auth login --hostname <host>` hint. The CLI of the detected host is then checked: missing,
unauthenticated, or (glab) lacking `mr merge --sha/--auto-merge` is a `MISS` on both github and gitlab,
because delivery cannot run without it. `/spec` detects after `/setup-matt-pocock-skills` (which may
add a remote) and records `host:`; `/run` re-detects before starting and at Delivery entry and stops
on a mismatch, naming the CLI login when that is the cause.

**Delivery route.** For `github` the route is `merge.sh`, unchanged. For the other hosts the route
text is a plugin reference that `/run` reads from the plugin at Delivery —
`skills/run/references/route-gitlab.md`, `route-local.md` — never a copy the candidate can edit
(deep-review R1–R3). The repository holds only a short key block in `.claude/rules/task-flow.local.md`,
written and checked by `scripts/setup/route.sh write|check`:
`<!-- cc-tuner:delivery-route <host> -->`, one line saying delivery goes only by `/cc-tuner:run`'s
route for that host and never by a web or bare CLI merge, and `<!-- /cc-tuner:delivery-route -->`.
For `other` the block body is the user's own description and is the route. `route.sh check` reports
current, missing, host mismatch, drift, malformed and a stale block on a github host; `/run` stops on
anything but current, and the block is committed with `task-flow.local.md` so task worktrees have it.
`route.sh write` also replaces the legacy "setup never touches this file" header. Every route keeps the
GitHub gate's order and records — verify → review → verdict → CI → pinned merge;
`cc-tuner-verdict`, `-verified`, `-local-ci`, `-accepted` — publishes records from a file, never through
a double-quoted string, treats a failing step as a stop, and says these are steps the agent performs.

- gitlab: `glab mr create --draft --target-branch <target> --source-branch <branch>`; MR notes read
  with `sort=asc&order_by=created_at`, system notes excluded, only the authenticated username's
  (`glab api user | jq -r .username`), latest by `created_at` wins; the MR's `target_branch`,
  `source_branch` and project ids must match the spec; under `review: codex`, the 7-field
  `review-state.sh check` marker with `head=` equal to the MR sha and the worktree HEAD; verify-record
  ancestry; `head_pipeline` of the current head and the target project, status `success`; required
  approvals read from `.../approvals` — when not approved, stop and ask a human, under `--auto` too;
  target-tip ancestry from the MR's `target_branch`; `glab mr merge <iid> --sha <head>
  --auto-merge=false --yes [--squash]`; the hand-over is the whole final step, not the merge line.
- local: records as `git notes --ref cc-tuner append -F <file>` paragraphs, last matching wins,
  ancestors found with `git log --notes=cc-tuner`; the merge decision is the verdict made in this
  session and the notes are its audit trail; `ci: none:<reason>`; no push, fetch or pull; the target is
  `refs/heads/<target>`; merge only fast-forward (`--ff-only` in a clean target worktree, or
  `git update-ref` compare-and-swap when none has it); a dirty target worktree hands the merge over;
  no squash or merge commit on the target, so `/spec` writes `merge: ff`.

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
`codex login status` succeeds; otherwise it is optional and specs use `review: none:<reason>`. The
confirmation is per plugin (multiSelect) and shows each source; declining cc-codex-triage records a
per-repository opt-out that doctor and prereq-check report as a NOTE and `/spec` turns into
`review: none:<reason>`. `scripts/setup/companion.sh` owns the companion table, the codex state, the
opt-out and the hint (install, marketplace add, `enable` for a disabled copy, a stop when a
same-named marketplace comes from another repo); it replaces `install-hint.sh` (deep-review C1–C4).
Fallbacks: no `claude` on PATH → print the `/plugin …` commands for the user; no jq → "cannot tell
what is installed", install nothing; installed but disabled → `claude plugin enable`. Versions are
not pinned. New node **delivery route** after the task-flow rule (above).

Rejected: host adapters inside `merge.sh` (the user's agent runs `glab`/`git` from a written route);
a live GitLab test (the user's agent exercises the route in their own repository); a full copy of the
route in `task-flow.local.md` (chosen first, reversed after deep-review: always-loaded, editable by the
candidate it gates, and `${CLAUDE_PLUGIN_ROOT}` does not expand there); a line in the always-on
`rule.template.md` (it would load in every GitHub repository); GitLab boards
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
  `scripts/setup/{host,companion,route}.sh` and `skills/run/references/route-{gitlab,local}.md`
  (after deep-review; `install-hint.sh` is replaced); both READMEs; `tests/setup/*`, `tests/contract/test_contract.sh`. Out of scope: `merge.sh`
  (unchanged), GitLab boards, agent teams / cross-session messaging, SessionStart's landed-plan test
  in remote-less repos (`session-start.sh:78`), the uncommitted statusline work on
  `feat/statusline-subagent-models`.
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment, and data are explicit
- [x] Delivery: branch `feat/fresh-machine-delivery`, PR to `main`, tracker gh, CI `validate.yml`

## Acceptance criteria
- [x] [machine] Without `codex` on PATH, or with `codex login status` failing, doctor reports
  cc-codex-triage as optional (no `MISS`, exit code unaffected), names `codex login` for the second
  case, and says specs use `review: none:<reason>` — checked by: `bash plugins/cc-tuner/tests/setup/test_doctor.sh`
- [x] [machine] With a logged-in `codex` and no cc-codex-triage, doctor and prereq-check print
  `/plugin marketplace add clicktronix/cc-codex-triage` + `/plugin install cc-codex-triage@cc-codex-triage`
  when the marketplace is not configured, and the `update` hint only for an installed copy missing the
  contract; mattpocock-skills gets `/plugin marketplace add mattpocock/skills` the same way — checked by:
  `test_doctor.sh`, `bash plugins/cc-tuner/tests/setup/test_prereq.sh`
- [x] [machine] cc-codex-triage installed but `codex` absent → doctor `WARN`s that the review bridge
  cannot run — checked by: `test_doctor.sh`
- [x] [machine] Without jq, doctor names jq as the reason companion checks were skipped and says the
  SessionStart plan restore is off; "could not list installed plugins" appears only when the list
  command itself failed — checked by: `test_doctor.sh`
- [ ] [machine] doctor prints the host `host.sh` detected; the CLI of that host is checked, and a missing
  or unauthenticated `gh` (github) or `glab` (gitlab, also one lacking `mr merge --sha/--auto-merge`)
  is a `MISS`; no other host's CLI is checked; for gitlab, local and other it prints what
  `route.sh check` reports (WARN with `/cc-tuner:setup install delivery-route` unless current) —
  checked by: `test_doctor.sh`
- [x] [machine] prereq-check without a usable `codex`: the missing bridge is a `NOTE` (review: none),
  exit 0 when mattpocock-skills is complete — checked by: `test_prereq.sh`
- [x] [machine] `merge.sh` and its suite are untouched — checked by:
  `git diff --exit-code origin/main -- plugins/cc-tuner/scripts/merge.sh plugins/cc-tuner/tests/flow/test_merge.sh`
- [ ] [machine] `skills/run/references/route-gitlab.md` names the author filter (`glab api user | jq -r .username`, notes `sort=asc`), `review-state.sh check`,
  the verify-record ancestry, `head_pipeline` at the current head, the target-tip ancestry check,
  `glab mr merge` with `--sha` and `--auto-merge=false`, and the four record lines; `route-local.md`
  names `git notes --ref cc-tuner append -F`, `ci: none`, the ancestry check, `--ff-only`, the
  `update-ref` compare-and-swap, the dirty-worktree hand-off and "no squash" — checked by:
  `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- [x] [machine] setup has the companions node (with its three fallbacks and the codex-login gate)
  and the delivery-route node; the spec template carries `host:` and
  `tracker: gh|glab|local|other|none`; `/spec` reads `docs/agents/issue-tracker.md`, asks when it is
  absent, and detects the host after it; `/run` re-detects the host, sends a non-github host to the
  route and stops when the block is missing or the host differs; shared-task names the per-host
  preflight; README no longer claims standalone operation without mattpocock-skills — checked by:
  `test_contract.sh`
- [x] [machine] `host.sh` classifies without network: exact URL host, SSH alias via `ssh -G`, configured
  gh/glab hosts, origin-or-only-remote, ambiguous, local, other with the login hint — checked by:
  `bash plugins/cc-tuner/tests/setup/test_host.sh`
- [x] [machine] `companion.sh` answers state (installed/disabled/absent/unknown with the scope rule of
  plugin-here.sh), hint (enable, install, marketplace add, stop on a same-named marketplace from another
  repo), codex state and the opt-out; doctor and prereq-check call it — checked by:
  `bash plugins/cc-tuner/tests/setup/test_companion.sh`
- [ ] [machine] `route.sh write` output is accepted by `route.sh check` and by doctor (the real
  producer through the real checker); check reports missing, mismatch, drift, malformed, CRLF-safe,
  stale-on-github; write replaces the legacy header and never touches text outside the markers —
  checked by: `bash plugins/cc-tuner/tests/setup/test_route.sh`
- [ ] [machine] the route references' record lines are the forms merge.sh accepts, and
  `rule.template.md` is byte-identical to origin/main — checked by: `test_route.sh`,
  `git diff --exit-code origin/main -- plugins/cc-tuner/assets/task-flow/rule.template.md`
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
