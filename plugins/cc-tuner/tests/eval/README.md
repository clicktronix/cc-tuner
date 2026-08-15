# The authenticated eval

The only tier that can prove a skill causes `TaskCreate` to be called.

Everything else in this repository tests **scripts**: `tests/flow/` runs them against real git
repositories with real payloads on stdin, and can settle every question about what a script decides.
None of it can settle whether a skill makes a model do something, because in that tier no producer
exists. That is what this is for, and it is why `tests/run.sh` does not include it: it needs auth,
it costs tokens, and it runs by hand.

**Status: attempted once, 2026-08-15. Not complete.** `/spec` and `/plan` were observed working;
`/run` was never exercised, because it resolved to the *installed* plugin rather than to this
checkout. Step 0 exists to catch exactly that, and on its first run it did. See the log below.

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
