# Slice unit cap — plan

**Spec:** docs/PLANS/2026-09-19-slice-unit-cap.md
**Branch:** feat/37-slice-unit-cap

## Slice 1 — The implementation unit exists as a capped agent and the validator guards it
Blocked by: none
Owned paths: plugins/cc-tuner/agents/slice-unit.md,tests/run.sh
Deciding check: bash tests/run.sh
Delivers: a `cc-tuner:slice-unit` type that a `/run` session can dispatch, with `maxTurns: 200`, and a suite that goes red if the cap is ever dropped from the definition

- [x] `tests/run.sh` section 5a requires `plugins/cc-tuner/agents/slice-unit.md` to exist and to carry `maxTurns:`; it was observed failing before the file existed
- [x] `plugins/cc-tuner/agents/slice-unit.md` has `name: slice-unit`, `maxTurns: 200`, `model: sonnet`, no `tools:` restriction, and a body that says what the unit hands back
- [x] `bash tests/run.sh` exits 0

Evidence: bash tests/run.sh → `ok   agent definitions declare what their consumers rely on` @ worktree; RED before the file: `FAIL plugins/cc-tuner/agents/slice-unit.md is missing; /run dispatches it by name`; guard: renaming `maxTurns` → `FAIL ... has no numeric maxTurns:`

## Slice 2 — `/run` dispatches through the unit and treats a partial return as a run event
Blocked by: none
Owned paths: plugins/cc-tuner/skills/run/SKILL.md,plugins/cc-tuner/skills/run/references/placement.md,plugins/cc-tuner/README.md,tests/scenarios/task-run/unit-runs-unbounded.json,tests/scenarios/README.md
Deciding check: bash tests/run.sh
Delivers: a `/run` that names `cc-tuner:slice-unit` for implementation, reads what a partial unit landed, redispatches once with the landed state, then takes the slice itself, and records `Partial:` under the slice; a scenario that holds the field incident as RED

- [ ] `plugins/cc-tuner/skills/run/SKILL.md` "Delegating a slice" names `cc-tuner:slice-unit` and the `general-purpose` fallback
- [ ] `plugins/cc-tuner/skills/run/references/placement.md` has `## Unit size and partial returns` with the one-fresh-unit-then-orchestrator rule and the `Partial:` plan line
- [ ] `plugins/cc-tuner/README.md` mentions the unit definition and its cap next to the delegation paragraph
- [ ] `tests/scenarios/task-run/unit-runs-unbounded.json` records the 269-turn unit as RED with `skills: ["run"]` and `tests_reference` pointing at the placement anchor; `tests/scenarios/README.md` has its row and says GREEN is unmeasured
- [ ] `bash tests/run.sh` exits 0, including the anchor and provenance checks
