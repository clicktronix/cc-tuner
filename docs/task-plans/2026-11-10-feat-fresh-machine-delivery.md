# Fresh-machine onboarding and delivery routes beyond GitHub — plan

**Spec:** docs/ARCHIVE/PLANS/2026-11-10-fresh-machine-delivery.md
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

- [x] the companions node runs `claude plugin marketplace add` + `claude plugin install` at user scope, verifies, and names `/reload-plugins` or a restart
- [x] fallbacks: no `claude` → print `/plugin …` commands; no jq → install nothing and say why; disabled → `claude plugin enable`
- [x] setup-manual-checks.md carries the live fresh-`CLAUDE_CONFIG_DIR` check for the [eyes] criterion

Evidence: bash plugins/cc-tuner/tests/contract/test_contract.sh → 220 PASS, rc=0 (RED first: 15 FAILs, first setup-hint-names-companions) @ a59a82c

## Slice 4 — spec, run and groom follow the tracker file and the route
Blocked by: 3
Owned paths: plugins/cc-tuner/skills/spec,plugins/cc-tuner/skills/run,plugins/cc-tuner/skills/verify-feature,plugins/cc-tuner/skills/task-flow,plugins/cc-tuner/assets/task-flow/rule.template.md,plugins/cc-tuner/README.md,README.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh && bash tests/run.sh
Delivers: in a GitLab or remote-less repository `/spec` records `host:` and the tracker from docs/agents/issue-tracker.md (asking when it is absent), and `/run` delivers by the route; on GitHub nothing changes

- [x] spec template has `host:` and `tracker: gh|glab|local|other|none`; `/spec` reads docs/agents/issue-tracker.md, asks when absent, detects the host after it
- [x] `/run` re-detects the host, uses merge.sh for github and the route otherwise, stops when the block is missing or the host differs; `--auto` allowed on every host
- [x] `--groom` works for glab (member-authored records settle) and local (append without commit); local tracker status changes are committed inside the candidate
- [x] shared-task preflight is per host; verify-feature and local-ci name where records go per host
- [x] both READMEs describe the host routes and no longer claim standalone operation without mattpocock-skills; rule.template.md version marker bumped

Evidence: bash plugins/cc-tuner/tests/contract/test_contract.sh → 295 PASS, rc=0 (RED first: 70 FAILs, e.g. spec-template-host-field) @ 699031c + invariant fix

## Slice 5 — one offline owner of host detection
Blocked by: 4
Owned paths: plugins/cc-tuner/scripts/setup/host.sh,plugins/cc-tuner/scripts/setup/doctor.sh,plugins/cc-tuner/tests/setup/test_host.sh,plugins/cc-tuner/tests/setup/test_doctor.sh
Deciding check: bash plugins/cc-tuner/tests/setup/test_host.sh && bash plugins/cc-tuner/tests/setup/test_doctor.sh
Delivers: doctor (and later /spec, /run, setup) learn the host from one offline program that resolves SSH aliases and configured hosts, and a missing or unauthenticated host CLI is a MISS on github and gitlab

- [x] host.sh prints host, via, remote and remote host; origin-or-only-remote; ambiguous; exact URL host parse; ssh -G alias; gh/glab configured hosts; local; other with the login hint; no network
- [x] doctor calls host.sh and checks only that host's CLI; missing/unauthenticated gh or glab, or glab without mr merge --sha/--auto-merge, is MISS; install hints are platform-neutral
- [x] doctor's untested host branches (review H8) each have a case

Evidence: bash plugins/cc-tuner/tests/setup/test_host.sh && bash plugins/cc-tuner/tests/setup/test_doctor.sh → 45 PASS / 185 PASS, rc=0 (RED first: 41 FAILs each, e.g. FAIL gh-missing-misses) @ e0e70c6

## Slice 6 — one owner of companion facts, per-plugin choice and the Codex opt-out
Blocked by: 5
Owned paths: plugins/cc-tuner/scripts/setup/companion.sh,plugins/cc-tuner/scripts/setup/install-hint.sh,plugins/cc-tuner/scripts/setup/plugin-here.sh,plugins/cc-tuner/scripts/setup/doctor.sh,plugins/cc-tuner/scripts/setup/prereq-check.sh,plugins/cc-tuner/skills/setup,plugins/cc-tuner/tests/setup/test_companion.sh,plugins/cc-tuner/tests/setup/test_doctor.sh,plugins/cc-tuner/tests/setup/test_prereq.sh,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/setup/test_companion.sh && bash plugins/cc-tuner/tests/setup/test_doctor.sh && bash plugins/cc-tuner/tests/setup/test_prereq.sh && bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: doctor, prereq-check and the companions node give one answer per companion — installed, disabled (enable), absent (install / marketplace add), conflicting marketplace (stop) — and a user can decline Codex review per repository without a permanent MISS

- [x] companion.sh owns the table, state, hint, codex state and opt-out; install-hint.sh is gone and no caller restates its rules
- [x] a same-named marketplace from another repo is a stop that names both sources
- [x] the companions node asks per plugin with sources shown, records the opt-out, declares its settings.json write, runs after 0b and before node 4; node 7 and /spec research are gated on a usable, loaded bridge

