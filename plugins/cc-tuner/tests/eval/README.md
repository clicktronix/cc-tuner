# The authenticated eval

The only tier that can prove a skill causes `TaskCreate` to be called.

Everything else in this repository tests **scripts**: `tests/flow/` runs them against real git
repositories with real payloads on stdin, and can settle every question about what a script decides.
None of it can settle whether a skill makes a model do something, because in that tier no producer
exists. That is what this is for, and it is why `tests/run.sh` does not include it: it needs auth,
it costs tokens, and it runs by hand.

**Status: every step observed PASS in run 3 (2026-08-20/21), against the single frozen SHA
`cd9fa2f`.** Run 2's statuses were corrected twice after review before this run started; they stand
below unchanged, because a superseded result is evidence about the method and deleting it would leave
only the flattering half.

| step | run 3 | run 2 |
|---|---|---|
| 0 | **PASS** — SHA frozen in a detached worktree before the first session, plugin root proved in both repos | PARTIAL — path recorded, no SHA |
| 1 | **PASS** — one session, `/spec → /plan → native tasks → /run → merge`, against a clause amended for the reason in finding 13 | PARTIAL — assembled from two sessions |
| 2 | **PASS** — plan to merged PR in a single unattended turn; the `blockedBy` refusal took a second, isolating fixture (finding 11) | PARTIAL — 3 of 5 |
| 2b | **PASS** — `--check-only` accepted, then the same script merged | PASS |
| 3 | **PASS** — same edges after a fresh session and after `/clear`; no duplication after `/compact` | not run |
| 4 | **PASS** — both denials live, `rc=1` | PASS |
| 5 | **PASS** — four more probes re-measured after an external review caught the row overstating how many were unaffected | PASS, and it caught a live regression |
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
| 5 | **PASS**, after a correction | **Five** of the nine target files unchanged since the 2026-08-20 measurement at `32f362b`; **four** do not, and an earlier revision of this row said eight — `deep-review/SKILL.md` and `plan/SKILL.md` both changed between that SHA and the frozen one, which reaches `request-changes-blocks-merge`, `reviewer-unavailable-fails-closed`, `stale-review-after-fix` and `visible-plan-before-edit` as well. All four were re-measured at `cd9fa2f`, 2/2 GREEN each, and `visible-plan-before-edit` had its `skills` field corrected: it points at `plan/SKILL.md` and listed only `run`. `sensitive-small-diff-review` got **RED and GREEN at one SHA this time**, which is what its own note demanded: with the six surfaces ablated from the frozen skill 2/2 probes chose serial review; with the skill unmodified, 2/2 fanned out and named pricing. |
| 6 | this section | |

**Task 8's promise — `/spec → /plan → native tasks → /run` end to end in one session — is observed.**
Twice, in two modes, on two repositories, against one frozen SHA.

#### Finding 10 — a verdict that says APPROVE, parsed as no decision, and it cost a paid round

Codex's round-2 reply in scenario B ended `APPROVE` **without a trailing newline**, so the driver's
`---` terminator joined it into `APPROVE---`. The lenient parser strips that; the strict required
parser refuses it by design, and recorded `NO_DECISION` on a genuine approval. The run re-dispatched
against the identical candidate rather than editing the state file or manufacturing a commit, and
approval came at attempt 3 of 5.

This is the **third** instance of one seam in eight days: a producer whose last line is not terminated
and a checker that requires it. The first was `merge.sh` reading a whole review body instead of its
first line; the second was `codex-thread.sh`'s `sed 's/^/  /'` dropping the final newline (PR #6 in
`cc-codex-triage`, fixed with `awk`). Each was invisible to every test on both sides, because each
side's suite asserted only its own half. **The fix belongs in `cc-codex-triage`**: the terminator
must not be able to touch the payload — emit it on its own line unconditionally, the same way `awk`
fixed the indenting.

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

Whether that is right is a design question, not a defect report, and both halves are worth stating.
It rewrote the dependency graph rather than working around it, left the plan true rather than
silently divergent, and flagged the edit as beyond ticking boxes. It also means **the edge is
advisory**: it stops the model's own reordering, not the operator's. The ADR already says the
frontier rule is an instruction rather than runtime code, and this is what that sentence looks like
from the outside. The one thing the eval can now say precisely: unprompted, the edge holds; asked
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
