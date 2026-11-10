# Fresh-machine onboarding and delivery routes beyond GitHub — plan

**Spec:** docs/PLANS/2026-11-10-fresh-machine-delivery.md
**Branch:** feat/fresh-machine-delivery

full_test_cadence: per-candidate

## Slice 1 — doctor and prereq-check give no false blockers on a fresh machine
Blocked by: none
Owned paths: plugins/cc-tuner/scripts/setup/doctor.sh,plugins/cc-tuner/scripts/setup/prereq-check.sh,plugins/cc-tuner/tests/setup/test_doctor.sh,plugins/cc-tuner/tests/setup/test_prereq.sh
Deciding check: bash plugins/cc-tuner/tests/setup/test_doctor.sh && bash plugins/cc-tuner/tests/setup/test_prereq.sh
Delivers: a user without codex, without jq, or on a GitLab/remote-less repository runs doctor and sees no MISS for what they do not need, the right install command for what they do, and the detected host

- [x] codex absent or `codex login status` failing → cc-codex-triage reported optional, no MISS, `review: none:<reason>` named; not-logged-in names `codex login`
- [x] logged-in codex without cc-codex-triage → `marketplace add` + `install` hint when the marketplace is absent, `update` only for an installed copy missing the contract; same for mattpocock-skills; prereq-check agrees
- [x] cc-codex-triage installed but codex absent → WARN that the bridge cannot run
- [x] no jq → jq named as the reason and the SessionStart plan restore named as off; "could not list installed plugins" only when the list command failed
- [x] host detected by `gh repo view` / `glab repo view` / no remote / other; `gh` and its auth checked (MISS when unauthenticated) only for github, `glab` and its auth only for gitlab
- [x] prereq-check without a usable codex prints a NOTE and exits 0 when mattpocock-skills is complete

Evidence: bash plugins/cc-tuner/tests/setup/test_doctor.sh && bash plugins/cc-tuner/tests/setup/test_prereq.sh → 119 PASS / 42 PASS, rc=0 (RED first: FAIL codex-absent-triage-not-miss) @ worktree after db4b24c + install-hint.sh extraction

## Slice 2 — GitLab, remote-less and other hosts get a written delivery route
Blocked by: 1
Owned paths: plugins/cc-tuner/assets/task-flow/route-gitlab.md,plugins/cc-tuner/assets/task-flow/route-local.md,plugins/cc-tuner/skills/setup,plugins/cc-tuner/scripts/setup/doctor.sh,plugins/cc-tuner/tests/setup/test_doctor.sh,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/setup/test_doctor.sh && bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: `/cc-tuner:setup install delivery-route` writes the route for the detected host between cc-tuner markers in task-flow.local.md, and doctor reports it missing, current or drifted

- [x] route-gitlab.md names the author filter, `review-state.sh check`, verify-record ancestry, `head_pipeline` at the current head, the target-tip ancestry check, `glab mr merge --sha <head> --auto-merge=false`, and the four record lines
- [x] route-local.md names `git notes --ref cc-tuner append`, `ci: none`, the ancestry check, `--ff-only`, the `update-ref` compare-and-swap, the dirty-worktree hand-off and no squash commit
- [x] the setup delivery-route node writes, diffs and asks; `other` is written from the user's words; the new task-flow.local.md header says setup writes only between cc-tuner markers
- [x] doctor WARNs with `/cc-tuner:setup install delivery-route` when the block is missing or differs from its asset, and says ok when it matches

Evidence: bash plugins/cc-tuner/tests/setup/test_doctor.sh && bash plugins/cc-tuner/tests/contract/test_contract.sh → 143 PASS / 205 PASS, rc=0 (RED first: FAIL route-local-missing-warns, 55 contract FAILs) @ 4a544ce

## Slice 3 — setup installs the companions on one yes
Blocked by: 2
Owned paths: plugins/cc-tuner/skills/setup,plugins/cc-tuner/tests/setup/setup-manual-checks.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: `/cc-tuner:setup install` on a fresh machine offers mattpocock-skills and, with a logged-in codex, cc-codex-triage, installs them after one confirmation and verifies them with `claude plugin list --json`

- [ ] the companions node runs `claude plugin marketplace add` + `claude plugin install` at user scope, verifies, and names `/reload-plugins` or a restart
- [ ] fallbacks: no `claude` → print `/plugin …` commands; no jq → install nothing and say why; disabled → `claude plugin enable`
- [ ] setup-manual-checks.md carries the live fresh-`CLAUDE_CONFIG_DIR` check for the [eyes] criterion

## Slice 4 — spec, run and groom follow the tracker file and the route
Blocked by: 3
Owned paths: plugins/cc-tuner/skills/spec,plugins/cc-tuner/skills/run,plugins/cc-tuner/skills/verify-feature,plugins/cc-tuner/skills/task-flow,plugins/cc-tuner/assets/task-flow/rule.template.md,plugins/cc-tuner/README.md,README.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh && bash tests/run.sh
Delivers: in a GitLab or remote-less repository `/spec` records `host:` and the tracker from docs/agents/issue-tracker.md (asking when it is absent), and `/run` delivers by the route; on GitHub nothing changes

- [ ] spec template has `host:` and `tracker: gh|glab|local|other|none`; `/spec` reads docs/agents/issue-tracker.md, asks when absent, detects the host after it
- [ ] `/run` re-detects the host, uses merge.sh for github and the route otherwise, stops when the block is missing or the host differs; `--auto` allowed on every host
- [ ] `--groom` works for glab (member-authored records settle) and local (append without commit); local tracker status changes are committed inside the candidate
- [ ] shared-task preflight is per host; verify-feature and local-ci name where records go per host
- [ ] both READMEs describe the host routes and no longer claim standalone operation without mattpocock-skills; rule.template.md version marker bumped
