# The authenticated eval

The only tier that can prove a skill causes `TaskCreate` to be called.

Everything else in this repository tests **scripts**: `tests/flow/` runs them against real git
repositories with real payloads on stdin, and can settle every question about what a script decides.
None of it can settle whether a skill makes a model do something, because in that tier no producer
exists. That is what this is for, and it is why `tests/run.sh` does not include it: it needs auth,
it costs tokens, and it runs by hand.

**Status: run 2 in progress, 2026-08-16.** Steps 0, 1 and 4 observed PASS against a live PR; the
step 2 also PASS with one part unmeasured; 2b blocked by a dependency; steps 3 and 5 not run. Run 1 is kept below:
it is the run where `/run` silently resolved to the *installed* plugin, which step 0 caught.

A step recorded as passing on the strength of reading a skill's text is the exact failure this branch
exists to remove — so a step is either observed or it is blank.

## What it costs

One session per scenario, two scratch repositories, and a handful of real PRs. Budget an hour of
attended time; most of it is waiting on CI. The two flow runs are the expensive part, and they are
deliberately not shareable — step 2 must not inherit step 1's workspace.

## Before you start

Read [`fixture-spec.md`](fixture-spec.md): the task to hand `/cc-tuner:spec`, which two repositories
to run it in, and why that task rather than a smaller one.

Both repositories exist and are configured (2026-08-15). What that setup had to get right, in case
it ever needs redoing: a GitHub remote, `gh auth status` clean, a runnable test command, and **at
least one required status check on the target branch**. `merge.sh` refuses a repository that
requires nothing — absent CI is unproven CI — so a repo without branch protection fails step 2b for
a reason that has nothing to do with the code under test.

## Running it

**First, disable the installed copy in the eval repository** — already done in both, but this is the
step to repeat if the repos are ever recreated. `--plugin-dir` adds a second plugin of the same name
rather than replacing the installed one, and run 1 showed `/cc-tuner:run` resolving to the installed
`commands/run.md` while `/spec` and `/plan` resolved locally:

```bash
cd <eval-repo> && claude plugin disable cc-tuner@cc-tuner --scope local
```

Then launch against **this checkout**:

```bash
claude --plugin-dir <path-to-this-repo>/plugins/cc-tuner
```

Then record, in the log below, the resolved plugin root and this repository's SHA:

```
/cc-tuner:setup          # its doctor prints the resolved plugin path
git -C <path-to-this-repo> rev-parse HEAD
```

This is step 0 and it is not ceremony. Without it the eval can exercise the installed 0.10.0 and
report a pass — which is not hypothetical. It is the original defect: sessions holding a frozen
`${CLAUDE_PLUGIN_ROOT}` while everyone read the new code.

## The steps

Each one is written out in `docs/superpowers/plans/2026-08-13-native-first-lifecycle.md` under
Task 8, with what it must observe and why it exists. In brief:

| # | What it observes |
|---|---|
| 0 | The session is running this checkout, proved by the recorded path and SHA |
| 1 | Attended `spec → plan → run`: branch before `CONTEXT.md`, plan committed and linting clean, `TaskList` carrying **`blockedBy` edges**, frontier order, checkboxes ticked, stops at each delivery boundary |
| 2 | `--auto`, whole flow, **fresh repository and session**: no approval question, plan committed, tasks created, boundaries not stopped at, a task with a non-empty `blockedBy` refused out of order |
| 2b | Producer → checked path: verdict posted only after the `--required` marker, `commit.oid` equal to the head SHA, and `merge.sh --check-only` reporting the candidate would be accepted |
| 3 | Recovery on the **graph**: same `blockedBy` edges after a fresh session, same after `/clear`, no duplication after `/compact` |
| 4 | Live denial: `merge.sh --check-only` on a head SHA with no verdict refuses, naming the missing fact |
| 5 | The nine `tests/scenarios/task-run/` probes re-measured against the shipped skills |
| 6 | Every outcome recorded here, dated, and committed |

Step 3 asserts the edges, not the row count: a rebuilt list with the right number of tasks and no
dependencies is the failure a one-pass implementation produces, and it looks correct from a distance.

Step 5 exists because all nine GREEN runs were taken on 2026-08-10 against `commands/run.md`, a file
this branch deleted three days later. Each scenario records what it was measured against and
`tests/run.sh` requires that field, so re-measuring rewrites `date`, `measured_against` and `runs` —
it does not add a row. **A scenario that no longer reproduces is a finding about the rewrite, not a
scenario to delete.**

## Acceptance

Every step — 0, 1, 2, 2b, 3, 4, 5 and 6 — observed PASS in a real session. Not-yet-run does not
count as a pass, and the branch is not finished until this file says so.

## Log

Written in the MEASURED style of `docs/spike-native-flow.md`: what was run, what was seen, and what
that does or does not establish. Leave the outcome blank until it is observed.

### Run 2 — 2026-08-15/16 (attended, in progress)

Same repository and branch as run 1, after disabling the installed copy locally. `/cc-tuner:run`
resolved to `~/Projects/ai/cc-tuner/plugins/cc-tuner/skills/run` and drove `plan-path.sh` and
`plan-lint.sh` — this checkout's runtime, with no `runctl` anywhere in the session.

| Step | Outcome | What was observed |
|---|---|---|
| 0 | **PASS** | The loaded skill path is this checkout's `skills/run`; `runctl` appears in the transcript only inside the stale state file it was reading. |
| 1 | **PASS** | Four slices worked in frontier order, each RED→GREEN→mutation→tick→commit, stopping at every boundary. 27/27 criteria ticked, tree clean, PR #3 opened at `4f70dca`. |
| 2 | **PASS, one part unmeasured** | Fresh repo, fresh session, `cc-tuner-eval-2`. `/plan --auto` asked **zero** questions where `/spec` had asked eight; plan committed and lint-clean; `/run --auto` worked all three slices to a PR **without a single user turn** — the attended run needed one per slice. Task publication could not be measured: the task tools were absent and `/plan` said so rather than skipping quietly. See below. |
| 2b | **BLOCKED** | Not by cc-tuner: Codex approved in substance, the required gate could not parse it, and `/run` correctly refused to publish an approval it could not attribute. See finding 7. |
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

The task tooling has now been absent in three consecutive sessions. That is an environment property, not a finding about cc-tuner — but it means the frontier rule, which the ADR already calls an instruction rather than a gate, is also the rule this eval keeps failing to reach.

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

**Left open:** whether a released version has this problem. After a normal `/plugin update` the
installed copy *is* the new one, so `commands/run.md` no longer exists anywhere — the collision is
specific to running a checkout beside an older install. It is still worth stating in the eval
instructions, because that is the only way this eval is ever run.

#### Finding 2 — the old runtime refused correctly, for a reason worth keeping

Before it could act, `/run` (the installed 0.10.0) found `TaskCreate` unavailable — that session's
MCP server had dropped — and stopped at its planning phase rather than proceeding without a visible
plan. It changed nothing under `src/`, `tests/` or `README.md`; the tree stayed at `95fac98`.

The refusal was right and the refusing code is deleted. The new `/run` has no equivalent, because its
frontier rule is an instruction rather than a gate — which the ADR states plainly. Worth watching in
run 2: what the new `/run` does when the task tools are missing.
