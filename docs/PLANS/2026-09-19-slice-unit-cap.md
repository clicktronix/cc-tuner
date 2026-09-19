# Slice units get a platform turn cap; partial returns are a run event

**Goal:** an implementation unit dispatched by `/cc-tuner:run` cannot run unbounded, and a unit that
hits its cap returns to the orchestrator as a normal event with a defined next step.
**Issue:** #37
**Architecture:** One agent definition, `plugins/cc-tuner/agents/slice-unit.md`, carries what
repeats on every implementation dispatch and cannot be expressed on a dynamic `Agent` call:
`maxTurns: 200`, `model: sonnet` as the default (a per-call `model` still overrides it), an
unrestricted tool list because the unit writes code and, under the machine's spawn depth of 2, may
run its own `Explore` lookup. The brief stays the committed spec plus the slice's own text. `/run`
dispatches implementation as `cc-tuner:slice-unit`; there is no uncapped fallback — when the host
does not list the type, the orchestrator does the slice itself and says so, because an uncapped
`general-purpose` unit is what the definition exists to prevent (changed after Codex review of the
first candidate, 2026-09-19). A partial return (the platform marks a unit that hit
`maxTurns` as partial) is handled by the orchestrator: read what landed in the worktree, dispatch
**one** fresh unit with a brief that states what is done and what remains, and take the slice itself
on a second partial return — the same shape as the existing "failed the deciding check twice" rule.
The plan records it under the slice as `Partial: <unit> at maxTurns; landed <commits>; redispatched once`.
Rejected: resuming the same unit through `SendMessage` (keeps growing the 300k–400k context the cap
exists to stop); a turn budget stated in the brief (a prose limit already failed in the field: a unit
told not to delegate delegated anyway).

## Definition of Ready
- [x] Problem/baseline: field audit of 399 subagent transcripts (personal-os
      `docs/2026-09-19-cc-tuner-subagent-field-audit.md` §2.2): 79 units ran past 150 turns, 41 ended
      above a 300k context, the largest ran 269 turns to 420k and wrote 1.17M cache tokens for one
      slice. Nothing capped them: `maxTurns` exists only in an agent definition and the plugin ships
      none for implementation.
- [x] Scope: `plugins/cc-tuner/agents/`, `plugins/cc-tuner/skills/run/`, `plugins/cc-tuner/README.md`,
      `tests/run.sh`, `tests/scenarios/task-run/`, `tests/scenarios/README.md`; out of scope: effort
      levels (unmeasured), review lenses and diff sharding (#38).
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment, and data are explicit
- [x] Delivery: each repository's branch, PR, target, tracker, and CI source are explicit

## Acceptance criteria
- [x] [machine] `plugins/cc-tuner/agents/slice-unit.md` exists with `name: slice-unit`,
      `maxTurns: 200` and `model: sonnet`, and `tests/run.sh` refuses a tree where that file lacks
      `maxTurns:` — checked by: `bash tests/run.sh` prints `ok   agent definitions declare what their
      consumers rely on` and exits 0
- [x] [machine] `/run` dispatches implementation units as `cc-tuner:slice-unit` with no uncapped
      fallback (the orchestrator does the slice itself), and `placement.md` carries a section `## Unit size and partial
      returns` holding the partial-return rule and the `Partial:` plan line — checked by:
      `grep -c 'cc-tuner:slice-unit' plugins/cc-tuner/skills/run/SKILL.md` prints at least 1, and
      `bash tests/run.sh` resolves the scenario anchor
      `plugins/cc-tuner/skills/run/references/placement.md#unit-size-and-partial-returns`
- [x] [machine] `tests/scenarios/task-run/unit-runs-unbounded.json` records the field incident as its
      RED, names `run` as its skill and the placement anchor as `tests_reference`, and
      `tests/scenarios/README.md` has its row; no GREEN is claimed — checked by: `bash tests/run.sh`
      prints `ok   scenario provenance is consistent`

## Test plan
- Regression test: the agent-definition rule in `tests/run.sh` (section 5a) extended to require
  `maxTurns:` on `agents/slice-unit.md`; the scenario JSON above.
- First failing check: add the `tests/run.sh` rule before the agent file exists, run
  `bash tests/run.sh`; expected failure: `FAIL plugins/cc-tuner/agents/slice-unit.md is missing` (or
  `has no maxTurns:`), exit 1.
- Targeted checks: `bash tests/run.sh`
- Full regression: `bash tests/run.sh`
- Static/build checks: covered inside `tests/run.sh` (`jq empty` on every JSON, `bash -n` is implicit
  in running the suites); `not applicable` beyond that — no build.
- Runtime/acceptance environment: none. A GREEN probe of the scenario is the repository's paid eval
  step (`tests/eval/README.md`) and is not part of this DoD; the scenario ships with RED only.
- Negative/mutation proof (name what the killed test must SAY, not only that it goes red):
  `not applicable — the validator rule is watched failing before the agent file exists (first failing
  check above), which is the same evidence a mutation would buy.`

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
branch: feat/37-slice-unit-cap
target: main
merge: squash
auto_ready: no — the cc-codex-triage required-review contract is not installed (prereq-check on
    2026-09-19); install it before `/run` reaches candidate review. Stacked on
    `feat/subagent-constraints` (PR #39): after #39 is squash-merged, retarget PR #40 to `main`,
    fetch origin and merge `origin/main` into this published, reviewed branch. Do not rebase it.
    Re-run `bash tests/run.sh`, publish the integrated candidate and wait for CI on its new SHA.
    Obtain fresh authoritative approval for that full SHA in the same review thread and worktree,
    then publish `cc-tuner-verdict: APPROVE <full-candidate-sha>` only if that review approved it.
    Both `merge.sh --check-only` and merge require the installed companion contract, its matching
    approval state, the public verdict and passing CI; check-only is not a fallback when the
    contract is missing. Use `--ci any` and the same review thread for the final checked handoff.
ci: any — `.github/workflows/validate.yml` runs `bash tests/run.sh` on ubuntu-latest and macos-latest
    for every pull request; no branch protection, so every reported check must pass; observe with
    `gh pr checks <pr>`.
target_test: bash tests/run.sh
full_test: bash tests/run.sh
tracker: gh
board: none
