# deep-review shards its file-local lenses when the candidate is too large for one reader

**Goal:** a deep-review over a candidate above a size threshold reviews it in deterministic shards:
file-local lenses run once per shard, whole-candidate lenses run once over the whole diff, one owner
aggregates, and the cost of the fan-out is stated before any lens is dispatched.
**Issue:** #38
**Architecture:** The arithmetic moves out of prose into a script, the way `plan-lint.sh` owns the
Owned-paths grammar. `plugins/cc-tuner/scripts/shard-diff.sh <base> <candidate> [--plan <path>]
[--max 4] [--files 300] [--lines 10000]` prints `SIZE\t<files>\t<lines>`, `MODE\tsingle|sharded`, and
when sharded one `SHARD\t<n>\t<key>\t<path,...>` per shard. Sharding triggers when the changed-file
count reaches `--files` **or** insertions plus deletions reach `--lines`. Files are grouped by the
plan's Owned paths when `--plan` is given — read through a new `plan-lint.sh owned <plan>` mode that
prints `OWNED\t<n>\t<path,...>`, so one parser owns the grammar — with files matching no slice in a
`rest` shard; without a plan, by the first path component (`root` for top-level files). More groups
than `--max` are merged smallest-into-neighbour until the cap holds. A bad ref exits non-zero with
nothing printed. `deep-review` runs the script before dispatch. A lens has no shell (0.14.0,
`agents/deep-review-lens.md`), so the owner already writes `<dir>/candidate.diff` and
`<dir>/changed-files.txt` before any dispatch; sharding extends that: for each `SHARD` line the owner
writes `<dir>/shard-<n>.diff` (`git diff --find-renames <base>...<candidate> -- <paths>`) and
`<dir>/shard-<n>-files.txt`, and the script's path list is exactly what goes after `--`. Correctness,
Repository standards, Security and Tests-and-operability lenses are dispatched once per shard and
read that shard's two files; Specification-and-scope and Architecture lenses are dispatched once and
read the whole `candidate.diff` and `changed-files.txt`, because their question does not cut along
paths. The owner aggregates as today,
deduplicating across shards by cause. `/run` says, when it selects deep-review, how many agents that
will be (`shards × 4 + 2`). Rejected: threshold and grouping in prose (prose arithmetic is what failed
in the field); sharding all six lenses (Specification and Architecture lose the cross-module view that
is their only job); letting a lens cut its own shard out of `candidate.diff` (a reader that could
not hold the diff is the one being asked to slice it). Superseded on 2026-09-20: the first draft
rejected the diff-through-file route as pure git savings; 0.14.0 made it the only route, because the
lens lost `Bash`.

## Definition of Ready
- [x] Problem/baseline: field audit (personal-os `docs/2026-09-19-cc-tuner-subagent-field-audit.md`
      §2.1): the Correctness lens over a 1071-file candidate (`c1dfd5b8`, +18070/−21919) spawned five
      Opus reviewers of its own; a lens over a stokli candidate (`b1fc9b88`) spawned six. Candidates of
      57 and 247 files were read by one lens. `agents/deep-review-lens.md` (commit 21dddff) now
      withholds the `Agent` tool, so a lens that cannot hold the diff will read part of it and report
      as if it had read all of it.
