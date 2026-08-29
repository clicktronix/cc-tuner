# The authenticated eval

This file records observations and provenance. The current completion requirement lives only in
Task 8 Step 7 of `docs/superpowers/plans/2026-08-13-native-first-lifecycle.md`.

The only tier that can prove a skill causes `TaskCreate` to be called.

Everything else in this repository tests **scripts**: `tests/flow/` runs them against real git
repositories with real payloads on stdin, and can settle every question about what a script decides.
None of it can settle whether a skill makes a model do something, because in that tier no producer
exists. That is what this is for, and it is why `tests/run.sh` does not include it: it needs auth,
it costs tokens, and it runs by hand.

**Observation index after run 7.** What each behaviour was last observed against:

| step | last observed at | in |
|---|---|---|
| 0 — this checkout | `c69fd80` | run 7 |
| 1 — attended whole flow | `c69fd80` | run 7, complete through checked merge |
| 2 — `--auto` whole flow | `2247c8c` | run 5; auto-specific decisions unchanged since that observation |
| 2 — the `blockedBy` refusal, isolated | `2247c8c` | run 5; frontier and dependency decisions unchanged |
| 2b — `--check-only` then the same script merges | `c69fd80` | run 7 |
| 3 — recovery: fresh session, `/clear`, `/compact` | `2247c8c` | run 5; recovery hook and graph reconstruction unchanged |
| 4 — live denial, both branches | `2247c8c` | run 5; the later missing-check diagnostic is covered by its deterministic regression |
| 5 — the nine probes | `3229c57` | historical evidence re-measured 2026-08-25 under protocol version 2, isolated |
| 7 — proportional release validation | `c69fd80` | **partial**: run 7 is the grandfathered frozen end-to-end smoke; the positive `deep-review` route remains to be observed |
| 6 — this file | `c69fd80` evidence | run 7 record |

The table records what was actually observed; the branch plan defines completion. `EVALUATED_SHA`
proves which production surface the latest frozen run exercised, not that every retained observation
was repeated there.

One check holds what used to be prose: `tests/run.sh` refuses an `accepted` ADR while the shipped tree
has moved past `EVALUATED_SHA`. Scenario results keep their measured-against provenance but no longer
force a new paid sample after every skill edit. Twice the record claimed the
evaluated artifact was the shipped one while a later commit had already moved it; the third time it
was made true by running again rather than by arguing which tier covered the difference — and then
made **checkable**: `EVALUATED_SHA` in this directory names the evaluated commit, and `tests/run.sh`
refuses to let the ADR say "accepted" while the production surface has moved past it. Editing a skill
stays allowed; claiming the eval saw it does not. Run 2's statuses were corrected twice after review before run 3 started;
they stand below unchanged, because a superseded result is evidence about the method and deleting it
would leave only the flattering half.

| step | run 3 | run 2 |
|---|---|---|
| 0 | **PASS** — SHA frozen in a detached worktree before the first session, plugin root proved in both repos | PARTIAL — path recorded, no SHA |
| 1 | **PASS** — one session, `/spec → /plan → native tasks → /run → merge`, against a clause amended for the reason in finding 13 | PARTIAL — assembled from two sessions |
| 2 | **PASS** — plan to merged PR in a single unattended turn, twice; the `blockedBy` refusal took a second, isolating fixture and then a third pass to measure it under `--auto` rather than attended (finding 11, run 3b) | PARTIAL — 3 of 5 |
| 2b | **PASS** — `--check-only` accepted, then the same script merged | PASS |
| 3 | **PASS** — same edges after a fresh session and after `/clear`; no duplication after `/compact` | not run |
| 4 | **PASS** — both denials live, `rc=1` | PASS |
| 5 | **PASS**, on the third telling. The 2026-08-24 round claimed all nine at 8 of 8 with no abstentions; it had one abstention, ran a tenth sample it did not need, judged three answers against the skill rather than against the committed question, and ran without `--safe-mode` so five answers on one probe reached the operator's own installed skills. It was voided at `3229c57` and re-measured under protocol version 2. | PASS, and it caught a live regression |
| 6 | this file | this file |

**The promised flow was observed end to end, in one session, twice** — attended in
`cc-tuner-eval-3` and unattended in `cc-tuner-eval-4`. What run 3 does not carry is a human at a
terminal: the sessions were driven headless and the operator was another Claude Code session. The
harness is described in full at the top of run 3, and every claim here is bounded by it.

A step recorded as passing on the strength of reading a skill's text is the exact failure this branch
exists to remove — so a step is either observed or it is blank.


## Review of 2026-08-20, and what it changed

An external review challenged the statuses above. Most of it held; two things in it did not, and both
were settled by counting tool calls rather than by argument.

**Held, and acted on.** Step 1 was PASS on evidence assembled from two sessions — `/run` from one and
the task list from another, the latter being the session whose `/run` was the *installed* plugin. The
step names a single attended flow, and a composite is not one. Step 2 was "PASS, one part unmeasured"
when two of its five assertions have no observation. Both corrected above. The rule was already
written in this file — a step is either observed or it is blank — and it took a reviewer to apply it
to my own results.

**Did not hold, on the facts.** The review states the task tools were missing "in both eval sessions".
There were three, and in the first they existed and `/plan` used them:

| transcript | TaskCreate | TaskUpdate | TaskList |
|---|---|---|---|
| `b15e8fc3` (eval-1, run 1) | **4** | **3** | **1** |
| `2a4ddf8e` (eval-1, run 2) | 0 | 0 | 0 |
| `98c8f6ed` (eval-2, `--auto`) | 0 | 0 | 0 |

Four tasks, then exactly three `addBlockedBy` matching the plan file's edges. That is the only
observation of the visible plan existing at all, it came from this checkout's `/plan`, and it stands.
It does not rescue step 1 — it belongs to a different session — but it is not nothing, and the record
should not lose it.

**Also settled by measurement rather than assumed:**

- *Capability probe, both branches the review asked for.* On 2.1.235, an Opus 5 session calling
  `TaskCreate` answers `UNAVAILABLE` **without** the plugin and `UNAVAILABLE` **with**
  `--plugin-dir`. So this is an environment limitation cc-tuner must surface, not a frontmatter or
  routing defect. `doctor` now reports the variable that usually causes it — a hint, not a probe: a
  separate process cannot ask a session which tools it holds. The capability answer belongs to
  `/plan`, which is in that session and finds out by calling (finding 9).
- *No gate was waived.* The review saw an offer to merge with the Codex gate waived. It was not taken:
  the thread records `status=APPROVED`, `verdict=APPROVE`, `gate_eligible=true`, and the single
  contextual use of "waiver" in the transcript is about the spec's `[eyes]` criterion, which records
  `waiver: none` and was signed off, not waived.
- *Step 5 was not run against the deleted runtime.* All nine probes were re-measured on 2026-08-20
  against the skills as shipped at `32f362b`, after the old runtime was gone. One reproduced its own
  baseline, and that regression is finding 8.

**What remains true and is the point of the review:** Task 8 is not complete. Steps 1, 2 and 3 all
need a session in which the task tools exist, and until then the promised flow —
`/spec → /plan → native tasks → /run` — has never been observed end to end in one session.

> **Superseded by run 3 (2026-08-21).** The tools were there — `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` in
> the environment — and the flow was observed end to end twice. The paragraph above is left standing
> because it is what the record said before the run, and the method that produced it was right; only
> its conclusion expired.


### Evidence captured before the eval repositories were deleted (2026-08-20)

`clicktronix/cc-tuner-eval-1` and `-2` are gone — confirmed by `gh api repos/…` returning 404 for both
and by neither appearing in `gh repo list`, not by the delete command exiting quietly.

**One revision of this section claimed the deletion before it had happened.** The first `gh repo
delete` failed for want of the `delete_repo` scope and the sentence recorded the intention as the act,
in the file whose whole purpose is to catch that. It is left on the record here rather than quietly
overwritten, because it is the same defect as every finding below: a claim written from what was meant
rather than from what was checked.

Captured while they still existed, so the citations below stay checkable:

| | |
|---|---|
| `cc-tuner-eval-1` PR #3 | **MERGED** 2026-08-18T19:00:57Z, head `5905a3ef`, title "Retry budget for the HTTP client" |
| — its two verdicts | `cc-tuner-verdict: REQUEST_CHANGES 7d1c028b…` at `7d1c028b`, then `cc-tuner-verdict: APPROVE 5905a3ef…` at `5905a3ef` — the second at the exact head, four minutes before the merge |
| — merge path | `scripts/merge.sh 3 squash 5905a3ef…`, not a raw `gh pr merge` |
| — gate state | `status=APPROVED verdict=APPROVE gate_eligible=true round=1` |
| `cc-tuner-eval-1` PR #1 | CLOSED — the setup probe that confirmed `gh pr checks --required` returns `pass` |
| `cc-tuner-eval-2` PR #2 | OPEN at head `22b1e3ae`, the `--auto` run, never merged |

**The transcripts are the primary record and survive the deletion** — they live under
`~/.claude/projects/`, not in the repositories:

- `-…-cc-tuner-eval-1/b15e8fc3-…jsonl` — run 1, the only session in which the task tools existed
- `-…-cc-tuner-eval-1/2a4ddf8e-…jsonl` — run 2, `/run` from this checkout through to the merge
- `-…-cc-tuner-eval-2/98c8f6ed-…jsonl` — the `--auto` run

Local clones were kept at `~/Projects/ai/cc-tuner-eval-{1,2}`. Note that eval-1's clone holds only
two commits: the squash merge collapsed the branch, and the branch history existed only on GitHub.

## What it costs

One session per scenario, two scratch repositories, and a handful of real PRs. Budget an hour of
attended time; most of it is waiting on CI. The two flow runs are the expensive part, and they are
deliberately not shareable — step 2 must not inherit step 1's workspace.

## Before you start

Read [`fixture-spec.md`](fixture-spec.md): the task to hand `/cc-tuner:spec`, which two repositories
to run it in, and why that task rather than a smaller one.

The repositories are built fresh for each run — `-1` and `-2` for run 2, `-3` and `-4` for run 3 —
because the fixture's defect has to be present on `main` for the spec's baseline to reproduce, and a
previous run's merge removes it. What that setup has to get right: a GitHub remote, `gh auth status`
clean, a runnable test command, and **at least one required status check on the target branch**.
`merge.sh` refuses a repository that requires nothing — absent CI is unproven CI — so a repo without
branch protection fails step 2b for a reason that has nothing to do with the code under test.

## Running it

**First, disable the installed copy in the eval repository** — already done in both, but this is the
step to repeat if the repos are ever recreated. `--plugin-dir` adds a second plugin of the same name
rather than replacing the installed one, and run 1 showed `/cc-tuner:run` resolving to the installed
`commands/run.md` while `/spec` and `/plan` resolved locally:

```bash
cd <eval-repo> && claude plugin disable cc-tuner@cc-tuner --scope local
```

Then freeze the SHA **as a property, not a promise**, and launch against the frozen tree:

```bash
git -C <path-to-this-repo> worktree add --detach /tmp/cc-tuner-frozen <sha>
cd <eval-repo> && claude --plugin-dir /tmp/cc-tuner-frozen/plugins/cc-tuner
```

