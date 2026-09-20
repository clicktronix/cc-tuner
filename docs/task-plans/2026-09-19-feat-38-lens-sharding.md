# Lens sharding — plan

**Spec:** docs/PLANS/2026-09-19-lens-sharding.md
**Branch:** feat/38-lens-sharding

## Slice 1 — One parser hands Owned paths to other scripts
Blocked by: none
Owned paths: plugins/cc-tuner/scripts/plan-lint.sh,plugins/cc-tuner/tests/flow/test_plan_lint.sh
Deciding check: bash plugins/cc-tuner/tests/flow/test_plan_lint.sh
Delivers: `plan-lint.sh owned <plan>` prints `OWNED\t<n>\t<path,...>` per slice in plan order, so a consumer never re-parses the Owned-paths grammar

- [ ] `plan-lint.sh owned` was observed printing the usage line and exiting 1 before the mode existed
- [ ] `owned` prints one line per slice, paths exactly as the plan wrote them, and fails on an invalid plan the way `check` does
- [ ] `--help` names the new mode
- [ ] `bash plugins/cc-tuner/tests/flow/test_plan_lint.sh` exits 0

## Slice 2 — Shards are computed deterministically from the diff
Blocked by: 1
Owned paths: plugins/cc-tuner/scripts/shard-diff.sh,plugins/cc-tuner/tests/flow/test_shard_diff.sh
Deciding check: bash plugins/cc-tuner/tests/flow/test_shard_diff.sh
Delivers: `shard-diff.sh <base> <candidate> [--plan] [--max] [--files] [--lines]` prints `SIZE`, `MODE` and `SHARD` lines a skill can dispatch from, with the cap, the plan grouping, the directory fallback and the fail-closed ref check all proven on a real repository

- [ ] `test_shard_diff.sh` was observed failing with `No such file or directory` before the script existed
- [ ] below both thresholds: `MODE\tsingle`; 300 files: `MODE\tsharded`; 10000 lines in few files: `MODE\tsharded`
- [ ] with `--plan`: groups follow `plan-lint.sh owned`, unmatched files land in `rest`; without: first path component, `root` for top-level files
- [ ] more groups than `--max` merge down to `--max`; unknown ref exits non-zero with empty stdout
- [ ] the `-ge` → `-gt` mutation on the file threshold kills `threshold-300-files-shards`, run through `mutate.sh --expect`
- [ ] bash 3.2 clean: `bash plugins/cc-tuner/tests/flow/test_shard_diff.sh` exits 0

## Slice 3 — deep-review shards its file-local lenses and names the cost
Blocked by: 2
Owned paths: plugins/cc-tuner/skills/deep-review/SKILL.md,plugins/cc-tuner/skills/run/SKILL.md,plugins/cc-tuner/README.md,tests/scenarios/task-run/lens-cannot-hold-the-diff.json,tests/scenarios/README.md
Deciding check: bash tests/run.sh
Delivers: a deep-review that runs `shard-diff.sh` before dispatch, writes `shard-<n>.diff` and `shard-<n>-files.txt` per shard next to `candidate.diff`, sends Correctness, Repository standards, Security and Tests once per shard on those files and Specification and Architecture once on the whole, aggregates across shards by cause, and a `/run` that states `shards × 4 + 2` agents when it selects the route

- [ ] `plugins/cc-tuner/skills/deep-review/SKILL.md` has `## Sharding` with the script call, the per-shard diff and file list the owner writes from the `SHARD` path list, the four-and-two lens split, cross-shard dedupe and the agent count
- [ ] `plugins/cc-tuner/skills/run/SKILL.md` states the agent count when selecting deep-review
- [ ] `plugins/cc-tuner/README.md` deep-review paragraph mentions sharding and the cap of 4
- [ ] `tests/scenarios/task-run/lens-cannot-hold-the-diff.json` holds the 1071-file incident as RED, `skills: ["deep-review"]`, `tests_reference` at the sharding anchor; `tests/scenarios/README.md` has its row and says GREEN is unmeasured
- [ ] `bash tests/run.sh` exits 0
