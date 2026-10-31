# Board moves in spec and run, a blind-spots lens, grooming without a branch

**Goal:** board cards move as `/spec` and `/run` advance; deep-review has a Blind spots lens, runs
its reasoning-heavy lenses on Opus and asks the user past its lens limit; `/spec` looks for what the
user did not consider before approval and can groom an issue without a branch; `verify-feature` runs
in a Sonnet subagent.
**Issue:** #62
**Architecture:** `/spec` and `/run` own *when* a card moves; `task-flow`'s Board recipes own *how*,
including the failure modes field sessions hit. Each card step in `/spec` and `/run` tells the agent
to read those recipes, because `/run` does not load `task-flow` on its own. Placement's model ladder
gains the new Opus and Sonnet dispatches so it does not contradict them. A new read-only agent,
`blind-spots` (Opus; Read, Grep, Glob, WebSearch, WebFetch), serves `/spec`; deep-review's Blind
spots lens is a `deep-review-lens` dispatched with `model: "opus"`. Rejected: a `board.sh` script
(user's choice: steps in the text), keeping 18 as the limit (the default four shards would then ask
every time), and a general-purpose agent for the spec pass (read-only would rest on the brief alone).

## Definition of Ready
- [x] Problem/baseline: 17 stokli/marqa transcripts — backend `a60215c8` ran `merge.sh` 21 times and
  `item-edit` twice, never In Progress; stokli's `task-flow.local.md` holds IDs but no instruction;
  `item-edit` failed on an empty item ID five times in marqa and on stale option IDs in stokli;
  epics #736 and #1177 were moved by hand. `grep item-edit` over `skills/run`, `skills/spec` and
  `scripts/merge.sh` is empty.
- [x] Scope: `skills/{spec,run,task-flow,deep-review}/SKILL.md`, `skills/run/references/placement.md`,
  `agents/deep-review-lens.md`, new `agents/blind-spots.md`, `plugins/cc-tuner/README.md`,
  `tests/contract/test_contract.sh`; out of scope: `merge.sh`, a board script, cc-codex-triage.
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment, and data are explicit
- [x] Delivery: one repository, branch `feat/board-lenses-groom`, PR to `main`, tracker gh, CI `validate.yml`

## Acceptance criteria
- [x] [machine] `/spec` adds or confirms the issue's card after approval; `/run` sets In Progress when
  implementation opens, In review when the PR opens if the board has that option, and Done after the
  merge that fully closes the issue; an epic's card follows its first and last sub-issue; each step
  sends the agent to `task-flow`'s Board recipes, which state the missing-card, stale-ID and
  empty-ID cases — checked by: `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- [x] [machine] deep-review runs 7 lenses in single mode and `shards × 4 + 3` sharded, limit 19;
  Architecture, Security and Blind spots are dispatched with `model: "opus"`; Blind spots findings are
  P3 or owner questions only; past the limit it asks with `AskUserQuestion` (run all / cut to the
  limit → `INCOMPLETE` naming unread lenses and paths / larger shards); the printed line shows the
  split by model — checked by: `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- [x] [machine] `/spec` dispatches `cc-tuner:blind-spots` after the draft contract and before the
  approval and turns its returns into grilling questions; `--groom` writes decisions, acceptance and
  open questions into the issue without a branch, spec or plan, refuses under `tracker: none`, and a
  later `/spec <issue>` does not re-ask what the groom record settled; `agents/blind-spots.md` has
  `model: opus` and no Bash, Edit, Write or Agent tool — checked by:
  `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- [x] [machine] `/run` dispatches `verify-feature` in a Sonnet subagent, takes back only its record,
  and keeps `[eyes]` criteria with the owner — checked by:
  `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- [x] [machine] The plugin README names the new behaviour and the repository suite passes — checked
  by: `bash tests/run.sh`

## Test plan
- Regression test: new `need` lines in `plugins/cc-tuner/tests/contract/test_contract.sh`, one per
  criterion phrase, plus a frontmatter check for `agents/blind-spots.md`.
- First failing check: `bash plugins/cc-tuner/tests/contract/test_contract.sh`; expected failure:
  `FAIL run-moves-card-in-progress` and the other new names before the text exists.
- Targeted checks: `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- Full regression: `bash tests/run.sh`
- Static/build checks: not applicable — instruction text and Markdown; `tests/run.sh` checks JSON,
  versions, plugin-root references and skill size.
- Runtime/acceptance environment: none beyond bash and jq.
- Negative/mutation proof: not applicable — the contract test is watched failing before each text
  change, which is the same evidence.

## Definition of Done
Recorded on the PR before merge, not ticked here (it would move the reviewed SHA).
- Regression check was observed failing for the expected reason before the fix
- Targeted, full, static/build, runtime, and acceptance checks passed as specified; verify-feature's
  record is on the PR
- Complete diff and formatter/autofix output were read; no unexplained files remain
- One advisory route ran (with at most one escalation to deep-review); valid findings were addressed
  or concretely refuted; the required review `review:` names approved the exact candidate SHA
- PR head equals the reviewed SHA, and CI is green on that SHA under the mode `ci:` declares
  (`../run/references/local-ci.md`)

## Completion and reconciliation
Reported after merge, not committed.
- PR is merged with the configured method
- Spec/archive, issue/board, target sync, branches, and worktrees are reconciled

## Sources
- Field investigation of stokli and marqa transcripts, 2026-10-31 (personal-os session), with the
  user's choices recorded in the same session.

## Run config
branch: feat/board-lenses-groom
target: main
merge: squash
auto_ready: no — the user merges; review runs through cc-codex-triage.
ci: any — `.github/workflows/validate.yml` runs `bash tests/run.sh` on ubuntu-latest and macos-latest
    for every pull request; observe with `gh pr checks <pr>`.
review: codex — cc-codex-triage is installed and reviews this repository.
target_test: bash plugins/cc-tuner/tests/contract/test_contract.sh
full_test: bash tests/run.sh
full_test_cadence: per-candidate
tracker: gh
board: none