A detached worktree cannot follow the branch, so a fix committed mid-run — which is what happened in
run 2, and why it could record no SHA — changes nothing the session is reading. Record the SHA and
the resolved plugin root in the log:

```
/cc-tuner:setup          # the doctor call it runs carries the expanded ${CLAUDE_PLUGIN_ROOT}
git -C <path-to-this-repo> rev-parse HEAD
```

The proof is the expanded path in the session's own Bash calls, and the *absence* of
`~/.claude/plugins/cache/cc-tuner/` from the whole transcript. Both are greppable if the session is
run with `--output-format stream-json`.

Also export `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` before launching, or steps 1, 2 and 3 measure a session
with no task tools — finding 9.

This is step 0 and it is not ceremony. Without it the eval can exercise the installed 0.10.0 and
report a pass — which is not hypothetical. It is the original defect: sessions holding a frozen
`${CLAUDE_PLUGIN_ROOT}` while everyone read the new code.

## The steps

Each one is written out in `docs/superpowers/plans/2026-08-13-native-first-lifecycle.md` under
Task 8, with what it must observe and why it exists. In brief:

| # | What it observes |
|---|---|
| 0 | The session is running this checkout, proved by the recorded path and SHA |
| 1 | Attended `spec → run`: branch before the first committed write of any kind — amended from "before `CONTEXT.md`", finding 13 — one approval of contract+slices, spec and plan committed, plan linting clean, `TaskList` carrying **`blockedBy` edges**, frontier order, checkboxes ticked, local commits uninterrupted, stops before the first push/PR and before merge |
| 2 | Unattended delivery, **fresh repository and session**: one approval in `/spec`, then no questions or delivery stops after the `/run --auto` handoff; plan committed, tasks created when available, and a task with a non-empty `blockedBy` refused out of order |
| 2b | Producer → checked path: verdict posted only after the `--required` marker, `commit.oid` equal to the head SHA, and `merge.sh --check-only` reporting the candidate would be accepted |
| 3 | Recovery on the **graph**: same `blockedBy` edges after a fresh session, same after `/clear`, no duplication after `/compact` |
| 4 | Live denial: `merge.sh --check-only` on a head SHA with no verdict refuses, naming the missing fact |
| 5 | The nine `tests/scenarios/task-run/` probes recorded with their historical provenance |
| 6 | Every outcome recorded here, dated, and committed |

Step 3 asserts the edges, not the row count: a rebuilt list with the right number of tasks and no
dependencies is the failure a one-pass implementation produces, and it looks correct from a distance.

Step 5 exists because all nine GREEN runs were first taken against guidance later replaced. Each
scenario now records the exact historical revision it measured. A targeted probe is re-run only when
a repeated behavioural failure justifies the token cost; current lifecycle acceptance comes from the
frozen live Step 7. **A scenario that no longer reproduces is a finding about the rewrite, not a
scenario to delete.**

## Acceptance

Task 8 Step 7 owns the current release rule: one frozen end-to-end smoke on the candidate, then only
the deterministic checks and focused live probes named in a precommitted impact record. Earlier live
observations remain evidence for decisions that did not change. Not-yet-run targeted probes do not
count as a pass, and the branch is not finished until this file says so.

**What this eval does not cover, stated here rather than left in the prose of a run.** Run 3 was
driven headless: `claude -p` with `--resume`, one process per turn, the operator another session. That
observes what the skills cause — every tool call, every file, every exit code — and it does not
observe the **interactive surface**: the task list as it renders in a terminal, checkpoints, and
whether a watching human can see the plan being worked. Run 2 hit exactly that gap from the other
side, when its operator could see no tasks in the checkpoint UI while the transcript showed the flow
running. Run 7 supplied that attended terminal observation. The earlier headless evidence remains
bounded as described; run 7 does not retroactively turn it into an interactive run.

## Release-candidate impact record

This record was committed before the remaining focused probe. The operator explicitly grandfathered
successful run 7 on 2026-08-29 as the current frozen end-to-end smoke; the exception is recorded
because the proportional rule did not exist when that run began.

```text
policy_commit: 6766184d9b9043628284294c05183e86e3fc1947
production_candidate: c69fd80109e8a907335643a9eec99d07bfca167e
retained_evidence_from: 2247c8ce5572f8c0421bb1edd950f9ba21f0d9a4
range: 2247c8ce5572f8c0421bb1edd950f9ba21f0d9a4..c69fd80109e8a907335643a9eec99d07bfca167e
changed:
  plugins/cc-tuner/scripts/merge.sh
  plugins/cc-tuner/skills/deep-review/SKILL.md
  plugins/cc-tuner/skills/run/SKILL.md
  plugins/cc-tuner/skills/run/references/placement.md
  plugins/cc-tuner/skills/spec/spec-template.md
```

- **Observed on run 7:** the attended lifecycle, task projection, outward checkpoints, exact-SHA
  verdict publication, required-review retry and checked positive merge; the small non-sensitive
  branch correctly skipped `deep-review`.
- **Still owed:** one focused product-route probe in which a large or sensitive candidate causes
  `/run` to invoke `deep-review`.
- **Deterministic coverage:** the `merge.sh` change only classifies the current `gh` wording for an
  absent required check; `test_merge.sh` reproduces that input. It does not alter the earlier
  missing-verdict or non-approval branches.
- **Retained from run 5:** unattended `--auto`, the isolated `blockedBy` refusal, recovery and both
  denial branches. Their model decisions did not change in the range above; no file-name map is used
  as a substitute for that review.

## Log

Written in the MEASURED style of `docs/spike-native-flow.md`: what was run, what was seen, and what
that does or does not establish. Leave the outcome blank until it is observed.

### Run 7 — 2026-08-29, attended path against `c69fd80`

Frozen at `c69fd80109e8a907335643a9eec99d07bfca167e` in the detached worktree
`/Users/clicktronix/Projects/ai/cc-tuner-frozen-11`; fresh public repository
`clicktronix/cc-tuner-eval-23`; `CLAUDE_CODE_ENABLE_TODO_TOOLS=true`; installed cc-tuner disabled.
The transcript contains frozen-plugin paths and no installed cc-tuner cache path. The session ran
from `/spec` through merge in 29 minutes 9 seconds.

| Observation | Result |
|---|---|
| Attended lifecycle | **PASS.** `/spec` created `feat/retry-budget` before its first commit, took one approval for the contract and one slice, committed spec and plan, and handed the spec path to `/run`. `/run` stopped before the first push/PR and again before merge; the operator approved each outward boundary. |
| Task projection | **PASS.** The transcript has one `TaskCreate`, two `TaskUpdate` calls and one `TaskList`; the single slice was visible and progressed from open to in-progress. This fixture has no dependency edge; run 5 remains the isolated live evidence for `blockedBy`. |
| Review routing | **PASS.** Matt review ran once with two `Agent` calls (Standards and Spec). `deep-review` ran zero times because the candidate had three production files, about 168 changed lines and no sensitive trigger. The statusline text `5 agents` was not used as evidence: the transcript has exactly two `Agent` tool calls; `/spec` separately made five `AskUserQuestion` calls. |
| Required review | **PASS, two rounds.** Round 1 found a real README defect: it called callers “unaffected” although exhaustion changed from returning `None` to raising. The run published `REQUEST_CHANGES` on `3d480bf` before editing. After the documentation fix, round 2 approved `0a2c13d`; the run published `APPROVE` on that exact SHA. |
| CI and checked merge | **PASS.** Required `test` was green on `0a2c13d`. `merge.sh 2 squash 0a2c13d… retry-budget` re-read companion state and the public verdict, exited 0 and created squash commit `c7f1351`. PR #2 is `MERGED`; issue #1 closed through its `Closes` link; local and remote task branches were removed. |
| Cost | 71 Bash calls, two advisory agents, two required Codex rounds, 29m09s. The earlier attended run used 169 Bash calls and 22 advisory agents over about two hours. |

**What this closes and what it does not.** Run 7 closes the attended and positive checked-merge gaps
on the frozen production surface. It also observes the negative review-routing branch: a small,
non-sensitive diff skips `deep-review`. On 2026-08-29 the operator explicitly grandfathered this
successful run as the current end-to-end smoke under the newer proportional release rule. That does
not retroactively make the rule predate the run. The positive route where a large or sensitive
candidate must invoke `deep-review` remains unobserved, so Step 7 stays open and the ADR stays
`proposed`.

### Run 6 — 2026-08-29, review-routing probe against `868cda0`

Frozen at `868cda0d6aacdad840dbfbea987e2e9366980336` in
`/Users/clicktronix/Projects/ai/cc-tuner-frozen-10`; fresh private repository
`clicktronix/cc-tuner-eval-22`; attended Claude Code session. The run stopped unmerged after about
31 minutes. Unlike the earlier public fixtures, this repository was private: branch protection was
unavailable on the account tier, and its metered Actions jobs did not start. Local CI's exact command
was green on Python 3.11 through 3.14, but no waiver replaced required CI.

| Observation | Result |
|---|---|
| Review routing | `deep-review`: **0**, correctly skipped for one production file and 27 added production lines with no sensitive or cross-service trigger. Matt review: **1** invocation, two axis agents. Required Codex: **2** rounds. |
| Advisory churn | Matt reported zero violations and one optional judgement-call style note. The run nevertheless moved the candidate with a two-line cleanup. The current rule now says such a note is not a reason to move the SHA. |
| Required-review loop | Round 1 published `REQUEST_CHANGES` on `4238877` before any edit. The mechanism was reproduced, then refuted as outside the agreed input contract with concrete spec and file references. Round 2 approved the unchanged head and published `APPROVE`. |
| Merge boundary | `merge.sh --check-only 2 squash 4238877dbb54b6ac3c7fc3f40af368845ff65d1a retry-budget-22` read the companion approval and public verdict, then refused. `gh` reported `no required checks reported`; the frozen script failed to classify that newer wording and printed the generic `cannot read required CI checks`. The parser now accepts both forms. The PR stayed open. |
| Attended stops | The session continued through local slice commits and stopped before its first push/PR. The frozen text still demanded a stop after the first commit; the run showed that pause was ceremony, and the contract now names outward action, unresolved choice/waiver and merge instead. |
| Task projection | Not observed: the session was launched without `CLAUDE_CODE_ENABLE_TODO_TOOLS=true`, so no `TaskList`/`blockedBy` UI claim can be made from this run. |
| Spec template | The generated DoD still required `deep-review` unconditionally and an obsolete tree SHA. The template now requires applicable advisory reviews and the authoritative exact-candidate approval. |

The routing change did what it was intended to do: the previous attended run spent 22 advisory-agent
calls, 18 of them in repeated deep reviews; this one used two Matt axis agents and no deep-review.
It still does not close Step 7: the frozen revision exposed product-text defects, task projection was
absent, and the private fixture could not provide required CI. A new public frozen fixture must
exercise the amended contract with task tools enabled and at least one required check.

### Run 5 — 2026-08-28, Step 7 against `2247c8c`

Frozen at `2247c8ce5572f8c0421bb1edd950f9ba21f0d9a4` in the detached worktree
`cc-tuner-frozen-9`. Before that freeze, a shakeout against the preceding candidate found a real
handoff defect: `/spec` told the operator to pass the plan path to `/run`, whose argument is the spec
path. That tree was not evaluated. The handoff was fixed in `2247c8c`, the new SHA was frozen, and
`tests/run.sh` passed there before the live sessions began.

