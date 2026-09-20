# Lens sharding — plan

**Spec:** docs/PLANS/2026-09-19-lens-sharding.md
**Branch:** feat/38-lens-sharding

## Slice 1 — One parser hands Owned paths to other scripts
Blocked by: none
Owned paths: plugins/cc-tuner/scripts/plan-lint.sh,plugins/cc-tuner/tests/flow/test_plan_lint.sh
Deciding check: bash plugins/cc-tuner/tests/flow/test_plan_lint.sh
Delivers: `plan-lint.sh owned <plan>` prints `OWNED\t<n>\t<path,...>` per slice in plan order, so a consumer never re-parses the Owned-paths grammar

- [x] `plan-lint.sh owned` was observed printing the usage line and exiting 1 before the mode existed
- [x] `owned` prints one line per slice, paths exactly as the plan wrote them, and fails on an invalid plan the way `check` does, missing headers included
- [x] `--help` names the new mode
- [x] `bash plugins/cc-tuner/tests/flow/test_plan_lint.sh` exits 0

Evidence: bash plugins/cc-tuner/tests/flow/test_plan_lint.sh → `PASS owned-one-line-per-slice-in-plan-order` … 101 PASS, rc 0 @ worktree; RED before the mode: `plan-lint: usage: plan-lint.sh check|slices|frontier|ready-batches <file> …`, rc 1

## Slice 2 — Shards are computed deterministically from the diff
Blocked by: 1
Owned paths: plugins/cc-tuner/scripts/shard-diff.sh,plugins/cc-tuner/tests/flow/test_shard_diff.sh
Deciding check: bash plugins/cc-tuner/tests/flow/test_shard_diff.sh
Delivers: `shard-diff.sh <base> <candidate> [--plan] [--max] [--files] [--lines]` prints `SIZE`, `MODE` and `SHARD` lines a skill can dispatch from, with the cap, the plan grouping, the directory fallback and the fail-closed ref check all proven on a real repository

- [x] `test_shard_diff.sh` was observed failing with `No such file or directory` before the script existed
- [x] below both thresholds: `MODE\tsingle`; 300 files: `MODE\tsharded`; 10000 lines in few files: `MODE\tsharded`
- [x] with `--plan`: groups follow `plan-lint.sh owned`, unmatched files land in `rest`; without: first path component, `root` for top-level files
- [x] more groups than `--max` merge down to `--max`; unknown ref exits non-zero with empty stdout
- [x] a group at a threshold splits into chunks below it; a cap that cannot hold refuses with the needed count; a rename lists both paths; non-ASCII and magic-looking names survive into the documented packet; comma/tab/newline paths are refused (Codex review 2026-09-20)
- [x] the `-ge` → `-gt` mutation on the file threshold kills `threshold-300-files-shards`, run through `mutate.sh --expect`
- [x] bash 3.2 clean: `bash plugins/cc-tuner/tests/flow/test_shard_diff.sh` exits 0

Evidence: bash plugins/cc-tuner/tests/flow/test_shard_diff.sh → 34 PASS, rc 0 @ worktree after Codex round 1 (18 PASS on the first candidate); RED before the script: 15 FAIL, direct call `bash: plugins/cc-tuner/scripts/shard-diff.sh: No such file or directory`; mutation: the threshold lives in awk, so the assigned `-ge` → `-gt` is `files < files_t` → `files <= files_t`; `mutate.sh --expect 'FAIL threshold-300-files-shards'` → `KILLED … green before, red on the mutant, green again once restored`, mutant log: only `FAIL threshold-300-files-shards`, re-run on the rewritten script with the same verdict

## Slice 3 — deep-review shards its file-local lenses and names the cost
Blocked by: 2
Owned paths: plugins/cc-tuner/skills/deep-review/SKILL.md,plugins/cc-tuner/skills/run/SKILL.md,plugins/cc-tuner/README.md,tests/scenarios/task-run/lens-cannot-hold-the-diff.json,tests/scenarios/README.md
Deciding check: bash tests/run.sh
Delivers: a deep-review that runs `shard-diff.sh` before dispatch, writes `shard-<n>.diff` and `shard-<n>-files.txt` per shard next to `candidate.diff`, sends Correctness, Repository standards, Security and Tests once per shard on those files and Specification and Architecture once on the whole, aggregates across shards by cause, and a `/run` that states `shards × 4 + 2` agents when it selects the route

- [x] `plugins/cc-tuner/skills/deep-review/SKILL.md` has `## Sharding` with the script call, the per-shard diff and file list the owner writes from the `SHARD` path list, the four-and-two lens split, cross-shard dedupe and the agent count
- [x] `plugins/cc-tuner/skills/run/SKILL.md` states the agent count when selecting deep-review
- [x] `plugins/cc-tuner/README.md` deep-review paragraph mentions sharding and the cap of 4
- [x] `tests/scenarios/task-run/lens-cannot-hold-the-diff.json` holds the 1071-file incident as RED, `skills: ["deep-review"]`, `tests_reference` at the sharding anchor; `tests/scenarios/README.md` has its row and says GREEN is unmeasured
- [x] `bash tests/run.sh` exits 0

Evidence: bash tests/run.sh → `ok   scenario provenance is consistent (20 scenarios)`, `ok   markdown links resolve`, `cc-tuner validate ok`, exit 0 @ worktree; RED before the section, with the validator's own anchor logic: `FAIL tests/scenarios/task-run/lens-cannot-hold-the-diff.json references missing anchor #sharding in plugins/cc-tuner/skills/deep-review/SKILL.md`