- [x] Scope: `plugins/cc-tuner/scripts/`, `plugins/cc-tuner/tests/flow/`,
      `plugins/cc-tuner/skills/deep-review/`, one sentence in `plugins/cc-tuner/skills/run/SKILL.md`,
      `plugins/cc-tuner/README.md`, `tests/scenarios/`; out of scope: lens effort, the slice-unit cap
      (#37), changing which surfaces trigger deep-review.
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment, and data are explicit
- [x] Delivery: each repository's branch, PR, target, tracker, and CI source are explicit

## Acceptance criteria
- [x] [machine] `plan-lint.sh owned <plan>` prints one `OWNED\t<n>\t<paths>` line per slice in plan
      order and fails on an invalid plan the way `check` does — checked by:
      `bash plugins/cc-tuner/tests/flow/test_plan_lint.sh` exits 0 with the new `owned-*` checks passing
- [ ] [machine] `shard-diff.sh` on a real git repository: below both thresholds prints `MODE\tsingle`;
      300 changed files prints `MODE\tsharded`; 10000 changed lines in few files prints
      `MODE\tsharded`; with `--plan` groups by Owned paths and puts unmatched files in `rest`; without
      a plan groups by first path component; more than `--max` groups are merged down to `--max`; an
      unknown ref exits non-zero and prints nothing on stdout — checked by:
      `bash plugins/cc-tuner/tests/flow/test_shard_diff.sh` exits 0
- [ ] [machine] `plugins/cc-tuner/skills/deep-review/SKILL.md` has a section `## Sharding` that names
      the script call, the per-shard `shard-<n>.diff` and `shard-<n>-files.txt` the owner writes,
      which four lenses shard and which two do not, and the agent count formula;
      `run/SKILL.md` states the agent count when selecting deep-review; the README's deep-review
      paragraph mentions sharding; `tests/scenarios/task-run/lens-cannot-hold-the-diff.json` records
      the field incident as RED with `skills: ["deep-review"]` and `tests_reference` at the sharding
      anchor, and `tests/scenarios/README.md` has its row — checked by: `bash tests/run.sh` prints
      `ok   scenario provenance is consistent` and `ok   markdown links resolve` and exits 0

## Test plan
- Regression test: `plugins/cc-tuner/tests/flow/test_shard_diff.sh` (new, built on `lib.sh`: a real
  repository under `flow_workdir`, files generated by loop, two commits, assertions on stdout and
  rc); `owned-*` checks appended to `plugins/cc-tuner/tests/flow/test_plan_lint.sh`.
- First failing check: `bash plugins/cc-tuner/tests/flow/test_shard_diff.sh` before the script
  exists; expected failure: every check fails with `No such file or directory` for
  `scripts/shard-diff.sh` and the suite exits 1. For slice 1: `bash plan-lint.sh owned <valid plan>`
  before the mode exists; expected failure: the usage line on stderr and rc 1.
- Targeted checks: `bash plugins/cc-tuner/tests/flow/test_plan_lint.sh`;
  `bash plugins/cc-tuner/tests/flow/test_shard_diff.sh`
- Full regression: `bash tests/run.sh`
- Static/build checks: `bash -n plugins/cc-tuner/scripts/shard-diff.sh`; the rest is inside
  `tests/run.sh` (JSON validity, links, anchors). bash 3.2 compatible: no associative arrays, no
  `mapfile`, because macOS CI runs the same suite.
- Runtime/acceptance environment: none beyond git and jq. A GREEN probe of the scenario is the
  repository's paid eval step and not part of this DoD.
- Negative/mutation proof (name what the killed test must SAY, not only that it goes red): one
  mutation on the file threshold comparison in `shard-diff.sh` (`-ge` → `-gt`, so exactly 300 files
  stays `single`); the killed check must say `FAIL threshold-300-files-shards`. Run through
  `mutate.sh` with `--expect 'threshold-300-files-shards'`.

## Definition of Done
- [ ] Regression check was observed failing for the expected reason before the fix
- [ ] Targeted, full, static/build, runtime, and acceptance checks passed as specified
- [ ] Complete diff and formatter/autofix output were read; no unexplained files remain
- [ ] Applicable advisory reviews ran once; valid findings were addressed or concretely refuted; authoritative Codex review approved the exact candidate SHA
- [ ] PR head equals the reviewed SHA, and CI is green on that SHA under the mode `ci:` declares —
      under `none:` that means no checks exist and a PR comment records the local result for that SHA

## Completion and reconciliation
- [ ] PR is merged with the configured method
- [ ] Spec/archive, issue/board, target sync, branches, and worktrees are reconciled

## Run config
branch: feat/38-lens-sharding
target: main
merge: squash
auto_ready: no — authoritative review is run by the user in Codex outside the cc-codex-triage
    bridge, so `merge.sh` has no review thread to check; the orchestrator publishes
    `cc-tuner-verdict: APPROVE <full-candidate-sha>` only after that review approved the exact SHA,
    and hands the merge to the user. Based on `main` at 0.14.1 (`b566003`, which holds #39, #40 and
    #43); the branch is published, so integrate later `main` movement by merging `origin/main`, never
    by rebasing.
ci: any — `.github/workflows/validate.yml` runs `bash tests/run.sh` on ubuntu-latest and macos-latest
    for every pull request; no branch protection, so every reported check must pass; observe with
    `gh pr checks <pr>`.
target_test: bash plugins/cc-tuner/tests/flow/test_shard_diff.sh
full_test: bash tests/run.sh
tracker: gh
board: none
