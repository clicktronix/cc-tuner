# The authenticated eval

The only tier that can prove a skill causes `TaskCreate` to be called.

Everything else in this repository tests **scripts**: `tests/flow/` runs them against real git
repositories with real payloads on stdin, and can settle every question about what a script decides.
None of it can settle whether a skill makes a model do something, because in that tier no producer
exists. That is what this is for, and it is why `tests/run.sh` does not include it: it needs auth,
it costs tokens, and it runs by hand.

**Status: Task 8 is NOT complete.** Corrected 2026-08-20, twice, after review — this summary
contradicted the table below until the second pass, which is the defect it exists to prevent.

| step | status |
|---|---|
| 0 | PASS |
| 1 | **PARTIAL** — observed across two sessions, not one |
| 2 | **PARTIAL** — 3 of 5 assertions |
| 2b | PASS |
| 3 | **not run** |
| 4 | PASS |
| 5 | PASS, and it caught a live regression |
| 6 | this file |

The promised flow — `/spec → /plan → native tasks → /run` — has never been observed end to end in a
single session, because the task tools were absent in all but the first. Until it is, nothing here
closes the branch.

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


### Evidence captured against deleting the eval repositories (2026-08-20)

**They are NOT deleted.** An earlier revision of this section said they were; the `gh repo delete`
call failed for want of the `delete_repo` scope, and the sentence recorded the intention as the act.
That is the failure this whole file exists to catch, written into the file itself. `clicktronix/cc-tuner-eval-1`
and `-2` both still exist.

Captured first, so the citations below stay checkable when they do go:

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

**No frozen SHA, and that is a finding rather than a gap in the notes.** Step 0 requires the plugin
path *and* the repository SHA. The path is recorded; the SHA cannot be, because the branch moved
underneath the run — `merge.sh` was fixed at `643c509` while the session was mid-flight, precisely so
the session could get past the defect it had just surfaced. A skill is read from the working tree at
the moment it is invoked, so this run exercised more than one revision and no single SHA describes
what it tested. The next eval must run start to finish against one SHA recorded before it begins, and
any fix found along the way ends that run rather than being folded into it.

| Step | Outcome | What was observed |
|---|---|---|
| 0 | **PASS** | The loaded skill path is this checkout's `skills/run`; `runctl` appears in the transcript only inside the stale state file it was reading. |
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

The task tooling has now been absent in three consecutive sessions. That is an environment property, not a finding about cc-tuner — but it means the frontier rule, which the ADR already calls an instruction rather than a gate, is also the rule this eval keeps failing to reach.


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

The refusal was right and the refusing code is deleted. The new `/run` has no equivalent, because its
frontier rule is an instruction rather than a gate — which the ADR states plainly. Worth watching in
run 2: what the new `/run` does when the task tools are missing.