Evidence: test_companion.sh && test_doctor.sh && test_prereq.sh && test_contract.sh → 68 / 210 / 59 / 303 PASS, rc=0 (RED first: FAIL table-rc0, FAIL optout-rc0, FAIL install-hint-script-is-gone) @ c6fba75; plugin-here.sh default output identical to origin/main

## Slice 7 — the route text comes from the plugin; the repo keeps a checked key block
Blocked by: 6
Owned paths: plugins/cc-tuner/skills/run/references/route-gitlab.md,plugins/cc-tuner/skills/run/references/route-local.md,plugins/cc-tuner/skills/run/references/local-ci.md,plugins/cc-tuner/assets/task-flow,plugins/cc-tuner/scripts/setup/route.sh,plugins/cc-tuner/scripts/setup/doctor.sh,plugins/cc-tuner/skills/setup,plugins/cc-tuner/tests/setup/test_route.sh,plugins/cc-tuner/tests/setup/test_doctor.sh,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/setup/test_route.sh && bash plugins/cc-tuner/tests/setup/test_doctor.sh && bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: setup writes a short key block that route.sh check accepts, doctor and /run reject any drift, and /run follows a route text in the plugin that fixes every route defect deep-review found

- [x] route.sh write → route.sh check → doctor round trip passes; check reports missing, mismatch, drift, malformed, stale-on-github, CRLF-safe; legacy header replaced; outside text untouched
- [x] route references fix R3–R6 and R9–R14 and their record lines match merge.sh's accepted forms
- [x] assets/task-flow/route-*.md are gone and rule.template.md equals origin/main; the template word ceiling is back to 650
- [x] delivery-route.md drives route.sh instead of inline bash; the plugin-root fallback resolves through plugin-here.sh in every setup reference

Evidence: test_route.sh && test_doctor.sh && test_contract.sh → 143 / 220 / 362 PASS, rc=0 (RED first: 82 route FAILs, FAIL route-local-current-ok, FAIL template-stays-small 660>650; CRLF mutation killed) @ e43e8a9; merge.sh and rule.template.md identical to origin/main

## Slice 8 — skills and READMEs follow host.sh, route.sh and companion.sh
Blocked by: 7
Owned paths: plugins/cc-tuner/skills/spec,plugins/cc-tuner/skills/run/SKILL.md,plugins/cc-tuner/skills/run/references/shared-task.md,plugins/cc-tuner/skills/task-flow,plugins/cc-tuner/skills/verify-feature,plugins/cc-tuner/README.md,README.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: /spec and /run detect the host with host.sh, check the route with route.sh at start and at Delivery, read the route from the plugin, and say what a remote-less repository does instead of push/fetch/pull

- [x] review items S1–S9 are fixed in the skills and READMEs
- [x] the contract suite keeps command, marker and order pins and drops the generic-substring pins (S10)

Evidence: bash plugins/cc-tuner/tests/contract/test_contract.sh → 367 PASS, rc=0 (RED first: 26 FAILs, first spec-asks-host-sh; then 7 README FAILs) @ a8e0c72


## Slice 9 — active profiles, persistent local issues and concise instructions
Blocked by: 8
Owned paths: .claude-plugin/marketplace.json,README.md,plugins/cc-tuner/.claude-plugin/plugin.json,plugins/cc-tuner/README.md,plugins/cc-tuner/scripts/setup,plugins/cc-tuner/skills,plugins/cc-tuner/output-styles/mechanism-first.md,plugins/cc-tuner/tests/setup,plugins/cc-tuner/tests/flow/test_local_issues.sh,plugins/cc-tuner/tests/contract/test_contract.sh,docs/ARCHIVE/PLANS/2026-11-10-fresh-machine-delivery.md
Deciding check: bash plugins/cc-tuner/tests/setup/test_profile.sh && bash plugins/cc-tuner/tests/flow/test_local_issues.sh && bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: every setup node uses the active profile; all local issue writers preserve ignored records across worktree cleanup; instructions have one permission policy and concise descriptions

- [x] statusline check/install/remove use the active profile, preserve unrelated settings and handle spaces/quotes in paths; doctor detects the same profile
- [x] spec, groom and future-work issues share one location policy; ignored issues survive task-worktree cleanup
- [x] merge authorization, instruction-size guidance, commit conventions, release-note behavior and setup ownership agree across their callers
- [x] descriptions state purpose and invocation; routes reuse verification evidence; internal fallback commands clearly produce user-facing commands
- [x] independent semantic review confirms the fixes and preserved lifecycle obligations

Evidence: RED `FAIL custom-active-settings` on the old statusline recipe; new profile recipe 23 PASS. RED `FAIL shared-local-issue-location-missing`; new Git location/merge/cleanup probe 4 PASS. Doctor 225 PASS, route 146 PASS, contract 402 PASS. Full repository gate runs in PR CI on macOS and Ubuntu with the pinned Claude version; delivery still requires that gate to pass. Live model flow remains unproved; no paid eval was run.