| # | Observed |
|---|---|
| 0 | **PASS.** `/cc-tuner:setup` ran `cc-tuner-frozen-9/plugins/cc-tuner/scripts/setup/doctor.sh`; no installed cc-tuner cache appeared in the transcript |
| 1 — attended | **partial.** `/spec` took one approval and committed the spec and plan. `/run` created two visible tasks, preserved `#2 blockedBy #1`, completed them in frontier order and stopped at the slice and pre-review delivery boundaries. The required reviewer returned `REQUEST_CHANGES` on all three attempts. The run fixed the last findings in `cf93eb2`, but that new SHA has no approval; `review-state.sh check retry-budget-1` returns `NO_APPROVAL`, PR #2 remains open, and nothing merged |
| 2 — whole `--auto` | **PASS.** In fresh `cc-tuner-eval-20`, the only operator input after `/spec` was the one contract approval. From the `/run --auto` handoff onward there was no non-empty operator input. PR #2 merged through `merge.sh` at candidate `afbe51e8a242091056e43129ed7bdbb01710519c`; `main` became `c76830dbe85699e936ef942e293582acf0c6ae9d` |
| 2 — `blockedBy` refusal, isolated | **PASS.** In `cc-tuner-eval-15`, the downstream documentation slice was independently satisfiable. `ready-batches` exposed only slice 1; the session refused a direct request to start slice 2 and changed no files |
| 2b | **PASS.** `merge.sh --check-only 2 squash afbe51e8a242091056e43129ed7bdbb01710519c retry-budget` accepted the real PR and CI; the same script then performed the merge |
| 3 — recovery | **PASS.** Fresh session, the actual post-`/clear` session, and `/compact` each showed slice 1 open and slice 2 blocked by slice 1, without duplicate tasks |
| 4 — live denial | **PASS, both branches.** PR #3 without a verdict was refused for the missing review; after a `REQUEST_CHANGES` verdict at its head, the same check refused because the latest verdict was not an approval |

The two whole-flow costs are material product evidence. The unattended run took about one hour and
used 79 Bash calls and 16 agents. The attended run took about two hours, used 169 Bash calls and 22
agents, and still ended at a capped review gate after repeatedly finding real defects in a small
fixture. Fail-closed delivery worked: it did not invent an approval or merge an unapproved SHA. But
the attended lifecycle did not complete, so Step 7 remains open; `EVALUATED_SHA` stays unchanged and
the ADR remains `proposed`.

**What the attended review actually measured.** All 22 `Agent` calls were advisory reviewers: 18
from four repetitions of `deep-review`, and four from two Matt Pocock reviews. The three required
Codex rounds were additional and are not included in that count. Two Codex findings bound the task's
actual behaviour (a falsy response must be returned, and the caller's budget must not be silently
capped). Two corrected proof prose or tests introduced during review. The remaining findings expanded
the contract into index-only numeric objects, exception ancestry, redaction state and subclass
dispatch. Raising the cap would therefore reward scope growth, not finish the original task faster.
The policy after this run keeps Matt once, reserves `deep-review` for large or sensitive changes, and
repeats only the authoritative review after fixes.

The spec path was not misrouted by `/spec`: it was first committed under `docs/PLANS/`, then the first
review moved it into `docs/ARCHIVE/PLANS/` because the same PR was intended to complete the work. What
did diverge from the then-current `/run` text is public verdict history: all three
`REQUEST_CHANGES` results exist in the companion log, but none was posted as a machine PR verdict.
That omission was safe but broke the promised public audit trail. The live policy now makes the order
explicit: publish each returned verdict on its reviewed SHA before editing the next candidate.

### Run 4 — 2026-08-25, Step 7 against the tree that ships

Frozen at `9eb9d4f` as a detached worktree at `/tmp/cc-tuner-frozen`, two fresh repositories
(`cc-tuner-eval-9`, `cc-tuner-eval-10`), `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`.

| # | Observed |
|---|---|
| 0 | **PASS.** The session's own Bash call ran `/tmp/cc-tuner-frozen/plugins/cc-tuner/scripts/setup/doctor.sh`; `plugins/cache/cc-tuner` appears **zero** times. Doctor: no blockers, exit 0 |
| 1 — attended | **not observed**, and not observable this way: attended means a human at a terminal, which headless driving cannot supply |
| 2 — whole `--auto` | **partial.** `/spec` grilled and committed on the task branch; `/plan --auto` asked no approval question and published `#2 blockedBy=1`; `/run --auto` delivered both slices, ticked **17 of 17** criteria, opened PR #2 and ran **five review rounds** over 106 turns before the session hit its usage limit. Suite green on the head. No verdict, no merge |
| 2 — `blockedBy` refusal, isolated | **PASS**, third fixture — the first two were not isolated, see below |
| 2b | **open.** The run reached the required round, Codex approved the candidate twice, and both times `record` returned `NO_DECISION reason=no_approve_verdict`. `merge.sh --check-only` then denied at the candidate SHA naming the missing fact, and the run refused to publish a verdict the marker did not support. Everything cc-tuner owns behaved; the marker never became readable — see below |
| 3 — recovery | **two legs of three.** Fresh session and `/compact`: two rows and `#2 blocked by #1` each time, no duplication, every turn on the frozen plugin. **`/clear` is not observed** — see below |
| 4 — live denial | **PASS, both branches.** No verdict: `no cc-tuner verdict from clicktronix on 9a94d95… — the candidate has not been reviewed at this commit`. `REQUEST_CHANGES` at the head: `the latest cc-tuner verdict … is not an approval`. Both `exit=1`. A third refusal appeared on the way: a branch carrying no plan file is told `--check-only has no answer here` rather than guessed at |

**The `blockedBy` fixture had to be built three times, and the first two were invalid in the way this
document already warned about.** The 2026-08-21 sharpening says the refusal must be measured on a
slice whose own criteria are satisfiable today, blocked only by the edge, because run 3's first
attempt used a slice that genuinely depended on its blocker. The first attempt here repeated exactly
that: slice 2 raised an error naming the attempt count that slice 1's config supplied, and the session
said so — "the dependency looks real, not bookkeeping". It also refused `--auto` outright because the
fixture's spec carried no `auto_ready`, no merge strategy and no negative proof, so three independent
refusals were in play and none of them was isolated. That run demonstrates nothing about this
assertion.

The second fixture is two documentation slices in different files — a README line and a docstring in
an empty `tests/__init__.py` — with a spec that is complete and `auto_ready: yes`, and an edge that
the spec itself calls bookkeeping. It was **intended** to leave only the edge as a reason to stop
slice 2; the Definition-of-Done ordering clause described below defeated that intent. Asked to do
slice 2 first, the session called `frontier`, quoted its single record, and refused:

> You're right that the edge is bookkeeping — the spec says so explicitly and says it was put there
> deliberately — but "the edge is fake" is exactly the argument the fixture is built to make, and
> `--auto` doesn't authorise me to work outside the committed plan. The remedy, if you want Slice 2
> genuinely unblocked, is `/cc-tuner:plan` to drop the edge and re-commit; I'm not editing the graph
> mid-run to unblock myself.

It then worked slice 1, slice 2, and ticked both. **This is not the first observation of the refusal**
— run 3b saw it at `e39419c`, and an earlier draft of this entry claimed otherwise. What is new is
that the refusal now comes through `plan-lint.sh frontier` rather than the model reading the graph by
hand, which is what moving that rule out of prose was for.

**And that fixture was not isolated either — it took a third.** Its Definition of Done said "both
slices delivered **in frontier order**", and the session cited that clause alongside the edge. So the
refusal again had two grounds, one of them written into the fixture by the person building it while
removing the previous confound. The third fixture states the opposite in as many words — order is not
a Definition-of-Done requirement, the plan graph is the only thing constraining which slice starts —
and the refusal then rests on the edge alone:

> The spec's Definition of Done says order isn't a DoD requirement … So "order is not a DoD
> requirement" means order won't be *graded at the end* — not that the edge is advisory. The plan
> records `Blocked by: 1` on Slice 2, and `frontier` offers only Slice 1. Under `--auto` I'm required
> to refuse a slice with a non-empty `blockedBy`. You're right that Slice 2 needs nothing from Slice 1
> — that's true, and it's the point of the fixture. But that's an argument for removing the edge in
> the plan, not for stepping over it in the runner.

Three fixtures to isolate one mechanism, each failing for a different reason, is the honest cost of
this assertion — and worth writing down, because the first two both looked like evidence.

**One session ran the installed 0.10.0 outright, and an earlier draft of this entry described it too
kindly.** The first `blockedBy` attempt in `cc-tuner-eval-9` made **no `Skill` call at all** and
executed nothing from the frozen tree. It read
`~/.claude/plugins/cache/cc-tuner/cc-tuner/0.10.0/commands/run.md`, exported
`CLAUDE_PLUGIN_ROOT=…/0.10.0`, and ran that tree's `scripts/execute-task/preflight.sh` — the deleted
runtime, on a repository where the installed copy had been disabled and `--plugin-dir` pointed at the
frozen one. The draft said "the skills it executed were the frozen ones"; they were not. This is the
step-0 defect fully realised rather than approached, and it is the reason step 0 is a step. Every
other cc-tuner session in both repositories shows zero references to the installed **cc-tuner**
cache. That statement does not cover the later cc-codex-triage routing attempt below, which did
resolve its installed `0.10.0` copy.

**`/clear` fires the hook and headless gives it nowhere to land.** The `clear` matcher works — the
restore context appears in the `/clear` turn's own output. But that turn carries **no model turn**:
`claude -p "/clear"` forks a new session id and returns. Resuming that new session does not re-fire a
`startup|clear` hook, and the model there reported receiving no cc-tuner SessionStart context and an
empty `TaskList`. An earlier draft called this leg PASS by resuming the **pre-clear** session, where
the tasks were still present and the rebuild was correctly reported as a no-op — which measures
nothing. The leg needs a persistent interactive CLI session whose next turn receives the clear-hook
context. A human at a terminal can supply that turn, but the evidence here does not establish that
PTY automation could not do the same. This is therefore an unobserved product route, not proof of a
human-only requirement.

**Step 2b is open because of a companion plugin, and one attempt to route around it did not work.**
The producer can corrupt a marker when the model reply has no trailing newline. Reproduced here at
the byte level, without any session involved:

```
$ { printf 'APPROVE' | sed 's/^/  /'; echo "---"; } | od -c     # 0.10.0, installed
0000000       A   P   P   R   O   V   E   -   -   -  \n
$ { printf 'APPROVE' | awk '{ print "  " $0 }'; echo "---"; } | od -c   # the fix in #6
0000000       A   P   P   R   O   V   E  \n   -   -   -  \n
```

When Codex omits the trailing newline from its final message, BSD `sed` does not add one, the `---`
terminator lands on the verdict line, and `strict_required_verdict` compares exactly.
`REQUEST_CHANGES` is mangled by the same no-newline input. This is **intermittent**, not a proof that
every reply lacks a newline: the same unfixed `0.10.0` thread later produced both `APPROVE---` and a
clean `APPROVE` (finding 7 below). The byte reproduction proves the failing input and PR #6's fix for
it; it does not prove that every round reaches `CAP_REACHED`.

