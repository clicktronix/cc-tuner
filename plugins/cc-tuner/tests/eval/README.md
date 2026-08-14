# The authenticated eval

The only tier that can prove a skill causes `TaskCreate` to be called.

Everything else in this repository tests **scripts**: `tests/flow/` runs them against real git
repositories with real payloads on stdin, and can settle every question about what a script decides.
None of it can settle whether a skill makes a model do something, because in that tier no producer
exists. That is what this is for, and it is why `tests/run.sh` does not include it: it needs auth,
it costs tokens, and it runs by hand.

**Status: not yet run.** No row below is filled in. A step recorded as passing on the strength of
reading a skill's text is the exact failure this branch exists to remove — so a step is either
observed or it is blank.

## What it costs

One session per scenario, two scratch repositories, and a handful of real PRs. Budget an hour of
attended time; most of it is waiting on CI. The two flow runs are the expensive part, and they are
deliberately not shareable — step 2 must not inherit step 1's workspace.

## Before you start

Read [`fixture-spec.md`](fixture-spec.md): the task to hand `/cc-tuner:spec`, why that task and not
a smaller one, and what the scratch repository must already have. The short version: a GitHub
remote, `gh auth status` clean, **at least one required status check on the target branch**, and a
runnable test command. `merge.sh` refuses a repository with no required checks, so a repo without
branch protection fails step 2b for a reason that has nothing to do with the code.

## Running it

Launch against **this checkout**, never an installed copy:

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

### Run 1 — <date>

- **Plugin root:** _<paste what doctor resolved>_
- **Repository SHA:** _<paste>_
- **Scratch repos:** _<attended>, <auto>_

| Step | Outcome | What was observed |
|---|---|---|
| 0 | | |
| 1 | | |
| 2 | | |
| 2b | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | | |

**Findings:** _anything the run showed that the scenario tier could not, including steps that passed
for the wrong reason._
