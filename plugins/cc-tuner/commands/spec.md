---
description: Turn a rough task into a spec /cc-tuner:run can execute unattended — grilled requirements, acceptance criteria that a machine can check, and the config the run needs. Use for "напиши спеку", "spec this out", or before any --auto run.
argument-hint: '<issue number | URL | free-text description>'
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill, TodoWrite, AskUserQuestion, WebFetch, WebSearch
disable-model-invocation: true
---

# /cc-tuner:spec

Produces one artifact: a spec document that `/cc-tuner:run` can execute **without asking you
anything**. This command is where all the asking happens.

The split exists because the old `/cc-tuner:execute-task` tried to do both and could do neither well:
its step 1 was marked `🚦 always`, so full autonomy was structurally impossible, while the interactive
work was squeezed into one step of a ten-step pipeline. Interrogation and execution want opposite
things — one wants your attention, the other wants your absence.

**A spec is done when a competent stranger could execute it without you in the room.** That is the bar
to hold yourself to, and the reason not to stop at the first plausible-looking draft.

## 1. Anchor and read what exists

```bash
git rev-parse --show-toplevel || { echo "not a git repo"; exit 1; }
```

Read, in this order — each can make the next question unnecessary:

- `.claude/rules/task-flow.local.md` — board name, cached field IDs, label taxonomy.
- The issue, if `$ARGUMENTS` names one: `gh issue view <N> --json title,body,labels,projectItems`.
- The repo's own instructions (`CLAUDE.md`, `AGENTS.md`, `.claude/rules/`) — its conventions are
  constraints on the spec, not suggestions.
- The code the task touches. A spec written without reading the code specifies a fantasy.

Do not ask about anything you can read. Every question you ask that the repo already answered spends
the user's attention on your laziness.

## 2. Grill

Invoke `mattpocock-skills:grilling`, using `mattpocock-skills:domain-modeling` for the vocabulary. That
pair is what `grill-with-docs` is — its body is one line delegating to them — and it is the pair you
can actually call: `grill-with-docs` ships with `disable-model-invocation: true`, so it never reaches
the skill list and is only reachable when a human types it.

Grilling interviews one question at a time down the decision tree. Pull current docs via Context7 as
you go, so answers are anchored to how the dependencies behave now rather than to how anyone remembers
them.

Grill until the answers stop changing your draft — not until the questions run out. Two signals you
stopped too early: you are about to write "TBD" or "as appropriate" anywhere, or you cannot state what
the *first* failing test would assert.

## 3. Write acceptance criteria a machine can check

Tag every criterion `[machine]` or `[eyes]`.

- `[machine]` — something a command or a browser-driving step can decide. UI flows via chrome-devtools
  MCP (navigate, click, screenshot), behaviour via the repo's test scripts.
- `[eyes]` — needs a human to look.

**Every `[eyes]` criterion must come with a machine replacement or an explicit waiver.** An `[eyes]`
criterion in a spec destined for `--auto` is a stop the run cannot clear, so a spec full of them is a
spec that cannot run unattended. When you write one, take the next step: either state the machine
check that replaces it (a screenshot diff, a computed contrast ratio, an axe-core assertion) or record
that the user knowingly accepted a hard stop there. Never leave a bare `[eyes]` and let `/run`
discover it.

Vague criteria are the other failure. "Looks right" is not a criterion. "The empty state renders the
illustration and the CTA is focusable" is.

## 4. Decide the shape of the work

Per the `cc-tuner:task-flow` skill: more than one PR, more than one repo, or phases a human will
review separately → an epic with sub-issues, and **one spec per sub-issue**. A spec that spans three
PRs cannot be executed unattended, because the first merge invalidates the base of the rest.

Otherwise a plain issue on the board with Status and Priority set.

## 5. Write the spec

To `<plans-root>/PLANS/YYYY-MM-DD-<slug>.md` — `wiki/` if the repo has one, else `docs/`. Structure:

```markdown
# <title>

**Goal:** one paragraph. What is true after this ships that is not true now.
**Issue:** #N (link; the issue body links back here)
**Architecture:** the approach, and the alternatives rejected with the reason.

## Acceptance criteria
- [ ] [machine] <criterion> — checked by: <exact command or MCP step>
- [ ] [eyes] <criterion> — machine replacement: <check> | WAIVED by user <date>

## Tasks
1. <file path> — <what changes and why>

## Out of scope
<the things a reader would otherwise assume are included>

## Run config
merge: squash|merge · auto: yes|no · ci: <command> · cheap_gate: <command> · test: <command>
```

**Out of scope** is not filler. It is where you record the boundary you and the user agreed on, and
its absence is how an unattended run turns a two-file change into a refactor.

Then commit the spec, and create or update the issue so the two point at each other.

## 6. Hand off

Print the spec path and the exact next command:

```
/cc-tuner:run docs/PLANS/2026-07-31-thing.md            # HITL between phases
/cc-tuner:run --auto docs/PLANS/2026-07-31-thing.md     # unattended, merges on green CI
```

State plainly whether the spec is `--auto`-ready. It is **not** if any criterion is `[eyes]` without a
waiver, if the run config has a blank `ci`, or if the work needs more than one PR. Saying so here
costs a sentence; discovering it mid-run costs the run.

## Verification

- [ ] Every acceptance criterion names the command or MCP step that decides it
- [ ] No `[eyes]` criterion without a machine replacement or a recorded waiver
- [ ] No "TBD", no "as appropriate", nothing deferred to the executor's judgement
- [ ] Spec is committed and the issue links to it both ways
- [ ] `--auto` readiness stated explicitly, with the reason when the answer is no
- [ ] Nothing asked that the repo, issue, or code already answered
