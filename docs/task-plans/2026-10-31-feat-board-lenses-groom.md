# Board moves, blind spots, grooming — plan

**Spec:** docs/PLANS/2026-10-31-board-lenses-groom.md
**Branch:** feat/board-lenses-groom

## Slice 1 — Cards move as spec and run advance
Blocked by: none
Owned paths: plugins/cc-tuner/skills/spec/SKILL.md,plugins/cc-tuner/skills/run/SKILL.md,plugins/cc-tuner/skills/task-flow/SKILL.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: an agent following `/spec` then `/run` puts the issue's card on the board and moves it Todo → In Progress → In review → Done, with the epic's card following, and recovers from a missing card or stale IDs instead of failing on an empty item ID

- [x] The new board `need` lines were observed failing before the text existed
- [x] `/spec` and `/run` name each move at its moment and send the agent to `task-flow`'s Board recipes
- [x] The recipes state the missing-card, stale-ID and empty-ID cases
- [x] `bash plugins/cc-tuner/tests/contract/test_contract.sh` exits 0

Evidence: bash plugins/cc-tuner/tests/contract/test_contract.sh → 111 PASS, rc 0 @ worktree; RED before the text: 8 FAIL (`spec-puts-the-card-on-the-board` … `recipes-refresh-stale-option-ids`), rc 1

## Slice 2 — Deep-review sees blind spots and asks past its limit
Blocked by: 1
Owned paths: plugins/cc-tuner/skills/deep-review/SKILL.md,plugins/cc-tuner/agents/deep-review-lens.md,plugins/cc-tuner/skills/run/references/placement.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: a deep-review runs seven lenses (sharded `shards × 4 + 3`, limit 19) with Architecture, Security and Blind spots on Opus, prints the split by model, and asks the user how to proceed when the count exceeds the limit

- [x] The new deep-review `need` lines were observed failing before the text existed
- [x] Blind spots findings are P3 or owner questions, never blockers
- [x] Placement's ladder names the Opus lenses
- [x] `bash plugins/cc-tuner/tests/contract/test_contract.sh` exits 0

Evidence: bash plugins/cc-tuner/tests/contract/test_contract.sh → 116 PASS, rc 0 @ worktree; RED before the text: 7 FAIL (`deep-review-lens-limit` … `placement-names-opus-lenses`), rc 1

## Slice 3 — Spec looks for what nobody considered, and grooms without a branch
Blocked by: 2
Owned paths: plugins/cc-tuner/skills/spec/SKILL.md,plugins/cc-tuner/agents/blind-spots.md,plugins/cc-tuner/skills/run/references/placement.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: `/spec` runs a read-only Opus blind-spots pass before approval and turns its returns into grilling questions; `/spec --groom <issue>` records decisions, acceptance and open questions in the issue with no branch, spec or plan, and a later `/spec <issue>` builds on that record

- [ ] The new spec `need` lines and the agent frontmatter check were observed failing first
- [ ] `agents/blind-spots.md` is Opus and read-only
- [ ] `--groom` refuses under `tracker: none`
- [ ] `bash plugins/cc-tuner/tests/contract/test_contract.sh` exits 0

## Slice 4 — Verification runs beside the orchestrator
Blocked by: 3
Owned paths: plugins/cc-tuner/skills/run/SKILL.md,plugins/cc-tuner/skills/run/references/placement.md,plugins/cc-tuner/README.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash tests/run.sh
Delivers: `/run` hands `verify-feature` to a Sonnet subagent and keeps only its record, the owner still deciding `[eyes]` criteria; the README describes every behaviour this plan adds

- [ ] The new verify `need` line was observed failing before the text existed
- [ ] The README names the board moves, the Blind spots lens and pass, `--groom` and the verify subagent
- [ ] `bash tests/run.sh` exits 0