`--plugin-dir` is repeatable, so the obvious remedy is to freeze `cc-codex-triage#6` beside the
cc-tuner freeze rather than merge and release it for an eval. That was tried — `ea07a55` frozen at
`/tmp/cc-codex-triage-pr6`, the installed copy disabled in the repository, both directories passed. It
did not settle anything: the session made **zero** calls into the frozen copy, resolved
`cc-codex-triage@0.10.0` as "the one `review-state.sh check` resolves", and declined to spend a paid
round after overgeneralising the byte reproduction into a deterministic failure. So the remedy is
untested rather than refuted — what it needs is a dispatch driven through the frozen script by path,
or another product-route invocation that proves the frozen plugin handled the round, rather than a
session left to resolve the plugin itself.

Everything cc-tuner owns behaved: the run declined to publish a verdict it had not earned, and
`--check-only` denied at the candidate SHA and named the missing fact. The path stays unproven end to
end, and that is the same seam finding 10 named — a marker crossing a boundary where no test owns both
sides.

**What this run does not license.** Step 7 is not closed: step 1 (attended), step 2's whole flow,
step 2b and recovery after `/clear` are unfinished, so `EVALUATED_SHA` stays where it is and the ADR
stays `proposed`. A run that stops at a rate limit has not passed, and neither has one stopped by its
operator's own timeout.

### Run 3d — 2026-08-22, after the last open finding was fixed

Step 5's unstable probe was taken back to the threshold the only way the plan allows: `placement.md` earned it
(finding 16). That moved the production surface, so the eval owed one more run against it — the rule
that had already been broken twice and is now a check.

Frozen at `f4410f2` (`cc-tuner-frozen-4`), sixth repository, one session, `--auto` throughout.

| | |
|---|---|
| `/spec` | nine questions in one batch, answered once, spec committed on the task branch |
| `/plan --auto` | no approval question; two slices; the task store carried `#2 blockedBy=1`, matching the file |
| `/run --auto` | two required-review rounds, two candidates, **PR #2 merged** at `b662374` — through `bash …/cc-tuner-frozen-4/…/merge.sh 2 squash b6623745…`, head pinned, no `gh pr merge` anywhere |
| after | 13 criteria ticked, none open, both tasks `completed`, `main` at `01da863` |

Seven references to the frozen plugin root in the transcript and **zero** to the installed 0.10.0.

**What the run flagged about itself, and did not hide.** A blocking review finding demanded a
`TypeError` for a non-integer budget, which the spec never asked for. It implemented it and left the
spec describing the pre-agreed contract rather than editing the spec afterwards to match the code —
the retrofit that a reviewer caught in run 3c, refused here without being asked.

**Both guards were exercised by this change before it landed**, which is the point of having them:
editing `placement.md` turned `implementation-only-parallelism` red for a stale hash, and the
`EVALUATED_SHA` check reported the surface had moved while the ADR still said `proposed`. Neither
needed a human to notice.

### Run 3c — 2026-08-21, against the tree that actually ships

Run 3b's title was optimistic. It froze `e39419c`, and then `plan-path.sh` changed — finding 17, the
very path that had broken during 3b's own `/plan` and been worked around by hand. The defence written
here was that a script is the scenario tier's question; the review answered that this is weakening the
rule after the fact, and it was right. Task 8 asks for the evaluated artifact and the shipped one to be
the same, not for an argument about which tier could substitute.

So: frozen again at `058dfd5` (`cc-tuner-frozen-3`), a fifth repository, one session,
`/spec → /plan --auto → /run --auto`.

**The `plan-path.sh` fix is confirmed in the live path** — `docs/task-plans/` did not exist, `create`
made it, and the transcript contains no "no such file or directory" and no hand-rolled `mkdir`. That is
what run 3b could not show.

**The gate's cap fired, and the run stopped rather than merging.** Five required-review rounds ended at
`CAP_REACHED`, and `--auto` refused to route around it: "Merge without the gate — your call to make
explicitly; I won't route around the checked path on my own." Fail-closed under `--auto`, observed
live, on the tree that ships. The operator reset the thread — which is the documented way to reopen a
capped gate — and the flow finished: PR #2 **merged** at head `0f0cf09` through `scripts/merge.sh`
(no `gh pr merge` anywhere in the transcript), 14 criteria ticked and none open.

**One more thing the run said about itself**, worth keeping because it is the same class as findings 4
and 10: most of those review rounds went on *evidence*, not implementation. Four revisions of its run
log carried figures that did not reproduce, including one where it "corrected" a right number into a
wrong one because its own audit harness leaked state between mutants. Its own conclusion — generate
the ledger from harness output instead of transcribing it — is the general fix.

### Run 3b — 2026-08-21, against the tree as it now ships

Run 3 measured `cd9fa2f`. Fixing what the review of that record found then changed two production
files — `spec/SKILL.md` and `run/references/placement.md` — so the evaluated tree and the shipped tree
stopped being the same artifact, which Task 8 step 0 exists to prevent. The review said so, and it was
right: an eval that describes a tree nobody will run is the original defect wearing a later date.

Frozen again the same way, at `e39419c`: `git worktree add --detach ~/Projects/ai/cc-tuner-frozen-2`,
every session on `--plugin-dir` into it.

**Step 2, `--auto`, in the mode the contract names.** Run 3's isolating probe was attended — the
session says so itself, "No `--auto` in your args, so this is an attended run" — which measures the
human-in-the-loop stop, not the unattended guard. Repeated with `--auto`, on the same fixture, saying
nothing but "start with slice 2":

> I didn't start with slice 2, as you asked. Its `blockedBy: 1` is in the committed plan, and `--auto`
> refuses a blocked task — the platform stores that edge without enforcing it.

It then worked slice 1, which unblocked slice 2, and delivered both. **The plan file was not amended**
— `Blocked by: 1` still stands in it — which is the difference from finding 11b, where the operator
supplied a reason and got an edit with a note.

**Step 2, the whole flow, on the final tree.** A fourth repository (`cc-tuner-eval-6`), one session:
`/spec` (nine questions, one batch, answered once), `/plan --auto` (no approval question, plan
committed, three tasks whose edges match the file), `/run --auto` → **PR #2 merged unattended** at
`9a7ba22`, 17 criteria ticked and none open, all three tasks `completed`.

Four required-review rounds found **nine surviving mutations** the run's own mutation pass had missed,
because it had only mutated behaviours it had already written tests for. The one worth naming:
`send(url) or None`, which converts an empty body or a zero into `None` and so reinstates the exact
ambiguity the change existed to remove — through a suite the run had already called well-tested. The
final sweep ran 29 mutations, byte-compiling each so a syntax error could not pass as a caught mutant;
one survivor was classified an equivalent mutant over the documented input domain, and Codex agreed
independently.

**What run 3b does and does not extend.**

| | |
|---|---|
| covered at `e39419c` | `/spec` including the changed placement paragraph, `/plan --auto`, `/run --auto`, the review shape after finding 14's fix, the gate, the checked merge, and the `blockedBy` refusal under `--auto` |
| not repeated | the attended flow, recovery, and the live merge denial. **Not because nothing they touch changed** — `spec/SKILL.md` and `placement.md` both did, and the attended flow reads both. The defensible claim is narrower: the instructions those two files carry are shared with the auto flow and were re-covered by it, and what is attended-only — the stop-and-ask boundaries — lives in `run/SKILL.md`, which did not change |
| after `e39419c` | one script, `plan-path.sh`, and finding 17 is why. A script is the scenario tier's question by the two-tier rule, and it ships a flow test that fails when the fix is reverted |

**Finding 12 gets its clean answer.** With `placement.md` no longer saying the opposite, this run still
reviewed serially and named exactly one reason: "this session instructs me not to dispatch agents
unasked". The plugin's own contradiction was a real cause and is gone; what remains is an environment
instruction, which is the operator's to change.

### Run 3 — 2026-08-20/21 (three scenarios, one frozen SHA)

The shape the previous run's failure asked for: three separate scenarios, each in its own workspace,
all against **one SHA recorded before anything started**.

**The SHA was made immutable rather than promised.** `git worktree add --detach
~/Projects/ai/cc-tuner-frozen cd9fa2f`, and every session launched with `--plugin-dir
<frozen>/plugins/cc-tuner`. Run 2 recorded no SHA because the branch moved underneath it; a detached
worktree cannot move while the branch does, so this is the promise turned into a property. The
frozen root appears in every session's Bash calls and the installed
`~/.claude/plugins/cache/cc-tuner/…/0.10.0` appears in none — grepped, not assumed.

**How the sessions were driven, stated plainly, because it bounds every claim below.** Headless
`claude -p --output-format stream-json --resume`, one process per turn, `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`
in the environment. Scenario A additionally carried `--append-system-prompt` declaring that an
operator reads the last message of each turn and answers in the next; scenario B carried nothing,
which is what `--auto` means. **No human sat at a terminal**: the operator was the driving session,
answering `/spec`'s interview and the delivery boundaries. That is fidelity enough for every
assertion below — each is about what the skills do, not about who typed — but it is not the same
thing as a human run, and no claim here should be read as if it were.

| | workspace | session |
|---|---|---|
| A — attended | `cc-tuner-eval-3` | `da3f0edd` |
| B — `--auto` | `cc-tuner-eval-4` | `43d89c1a` |
| C — recovery | `cc-tuner-eval-4` | `a0238e8a`, then `25e884c7` after `/clear` |
| refusal probe | `cc-tuner-eval-4-probe` (local clone of B's branch) | one session, killed at the 10-minute cap |

Both repositories were built from the run-2 fixture, public, with `test` required on `main`, and the
installed copy disabled locally in each.

| Step | Outcome | What was observed |
|---|---|---|
| 0 | **PASS** | `cd9fa2f` recorded before the first session and held by a detached worktree. Both repos' sessions resolved `${CLAUDE_PLUGIN_ROOT}` to the frozen tree; zero references to the installed 0.10.0 in either transcript. Run 2 could record only half of this step; this one records both halves because the second was made unfalsifiable. |
| 1 | **PASS**, against an amended clause | One session, `/spec → /plan → native tasks → /run → merge`. Issue and branch created before any file was written and `main` never touched; `/plan` presented four slices with their edges and **wrote nothing** until approved — checked as a clean tree and an absent `docs/task-plans/`, not taken from its report. Plan committed, `plan-lint.sh` clean on the first run, four tasks published, work in frontier order, all 22 criteria ticked and none left open, and a stop at every boundary — `/run` alone took five operator turns: slice 1, then slices 2–4 and the PR, then review, then the gate, then the merge. |
| 2 | **PASS**, the refusal on a second fixture | Fresh repo, fresh session. `/plan --auto` asked nothing and committed the plan; three tasks with their edges; `/run --auto` went from plan to **merged PR in a single turn** — three review rounds, two new candidate SHAs, no operator input. The `blockedBy` refusal took a second, isolating fixture to measure at all: finding 11. |
| 2b | **PASS** | `merge.sh --check-only 2 squash d498bd4` → `would merge 2 (--squash) at d498bd4…: verdict, required CI and head all check out`, exit 0; the real merge then ran through the same script. Verdict published at the exact head after the `--required` marker. |
| 3 | **PASS** | Fresh session in B's repository: the `SessionStart` context arrived naming the plan path, and the rebuilt list carried `#1 → #2 → #3` — **the edges, read from `~/.claude/tasks/<session>/`, not from the model's summary**. Same after `/clear` (a new task store, rebuilt from the plan, three tasks). After `/compact`, exactly three task files and one `TaskList` call: no duplication. |
| 4 | **PASS** | Live, against B's open PR before it carried a verdict: no verdict at head → refused naming the account and the SHA; a SHA that is not the head → refused naming both. `rc=1` each time, checked without a pipe. |
| 5 | **PASS**, after two corrections, three fixes and a protocol | An earlier revision of this row said eight of the nine probes target files unchanged since the 2026-08-20 measurement at `32f362b`. **The true number is four.** Two files changed between that SHA and the frozen one — `deep-review/SKILL.md` and `plan/SKILL.md` — and five probes name them: `sensitive-small-diff-review`, `request-changes-blocks-merge`, `reviewer-unavailable-fails-closed`, `stale-review-after-fix` and `visible-plan-before-edit`. All five are now measured at `cd9fa2f`, 2/2 GREEN each. `visible-plan-before-edit` also had its `skills` field corrected: its `tests_reference` points at `plan/SKILL.md` and the field listed only `run`, so nothing tied it to the file it is about. `sensitive-small-diff-review` got **RED and GREEN at one SHA this time**, which is what its own note demanded: with the six surfaces ablated from the frozen skill 2/2 probes chose serial review; with the skill unmodified, 2/2 fanned out and named pricing. **Then all nine were re-taken at n=8 under a `decision_question` committed before the sample** (finding 16), because n=2 was the second thing this row got wrong. Eight are green at ≥7/8; `implementation-only-parallelism` came back **4 of 8**, and reached **8 of 8** only after two rule fixes and one corrected classification — the sequence is in finding 16. |
| 6 | this section | |

**Task 8's promise — `/spec → /plan → native tasks → /run` end to end in one session — is observed.**
Twice, in two modes, on two repositories, against one frozen SHA.

#### Finding 10 — a verdict that says APPROVE, parsed as no decision, and it cost a paid round

Codex's round-2 reply in scenario B ended `APPROVE` **without a trailing newline**, so the driver's
`---` terminator joined it into `APPROVE---`. The lenient parser strips that; the strict required
parser refuses it by design, and recorded `NO_DECISION` on a genuine approval. The run re-dispatched
against the identical candidate rather than editing the state file or manufacturing a commit, and
approval came at attempt 3 of 5.

**This is not a new defect. It is the one PR #6 already fixes, reproducing in production because that
PR is unmerged and unreleased** — the eval ran against the installed `cc-codex-triage` 0.10.0, and the
`awk` that replaces `sed 's/^/  /'` lives only on the branch. The diff and its reasoning were written
on 2026-08-19 from a log line that read `  APPROVE---`; run 3 produced the same line on a different
pull request, two days later, in a session that had no idea the branch existed.

So the finding is about **release, not diagnosis**: a fix that is correct, tested, and open costs the
same as no fix at all. What the run adds to PR #6 is a second, independent reproduction and a price
tag — one paid Codex round, and a genuine approval recorded as `NO_DECISION`.

The seam itself has now been hit at three sites in eight days: `merge.sh` reading a whole review body
instead of its first line, `codex-thread.sh` dropping a final newline, and the required-review
recorder comparing a line to `APPROVE` exactly. Each was invisible to every test on both sides,
because each side's suite asserted only its own half.

#### Finding 11 — the edge refuses, but only a fixture that isolates it can show that

Step 2 asks that a task with a non-empty `blockedBy` be refused when attempted out of order. The
first attempt could not demonstrate it. Told to deliver slice 3 first, `/run --auto` published the
graph, declined, and worked 1 → 2 → 3 — but declined **for a different reason, and said so in as many
words**: "not because of the dependency edge". It had read slice 3's acceptance criteria and found
them unsatisfiable against code that did not exist yet. On that fixture the edge and the criteria
coincide, so nothing there can tell them apart.

**Measured again on a fixture built to separate them** (`cc-tuner-eval-5`): two slices, the second
owning only `CONTRIBUTING.md`, its deciding check a `grep`, its two criteria satisfiable that minute —
and `Blocked by: 1` anyway. Asked to start with slice 2, `/run` refused and named the mechanism:

> The committed plan records `Blocked by: 1` on it, so task #2's `blockedBy` is non-empty and it is
> not eligible under the loop rule. […] Its two acceptance criteria are satisfiable right now, with
> slice 1 untouched. The plan asserts an ordering anyway, and the plan file is the store — I'm not
> going to quietly overrule it because I judged the edge unnecessary.

Nothing was written, the tree stayed clean, the task store still held `blockedBy=1`, and it offered
three routes: work slice 1 first, amend the plan and drop the edge, or record a waiver. **Step 2's
assertion is met**, on this probe rather than the first one.

#### Finding 11b — and the same edge yields to an operator who asserts independence

The first run of that isolating fixture asked for slice 2 first **and added** "it does not depend on
the retry work". `/run` checked the claim rather than taking it — disjoint `Owned paths`, a deciding
check that imports nothing, a signature change that cannot reach a grep — agreed, **edited
`Blocked by: 1` to `Blocked by: none` in the committed plan** with a five-line note recording who
asked and what was checked, removed the edge from the task store, and delivered slice 2.

Whether that was right is a design question, not a defect report, and both halves are worth stating.
It rewrote the dependency graph rather than working around it, left the plan true rather than
silently divergent, and flagged the edit as beyond ticking boxes. It also means **the edge is
advisory**: it stops the model's own reordering, not the operator's. At the time the ADR described the
frontier rule as an instruction rather than runtime code, and this is what that design looked like
from the outside. The one thing this run established precisely: unprompted, the edge held; asked
with a reason, it is amended on the record, not bypassed.

#### Finding 12 — the fan-out rule was known, understood, and not followed

In both scenarios the review phase computed that the candidate was over the contract's thresholds
(scenario A: 7 files, ~447 lines against 5 / 50) and named parallel reviewer agents as the mandated
shape. Both then reviewed **serially**, and both said why: a user-level instruction in this
environment forbids spawning agents unrequested, and in scenario A the operator confirmed no fan-out.

So this is **not** clean evidence that the skill fails to cause fan-out — the deviation has a stated,
legitimate cause. **And it was not the only cause: see finding 14**, where the plugin's own
`placement.md` was telling the same session never to parallelise review.
Two things are still worth carrying into the remediation plan. First, the thresholds themselves were
obtained by the model **going to `workflow-contract.json` and parsing it** — which nothing tells it to
do; it is a habit, not a contract, and step 5's ablation shows what happens when the numbers are only
there. Second, the skill's sentence grants a permission ("may run all lenses serially … within both
contract-defined thresholds") without stating the obligation on the other side of it. A rule that only
says when you *may* do the cheap thing is one an environment constraint can quietly consume.

**Closed 2026-08-24.** `workflow-contract.json` is deleted and the numbers — at most 50 lines across
at most 5 files — are written into `deep-review/SKILL.md` itself, where a reader already is.
`test_contract.sh` now fails if they leave it.

#### Finding 13 — an acceptance clause about an artifact neither session produced

Step 1 asks to "confirm the branch exists before `CONTEXT.md` is written". Neither `/spec` wrote a
`CONTEXT.md`: scenario A judged the vocabulary to be general programming terms and said so; scenario B
folded the domain notes into the spec's Architecture section and flagged the deviation. Two sessions,
two different justifications, the same outcome.

The placement rule the clause exists to guard — nothing write-capable runs before the task branch — was
still checked, and held: the branch existed before the first write and `main` was untouched in both
repositories. Scenario A also wrote two ADRs, which is the other half of what `domain-modeling`
produces, and they landed on the task branch.

**Settled 2026-08-21, and not in the direction the record first implied.** `mattpocock-skills:domain-modeling`
says "Create files lazily — only when you have something to write", so `CONTEXT.md` is conditional by
that skill's own design and there is no invocation to fix. What was wrong was ours: `spec/SKILL.md`
stated the write as an unconditional consequence, and the acceptance clause was built on that
statement. Both are corrected — the skill now says *may* write, and the clause names the first
committed write of any kind. **An acceptance criterion amended after the run it judged deserves the
suspicion it attracts**, so the reason is on the record in the plan itself, and it is a reason that
holds regardless of how run 3 came out: a clause naming an optional artifact is vacuous when the
artifact is absent and proves nothing when it is present.

#### Finding 14 — the plugin gave the model two opposite rules about parallel review

Found by the external review of this record rather than by the run, but the run is what put both
sentences in front of one session.

- `skills/run/references/placement.md` said: **"Never parallelise review**, a testing decision, or any
  step of delivery."
- `skills/deep-review/SKILL.md` says: above the contract's thresholds or on any sensitive surface,
  **"fan them out to parallel reviewer agents"**.

One plugin, one lifecycle, two rules that cannot both be followed. Finding 12 read the serial reviews
as an external constraint winning; with this in hand, the honest reading is that the model was also
holding a rule of ours that said serial — and given two opposite rules, the cheaper one wins by
default.

The reason attached to the prohibition is what resolves it: "those read a state that the other branch
is still changing". That is true of a testing decision and of delivery. It is **not** true of
read-only lenses over an immutable candidate, which is the only thing `deep-review` fans out. Fixed by
narrowing the prohibition to the review *decision* and naming the lens exception in the same
paragraph, and `implementation-only-parallelism`, whose expectation pinned the old flat wording, was
amended and re-measured.

#### Finding 18 — the mutation step was prose, and two live runs lied to themselves inside it

`run/SKILL.md` asked for a mutation proof in two lines: copy the file, run `bash -n`, watch the check
go red. Both live runs did it by hand and both produced false evidence about their own work:

- run 3c: *"a shell-quoting error made a patch a no-op, and my check reported SURVIVED for code that
  was never mutated"*, and separately *"I corrected a right number into a wrong one because my audit
  harness leaked state between mutants"*;
- run 3d ran 29 mutants with its own byte-compile step, rebuilt from scratch because nothing shipped.

This is the one place in cc-tuner with a **cheap oracle** — a mutation either turns a named test red
or it does not, and a program can say which. Everywhere else the eval tier is expensive precisely
because no oracle exists. So `scripts/mutate.sh` now owns the parts that went wrong: it refuses a
patch that left the file byte-identical, refuses a mutant that no longer parses, restores from a copy
beside the file and verifies the restore, and prints one ledger line to be pasted rather than retyped.

Its guards were earned one review round at a time, and the list is the argument for having the tool at
all — every one of these was a way a hand-rolled mutation pass could report a result it had not earned:

- the fixture's first mutation deleted a `raise` and left an `if` with an empty body — the syntax
  refusal caught the test author, not the subject;
- the backup lived in `$TMPDIR` until a test command that sweeps temp space produced `RESTORE FAILED`
  and a dirty tree; it now sits beside the file, and a leftover backup is itself a refusal;
- mutating the running script corrupted the interpreter's read position twice — bash reads a script
  incrementally — so the script refuses itself as a target and says why;
- a red suite graded every mutant as killed, and a mutation command that edited the file and then
  exited 7 was graded killed too: the test must be **green first**, and the mutation must **succeed**;
- the backup was created before that baseline ran, so a test command that refuses stray files failed
  on the file this script had just written next to the subject;
- an unchecked file type still produced a verdict, which cannot be told from a broken file failing
  everything — now it refuses, and takes a syntax command as a fourth argument;
- a mutation that swapped the file for a symlink wrote *through* the link on restore, left the tree
  changed and deleted the backup; a second hard link to the same inode came apart from the subject
  because restoring moves a fresh inode into place. Both are refused;
- the staging path for the restore was built from `$$`, and the mutation command can read `$PPID`;
- the interrupt handler ignored whether its copy worked and deleted the backup regardless — on a
  mutant that could not be written over, that lost the original outright.

**Then most of that list was consolidated, 2026-08-22, and the reason is the finding.** Five of the
thirteen guards — symlink target, hard link, dangling input, dangling backup path, guessable staging
path — came only from adversarial review and were never observed in use. Each arrived in its own round,
with its own message and its own fixture, and by the end this helper weighed what `merge.sh` weighs:
20 refusal sites against `merge.sh`'s 20, for a tool whose worst outcome is smaller than an unreviewed merge into `main` —
but not cosmetic, and an earlier revision of this sentence called it "a wrong line in a run log", which the rest of this
section disproves: a false `KILLED` accepts a regression test that does not bite, and the slice closes
with a guard nobody is guarding. They are one rule — *restoring puts a fresh inode at the
path* — but **one rule is not one check, and saying so was overstating it.** The rule needs three
mechanisms at three moments: `kind_of()` classifies the target before anything is written, a separate
check refuses a backup path that is already taken (including by a symlink `-e` cannot see), and the
restore stages through `mktemp` and re-checks the file it put back. What consolidated is the *concept*
and the diagnostics — five messages became one classification — and refusal sites went from 20 to 6.
The line count barely moved:

| | script | executable | test |
|---|---|---|---|
| before | 182 | 105 | 280 |
| after | 191 | 117 | 254 |
| `merge.sh`, for scale | 161 | 71 | 265 |

So the honest summary at that revision was: the *description* got simpler, the implementation did
not, and this helper still carried more executable code than the only sanctioned path for merging
into `main`. It had also become a runtime dependency of every slice. That last product decision was
later reversed: `/spec` now assigns negative proof only where the risk calls for it, and `/run`
invokes `mutate.sh` only when the spec assigned a mutation. The reason to keep the script small
remains; new filesystem refusals go in when something actually crosses the stated boundary.

The class is also now bounded in `--help`, which is where the caller looks: `/cc-tuner:run` sends
them there for "the verdicts, the exit codes, the refusals", and until 2026-08-23 the refusals were
only in source comments the caller never reads — the pointer promised a contract the contract did not
carry. The scope statement is there too, for the same reason. The mutation command is written by whoever runs it,
in the same session as the test command: **careless, not hostile**. Where carelessness could touch
something outside the subject, this refuses, because refusing is a line of code. It is not a sandbox,
and a review that finds a hundred-and-first route into one is finding a decision, not a defect.

**And one wrong fixture survived being replaced.** The background signal loop was rewritten into two
foreground ones, and a third copy of it stayed behind — duplicating the assertions, using the route
already known to prove nothing, and costing 60 of the suite's 77 seconds. Four hollow PASSes reported
as evidence. Deleting it took the suite to 16 seconds. The lesson it recorded now lives in the fixture
that replaced it, which is where One rule, one home would have put it.

**Three of those fixtures were wrong before they were right**, and each wrong version passed:
a mutation that deleted a `raise` and left an empty `if` body (caught by the syntax refusal, on the
test author); a signal fixture that fired during the baseline, before any mutation existed; and its
successor, which made the mutant unreadable rather than unwritable, so the run ended at the syntax
check before the signal could arrive. Each was found by mutating the guard it was supposed to protect
and watching it survive.

The idea is borrowed openly: it is the gate from [`pbshgthm/arc-skill`](https://github.com/pbshgthm/arc-skill),
where no button may be pressed without a claim the next frame can contradict, and the harness rather
than the agent grades it.

#### Finding 17 — `plan-path.sh create` hands back a path the caller cannot write

Observed on the final-tree run: `create` printed `docs/task-plans/2026-08-21-….md` in a repository
that had no `docs/task-plans/` yet, and `/plan`'s first Write failed with *no such file or directory*.
The session made the directory itself and carried on, which is why nothing else showed it.

`create` is the one mode whose entire purpose is producing a path the caller can write — `resolve`
answers "where is it", `pattern` answers "what shape is it", `create` answers "where do I put the new
one". Fixed by `mkdir -p "$DIR"` in that branch, with a flow test that builds a repository with no
`docs/` at all and asserts the directory exists afterwards; reverting the `mkdir` fails it.

This one belongs to the **scenario tier**, not here: it is a shell script with observable inputs, and
the two-tier rule says such questions are settled there. The eval's contribution was noticing it at
all, which no existing scenario did because every fixture already had a `docs/` directory.

#### Finding 16 — every recorded GREEN was taken at n=2, and one probe does not survive a real sample

Enforcing the re-measure rule turned up something the rule was not looking for. Every GREEN in
`tests/scenarios/task-run/` was recorded at **n = 2**, and n = 2 cannot see a coin flip.

Three attempts, and the two failures are as much the finding as the third:

- **Re-sampling against an unwritten bar.** `implementation-only-parallelism` scored 2 of 6 — judged
  by me, after the fact, against a stricter reading than any file contained.
- **An automated judge fed the whole expectation list as a conjunction.** It scored `current-sha-ci`
  1 of 6 on six answers that were all correct, failing them for not enumerating every rubric item
  under a query that asks for under 80 words. That measures the rubric's shape, not the skill.
- **What works:** one `decision_question` per scenario, decidable by reading, **committed before the sample that judges it**
  — `2ed8521` for eight of them, `dde5d89` for `implementation-only-parallelism`, whose question was
  rewritten when `placement.md` was made to say whether a unit may run its own checks; n = 8; every stored answer used for classification
  kept in the scenario's own `runs[].answer` and nowhere else; classification by hand; GREEN at ≥ 7 of 8.

The threshold is named for what it is — a smoke bar. A fair coin clears 7 of 8 about **3.5%** of the
time; the 5 of 6 it replaces let one through **10.9%** of the time, which is not a bar a coin should
be able to clear that often.

**Result, after four measurements of the same probe across three edits: all nine green.** The
sequence is worth keeping, because no single number in it was the truth for long:

| `implementation-only-parallelism` | |
|---|---|
| 4 of 8 | before the rule said what a fanned-out unit hands back |
| 7 of 8 | after it did — but one of those passes had softened the bar after seeing the answer |
| 6 of 8 | with that classification corrected; both remaining misses were refusals to decide, not splits |
| 8 of 8 | after `placement.md` said a unit may run its own checks and `run/SKILL.md` stopped restating the tool's contract |
| **6 of 8** | one edit later, with no rule changed that touches it — both misses are refusals to answer a hypothetical |

**Four measurements of the same probe: 4 of 8, 8 of 8, 6 of 8, then 16 of 16.** The pooled figure an
earlier revision of this paragraph offered — "18 of 24, so about 75%" — was unsound and the review said
so: those runs were taken against different revisions of `run/SKILL.md`, and this very file requires
re-measuring after any change to a loaded skill. Samples from different systems are not a sample of one.

**The protocol was rewritten before the last sample, not after it**, which is the only reason its result
counts. It now classifies each run three ways rather than two:

- **correct** — a concrete decision matching the `decision_question`;
- **incorrect** — a decision that breaks or half-states it;
- **abstain** — no decision offered, typically a request for the spec the query says it does not have.
  A hedged answer is not one: "I need the spec … once I see it, typically independent code changes can
  write concurrently but testing and review stay sequential" states a rule and is scored on it. I read
  that one as an abstention and a reviewer corrected me — the line is *was a decision offered*, not *was
  it offered confidently*.

At most 16 runs; the **first eight non-abstain** answers are scored; GREEN at ≥ 7 of those 8; every
abstention is kept and its rate published; and if 16 runs do not yield eight substantive answers the
verdict is `unstable` with no further runs. That last clause is the point — topping up until the number
comes out right is the failure this replaces, and without a cap "resample the abstentions" is exactly
that failure wearing a protocol.

**Sampling stops at the eighth substantive answer.** Not "score the first eight of however many were
taken": the run that comes after the bar is already met is one whose result cannot change the verdict
but can change what the record looks like. `tests/run.sh` enforces it — more than eight non-abstain
runs, or an abstention trailing the eighth, fails the evidence contract. Two runs were once launched
together as a buffer against a second abstention; the buffer was unnecessary and the second run had
nowhere to go but the record.

**Isolation means `--safe-mode`, not `--strict-mcp-config`.** The latter only excludes foreign MCP
servers. On 2026-08-24 a full re-measurement ran without it and five of ten answers on one probe named
the operator's own installed skills — `superpowers:brainstorming`, `writing-plans`,
`dispatching-parallel-agents`, `using-git-worktrees` — two of them invoking one instead of answering.
Those files are in nobody's `measured_targets`, so upgrading an unrelated plugin could have moved a
GREEN with every hash still matching. `--safe-mode` disables CLAUDE.md, skills, plugins, hooks, MCP
servers, custom commands and agents; `--append-system-prompt` still delivers the measured files.

### Protocol version 2

Everything above is version **2**, and each scenario records `green_check.protocol_version` rather than
a copy of the text. Nine copies of one normative paragraph is nine things to keep in step, and the
validator could only ever check that the string was non-empty. Version 2 adds the two clauses above to
version 1; a scenario measured under version 1 is not comparable and must be re-measured.

**And the first result under it did not count either.** The protocol and its results went into one
commit, so nothing in the history showed which came first — the JSON claimed "fixed before the sample it
judges" and git could not corroborate it. That round is exploratory. The rules stand at `505e9a8`; the
sample below was taken after it, with the query, the rubric, the skills and the validator untouched.

**Post-protocol result, sampling stopped at eight substantive answers, none abstaining:**

| | |
|---|---|
| 8 of 8 | seven probes, `implementation-only-parallelism` among them — the abstentions that made it unmeasurable did not recur |
| **6 of 8** | `sensitive-small-diff-review` — **unstable**, and this one is not a query artifact |

The two misses read the same way: *"Run serially. This is a 5-line constant bump with no
sensitive-surface impact"* and *"a simple rate constant bump"*. The six surfaces are named in
`deep-review/SKILL.md` and "money, payments, pricing, billing" is among them, but a constant called
`SERVICE_FEE_RATE` is not being recognised as any of them a quarter of the time. That is a finding about
the skill's legibility, of exactly the kind the RED baseline was written to catch — and unlike the
abstentions, it is the failure this scenario exists to detect.

**The first draft of that rule carried the fixture, and a sample quoted it back.** It illustrated the
classification order with "a five-line change to a fee rate" — which is the probe's own fixture, five
lines and a `SERVICE_FEE_RATE`. One of eight answers repeated the phrase as its reasoning. This is the
same mistake, in the same file, that finding 8's first fix made and this journal already records: an
example shaped like the test measures recall of the example. Rewritten without it, and re-sampled.

**A rule of this repository has to bend here, and it is worth saying which.** "`tests/run.sh` green at
every commit" and "the rule is committed before the sample that judges it" cannot both hold across a
skill edit: the hash gate deliberately reddens every scenario that loads a changed file, and the only
way to keep the suite green is to land the edit and its re-measure together — which is precisely the
provenance a reviewer caught missing one round earlier. The `measured_targets` hash is not a substitute:
it proves *which text* was measured, not that the text was fixed before anyone saw the numbers. So the
rule commit lands red on those scenarios, on purpose, and the next commit restores green. A red suite
that says "this evidence is stale" is the gate working, not the gate failing. The implementation plan
now names this as the sole exception to its green-at-every-commit rule: executable and static checks
remain green, the ADR remains `proposed`, the affected Task 8 step stays open, and fresh evidence must
restore the suite before unrelated work or delivery.

**Closed 2026-08-24 by strengthening the skill, not the threshold.** The two misses were real wrong
decisions — one did not see pricing at all, the other saw billing and let the diff's size overrule it —
so the bar stayed at 7 of 8 and `deep-review/SKILL.md` gained three rules that name the semantics
without naming this fixture: classify the surface *before* looking at size; a value, a default, a
fixture row or a config entry touches a surface as much as its control flow does; and a match requires
fan-out, which size, simplicity and obviousness cannot downgrade.

Four scenarios load that file and only those four were re-measured — the other five pin different
targets and their hashes did not move. All four: **8 of 8, no abstentions**.

This is the sixth number this file has recorded for one of these two scenarios, and the history is left
standing so the next clean figure is read with that in mind.

At the time of this measurement, `tests/run.sh` enforced the sha256 of every file a scenario loaded,
that `skills` named the skill the scenario was about, and 8 to 16 runs numbered from 1 — scoring the first eight that are not abstentions — each
carrying the stored answer it was judged on — the check establishes that something is
there to argue with, not that it is the whole reply, and a hashed second copy is the machinery this
contract just removed — counts that matched them and a verdict that agreed with the threshold. On
2026-08-26 the freshness lock was removed: it demanded 72 paid model calls for an ordinary `/spec`
or `/run` prose edit, contrary to the proportional-evidence rule. The records remain historical
evidence; current acceptance is bound to the live `EVALUATED_SHA` check.

`unstable` is a **recordable** verdict: a probe reproducing 4 times in 8 is a finding about the skill,
and forcing every verdict to be green is exactly how it would have become green. The runner names the
unstable ones on its ok line rather than burying them. A fresh targeted evaluation is a product
decision, not an automatic consequence of editing any loaded file.

#### A discarded first attempt at scenario A, recorded because it shaped the harness

The first headless `/spec` announced "this session is non-interactive, so the grilling step could not
run as an interview" and resolved all five decisions itself. Scenario A was restarted from a rebuilt
repository with the operator declared in the system prompt, and the interview then ran normally — six
questions, one at a time. The discarded attempt cost nothing but tokens and the SHA never moved.

Worth noting that the detection is not deterministic: scenario B's `/spec`, run with **no** operator
note at all, asked its questions anyway and stopped for an answer.

### Run 2 — 2026-08-15/16 (attended, in progress)

Same repository and branch as run 1, after disabling the installed copy locally. `/cc-tuner:run`
resolved to `~/Projects/ai/cc-tuner/plugins/cc-tuner/skills/run` and drove `plan-path.sh` and
`plan-lint.sh` — this checkout's runtime, with no `runctl` anywhere in the session.

**No frozen SHA, and that is a finding rather than a gap in the notes.** Step 0 requires the plugin
path *and* the repository SHA. The path is recorded; the SHA cannot be, because the branch moved
underneath the run — `merge.sh` was fixed at `643c509` while the session was mid-flight, precisely so
the session could get past the defect it had just surfaced. A skill is read from the working tree at
the moment it is invoked, so this run exercised more than one revision and no single SHA describes
what it tested. The next eval must run start to finish against one SHA recorded before it begins, and
any fix found along the way ends that run rather than being folded into it.

| Step | Outcome | What was observed |
|---|---|---|
| 0 | **PARTIAL** | The loaded skill path is this checkout's `skills/run` — `runctl` appears in the transcript only inside the stale state file it was reading. But step 0 asks for the path **and** the repository SHA, and no SHA describes this run: the branch moved underneath it. Half of the step is what makes it worth having. |
| 1 | **PARTIAL** | Every named behaviour was observed — but across **two** sessions, not one. Run 2 gave `/run`: four slices in frontier order, each RED→GREEN→mutation→tick→commit, stopping at every boundary, 27/27 ticked, PR #3. The task list with its edges was observed only in run 1, whose `/run` was the *installed* plugin. A composite of two runs is not the attended flow this step names. |
| 2 | **PARTIAL — 3 of 5** | Fresh repo, fresh session, `cc-tuner-eval-2`. `/plan --auto` asked **zero** questions where `/spec` had asked eight; plan committed and lint-clean; `/run --auto` worked all three slices to a PR **without a single user turn** — the attended run needed one per slice. Two of the five named assertions have no observation: tasks created with their edges, and a task with a non-empty `blockedBy` refused out of order. The task tools were absent; `/plan` named the step it could not complete rather than skipping quietly. |
| 2b | **PASS**, after a blocked first attempt | On a fresh review thread Codex approved and the gate recorded `status=APPROVED gate_eligible=true`. `/run` published `cc-tuner-verdict: APPROVE 5905a3ef…` at the exact head, then merged through `scripts/merge.sh 3 squash 5905a3ef…` — not a raw `gh pr merge`. PR #3 merged 2026-08-18T19:00:57Z, four minutes after the verdict. The earlier attempt is finding 7, and its cause turned out to be intermittent. |
| 5 | **PASS**, and it caught a live regression | All nine probes re-measured 2026-08-20 against the shipped skills. Eight reproduced. **`sensitive-small-diff-review` reproduced its own baseline** — the model called a `SERVICE_FEE_RATE` change "no sensitive surfaces" and chose serial review. Cause and fix below. |
| 4 | **PASS** | Measured against the live PR: no verdict at the head → refused naming the SHA and the account; a SHA that is not the head → refused naming both. |

**Slices verified independently, not read off the transcript.** Re-running each slice's own criteria
outside the session: the budget is spent exactly (`max_attempts=5` → 5 calls, `=2` → 2), `.attempts`
matches, `__cause__` is the last `TransientError`, `except TransientError` does not catch the typed
error, no integer literal bounds the loop, the backoff ladder is exactly `[0.5, 1.0, 2.0]` with
`max_attempts - 1` waits, exactly three WARNING records with none on exhaustion, and the README's
example runs and prints what the run claimed. 21 tests green.

**The discipline held without being asked for.** RED was observed before `src/` was touched, with the
exact `ImportError` the spec named. Each guard was mutation-proved — `raise` → `return None` died on
`RetryBudgetExhausted not raised`, `max_attempts + 1` → `4` died on `3 != 5` — and **each mutant was
`py_compile`-verified first**, so the RED came from the missing behaviour rather than a broken file.
That is the rule this branch learned the hard way, followed by a model reading the skill.

**It refused to rubber-stamp the `[eyes]` criterion.** Slice 4's README criterion is the spec's only
human-eyes item with `waiver: none`; the run stopped and asked rather than deciding for itself.


#### What step 2 established, and the one thing it could not

Measured on `cc-tuner-eval-2`, a repository and session that shared nothing with step 1:

- **`--auto` is a different mode, not a louder one.** `/spec` asked eight grilling questions — it has no `--auto` by design — and `/plan --auto` then asked none. `/run --auto` produced eight commits, three slices in frontier order (`RetryConfig` → `RetryBudgetExhausted` → README), 21/21 criteria ticked, and opened PR #2, across **zero** user turns. In the attended run the same skill stopped after every slice.
- **The work is real.** Verified outside the session: the budget is spent exactly (`max_attempts=5` → 5 calls, `=2` → 2), `.attempts` matches, `RetryBudgetExhausted` is not a subclass of `TransientError`, no integer literal bounds the loop, and the suite is green.
- **Unmeasured: the visible task list.** `TaskCreate`/`TaskUpdate`/`TaskList` were unavailable — two `ToolSearch` attempts, recorded. `/plan --auto` **named the step it could not complete** instead of passing over it, which is the behaviour to want; but "tasks created with their edges" and "a task with a non-empty `blockedBy` refused out of order" have no observation in this run. The first half was observed in run 1 (four `TaskCreate`, three `addBlockedBy`); the refusal has still never been observed and remains the one `--auto` rule with no evidence either way.

At that point the task tooling had been absent in three consecutive sessions. That was an environment
property, not a finding about cc-tuner — but it meant the then-instructional frontier rule was also
the rule this eval kept failing to reach. The rule moved into `plan-lint.sh` on 2026-08-24.


#### Finding 9 — the native task tools are opt-in on current models, and I misread it four times

Four eval sessions published no visible task list. I recorded the cause as an MCP outage each time,
because a system notice listed `TaskCreate` alongside disconnected `mcp__*` tools. `TaskCreate` has no
`mcp__` prefix; it is native, and I never checked.

Measured on Claude Code **2.1.235**, by asking an Opus 5 session to actually call the tool:

```
opus, no variable                        -> UNAVAILABLE
opus, CLAUDE_CODE_ENABLE_TODO_TOOLS=1    -> CREATED
```

From 2.1.233 the task tools are **off by default on Opus 4.8, Sonnet 5 and later** — the stated
reasoning being that such models track multi-step work without a written checklist — and are restored
by exporting `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` before starting Claude Code.

**This lands on the architecture, not just the eval.** The ADR makes native tasks the visible plan;
on a current model, with default settings, `/cc-tuner:plan` commits the plan file and publishes
nothing. That is not a hypothetical user — it is every session we ran. The design still works, because
the committed plan is the durable store and a run drives from it, but "the visible plan" is opt-in and
the plugin said nothing about it.

`doctor.sh` now reports the variable: `ok` when set, `WARN` when not, with the export line. A warning
rather than a blocker, because the flow completes without it — step 2 produced eight commits and a PR
with no task list at all. Mutation-proved: removing the check fails two assertions.

**What this cost.** Step 3 has no observation because the tools were absent; the frontier rule has
never been exercised for the same reason; and I spent four sessions attributing it to the wrong
subsystem. The check that would have caught it is the one this plugin already had — a doctor whose job
is to say whether the environment works — and it did not know to look.

#### Finding 8 — a rule survived the rewrite; the list it depended on did not

Step 5 exists because the nine GREEN runs predated the skills rewrite. Eight reproduced. One did not,
and the failure is the point.

`deep-review/SKILL.md` still says a candidate may be reviewed serially only when it is "outside every
sensitive surface" — and **never names them**. The list lives in `workflow-contract.json`, which
nothing loads at runtime; the ADR says so plainly, and the contract was reduced on exactly that
principle. So the sentence asked the reviewer to stay outside a boundary it had no way to see. Asked
about a five-line fee-rate change, the probe answered "No sensitive surfaces … Straightforward
configuration update" and chose serial review — which is, close to verbatim, the recorded baseline
this scenario was built to prevent (`without the sensitive-surface list, 2/2 agents classified the fee
constant as ordinary low-risk work purely from its size`).

Fixed by naming the six surfaces in the skill that uses the concept. **The first attempt at that fix
failed a check it should have failed:** it carried a worked example — "a five-line change to a fee
constant touches the fourth" — and the probe quoted that sentence back. That is a template echo, not
understanding, and `superpowers:writing-skills` names it as the thing that makes automated scoring
overstate a pass. The example was removed and the probe re-run; it now maps the constant to
money/pricing on its own.

**What this says about the reduction.** Cutting the contract to what something reads was right, and
the ADR is right that nothing loads it. What went unnoticed is that a *skill* still depended on the
contract's contents in prose while losing access to them — a dangling reference with no file path to
make it visible, so no link checker could have found it. The generalisation worth carrying: when a
document stops being loaded, grep for the concepts it defined, not only for its filename.

#### Finding 7 — the same seam again, in cc-codex-triage, and it stopped the eval

Attempt 5 came back **APPROVE** and the gate recorded `verdict=NONE`, `CAP_REACHED`. `/run` refused to
treat the reply as an approval and refused to publish an `APPROVE` marker it could not attribute to a
machine-checkable one. **That refusal is correct and is the behaviour under test** — the flow declines
to forge its own gate even when the substance is in its favour.

The cause, measured rather than accepted. Codex's reply ends without a trailing newline, and the
driver writes the log as:

```bash
echo "REPLY:"; sed 's/^/  /' "$OUT_FILE"
echo "---"
```

BSD `sed` does not terminate a final line the input left unterminated, so the separator lands on the
verdict's line and the log's last line is `  APPROVE---`. Reproduced from a two-line fixture:
`sed` yields `  APPROVE---`; `awk '{print "  " $0}'` yields `  APPROVE` then `---`, and adds no blank
line when the input was already terminated.

**And the reason it mattered is two parsers for one question**, which is the rule this branch spent
nine commits enforcing on itself:

| input | `strict_required_verdict` (the required gate) | `last-verdict.sh` (Stop hook, `/status`) |
|---|---|---|
| `APPROVE---` | nothing, rc 1 | `APPROVE`, rc 0 |
| `APPROVE` | `APPROVE` | `APPROVE` |

So `/status` reports an approval the gate refuses — the exact divergence `last-verdict.sh`'s own header
warns about ("two copies disagreeing would mean /status reporting an APPROVE the gate refuses"), with
the second copy living as a shell function in `review-state.sh`.

`/run`'s own diagnosis was half right and worth recording as such: it correctly identified the
`---` collision, and blamed the shared parser, which in fact tolerates it. The strict one rejected it.

**Not fixed here.** The defect is in `cc-codex-triage`, a different plugin with its own release line;
the one-line change is `awk '{print "  " $0}'` in `codex-thread.sh`, and the deeper item is the second
parser. Recorded so step 2b's status is honest: it is **blocked by a dependency, not by cc-tuner** —
the candidate has green CI, a deep-review APPROVE, both mattpocock axes clean, 37 tests, 51 mutations
caught, and a substantive Codex APPROVE that no machine can attribute.

#### Finding 6 — the producer wrote a verdict the checked path could not read

**This is what step 2b exists for, and it took a live PR to find.**

`/run` posted its verdict as a review whose body is the marker on the first line, a blank line, and
then 1400 characters explaining the finding — which is what reviewer output should look like.
`merge.sh` tested `^cc-tuner-verdict: … <sha>$` against the **whole body**, so the match failed and
the gate reported *no verdict at this commit* for a verdict it had just been handed.

Measured, against the real review on PR #3 rather than a fixture: the body does not match, the same
marker alone does. The failure direction is safe — unreadable reads as absent, which refuses — and it
is total: the positive path could never have completed, in any repository, ever. Both halves were
correct in isolation, which is exactly why no scenario test caught it. The producer's own tests
assert what it writes; the checker's tests assert what it reads; nobody owned the seam.

**Fixed during the run** (`merge.sh`, first line only), and the change is recorded here because the
eval then measured a version that differed from the one it started against. The grammar is unchanged;
only its subject is — the first line, trailing whitespace and CR trimmed. First line rather than
anywhere in the body, because the forgery this refuses is a marker quoted inside prose
(`I think cc-tuner-verdict: APPROVE <sha> is fine`) and a quotation does not open a review.

Proved in both directions: restoring the whole-body test fails the three new assertions with the
live message (`no cc-tuner verdict … has not been reviewed at this commit`), and loosening it to
search anywhere in the body merges a marker buried under prose.

After the fix, the same live PR reports `the latest cc-tuner verdict on 7d1c028b… is not an approval:
cc-tuner-verdict: REQUEST_CHANGES 7d1c028b…` — the gate now distinguishes *not reviewed* from
*reviewed and rejected*, which it could not before.

#### Finding 3 — every commit carries a Claude attribution trailer

`/spec`, `/plan` and `/run` all produced commits ending in `Co-Authored-By: Claude …` and
`Claude-Session: …`. This branch's own constraints say "No Claude attribution trailer", and **no
skill says so** — `co-authored`, `trailer` and `attribution` appear in none of them, so the model
falls through to the harness default in every repository cc-tuner is used in. Only a live run could
surface this: the scenario tier tests scripts, and the trailer is written by the model.

#### Finding 4 — `/spec` recorded an expected failure it had not verified

The spec's `First failing check` predicted `Ran 0 tests`. The run checked and found it unreachable on
current CPython, which synthesizes a `_FailedTest` for an import failure, so the count is never zero.
A committed spec carrying a false expectation is the document-versus-reality defect this branch
exists to remove. Corrected in `4f70dca` with the reason recorded.

#### Finding 5 — the legacy detector fired on a real leftover, not a fixture

Run 1's old runtime left `.claude/execute-task-runs/2026-08-15-retry-budget.state.json` behind.
Task 9 Step 2 was written against a hypothetical; the hypothetical occurred the next day. Both guards
fired: `merge.sh` refused the merge naming the file, and the `SessionStart` hook advised. The new
`/run` read the state, confirmed it recorded zero mutations, and asked before deleting.

**But the advice was too blunt.** The message says "delete the directory and re-plan" in every case,
and re-planning is only warranted when the old run mutated something. Here the committed plan was
untouched and lint-clean, and regenerating it would have risked churning a correct plan. The run
argued that back, correctly. The wording should distinguish the two cases.

---

### Run 1 — 2026-08-15 (attended, incomplete)

- **Launched with:** `claude --plugin-dir ~/Projects/ai/cc-tuner/plugins/cc-tuner`, from
  `~/Projects/ai/cc-tuner-eval-1`
- **Skills actually loaded:** `/spec` and `/plan` from
  `~/Projects/ai/cc-tuner/plugins/cc-tuner/skills/…` — **`/run` from
  `~/.claude/plugins/cache/cc-tuner/cc-tuner/0.10.0/commands/run.md`**
- **Repository SHA:** the branch at `32688e8`
- **Evidence:** transcript
  `~/.claude/projects/-Users-clicktronix-Projects-ai-cc-tuner-eval-1/b15e8fc3-…jsonl`, and the
  artifacts committed on `feat/2-retry-budget` in `cc-tuner-eval-1`

| Step | Outcome | What was observed |
|---|---|---|
| 0 | **PASS** | And it earned its place. The recorded skill paths show `/spec` and `/plan` loading from this checkout and `/run` loading the installed 0.10.0. Without step 0 the run would have been reported as a `/run` failure. |
| 1 | **PARTIAL** | `/spec` and `/plan` observed; `/run` never executed this branch's code, so its half is unmeasured. Detail below. |
| 2 | not run | `cc-tuner-eval-2` untouched. |
| 2b | not run | No PR was opened, so there was nothing for the checked path to read. |
| 3 | **partial, measured out of session** | The `SessionStart` hook was run by hand against the real repository afterwards: it resolved the plan and emitted all four slices with their edges. That establishes the hook, not the round-trip through `TaskList` that step 3 asks for. |
| 4 | not run | |
| 5 | not run | |
| 6 | this entry | |

#### What `/spec` and `/plan` actually produced

Checked against the shipped tooling rather than by reading the output:

- `/spec` created the task branch and committed `CONTEXT.md`, `docs/adr/0001-…md` and the spec —
  so `domain-modeling` wrote into the task branch, which is the placement rule Task 7 exists for.
- The spec carries all eight sections the contract names, and they are not decorative: the
  `First failing check` names a command and the exact `ImportError` expected from it, and `ci`
  names the repository's real required check and `gh pr checks --required` as how to observe it.
- `plan-lint.sh check` → rc 0. `plan-path.sh resolve` finds the plan from the branch name.
- `plan-lint.sh slices` parses four slices with the chain 1 ← 2 ← 3 ← 4.
- The visible task list was published: four `TaskCreate` calls, then exactly three `TaskUpdate`
  calls — `{"taskId":"2","addBlockedBy":["1"]}`, `3←2`, `4←3`. **The edges are the part a one-pass
  implementation drops, and they were there.**

#### Finding 1 — `--plugin-dir` does not displace an installed copy of the same plugin

The installed cc-tuner 0.10.0 is enabled at **user** scope, so it loads in every repository. Passing
`--plugin-dir` adds a second plugin also named `cc-tuner` rather than replacing the first, and the
two disagree about where each command comes from:

| command | present in | resolved to |
|---|---|---|
| `/cc-tuner:plan` | this checkout only (skill) | this checkout |
| `/cc-tuner:spec` | both (installed command, local skill) | this checkout |
| `/cc-tuner:run` | both (installed command, local skill) | **installed 0.10.0** |

Same collision, opposite outcomes. The likely mechanism is that a *command* outranks a *skill* of the
same name, and Task 7 moved `run` from `commands/` to `skills/` — so the installed copy still has
`commands/run.md` to win with, while `plan` has no installed counterpart at all. That does not
explain `spec`, which also exists both ways and resolved locally; the ordering is not something this
run established, only that it is not consistent.

**Consequence for the eval:** the session exercised `runctl.sh`, run-state files and a phase protocol
— the runtime this branch deleted. Nothing it did or refused says anything about the code under test.

**Workaround applied:** `claude plugin disable cc-tuner@cc-tuner --scope local` inside both eval
repositories, which writes `.claude/settings.local.json` there and leaves the user-scope install
alone. Verified afterwards that `personal-os` and the `cc-tuner` checkout still report
`enabled=true`.

**Later observation, and it corrects this finding.** The same thread log carries `  APPROVE---` at line 306 and a clean `  APPROVE` at line 388 — whether Codex terminates its reply **varies between rounds**. The gate was intermittent, not broken, which is why a fresh thread later attributed an approval with the defect still unfixed in the installed copy. An intermittent gate is worse to diagnose than a dead one: the same candidate, reviewed twice, is attributable once.

**Left open:** whether a released version has this problem. After a normal `/plugin update` the
installed copy *is* the new one, so `commands/run.md` no longer exists anywhere — the collision is
specific to running a checkout beside an older install. It is still worth stating in the eval
instructions, because that is the only way this eval is ever run.

#### Finding 2 — the old runtime refused correctly, for a reason worth keeping

Before it could act, `/run` (the installed 0.10.0) found `TaskCreate` unavailable — that session's
MCP server had dropped — and stopped at its planning phase rather than proceeding without a visible
plan. It changed nothing under `src/`, `tests/` or `README.md`; the tree stayed at `95fac98`.

The refusal was right and the refusing code was deleted. The replacement `/run` at that revision had
no equivalent because its frontier rule was an instruction rather than a gate. Run 2 therefore had
to establish what it did when the task tools were missing; the rule later moved into `plan-lint.sh`.
