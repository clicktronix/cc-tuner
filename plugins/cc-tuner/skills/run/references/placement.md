# Where the work happens

Reference for `/cc-tuner:run`. Two questions: what may run at the same time, and which workspace a
method belongs in. Both are ordering rules — cc-tuner never rewrites another plugin's skill, it
decides when each one runs.

## Parallelism, only where it is safe

**Delegating and parallelising are different decisions.** One slice handed to one subagent while the
orchestrator waits is delegation: it costs a brief, buys context back, and needs no worktree. Two
units writing at once is parallelism, and everything below is about that. Read a rule here as a limit
on running things at the same time, never as a limit on handing one job to one unit.

Fan out **only across independent code-writing units**, one isolated git worktree each. Never
parallelise a testing decision or any step of delivery: those read a state that the other branch is
still changing, and two answers about one candidate is not twice the confidence.

**Review is the exception, and only in one direction.** Independent read-only lenses over one
*immutable* candidate may fan out when `/run` selects `deep-review`. The reason above does not apply
to them, because they read a tree nobody is changing. What must not fan out is the **decision**: one
owner merges the lenses into one verdict, and every step of the lifecycle around the review stays
sequential.

Until 2026-08-21 this paragraph said "never parallelise review" flat, which contradicted
`deep-review/SKILL.md` inside the same plugin. Run 3 caught both rules quoted in one session, and a
model handed two opposite rules follows the cheaper one.

**A fanned-out unit hands back commits, never a pull request.** Whoever fanned the work out is the
one owner: they take the units' commits into a **single candidate**, run the authoritative tests on
that candidate, carry it through one review to one verdict, and open the one pull request that
merges. A unit does not open its own PR, does not merge, and does not claim its own approval — two
candidates reviewed apart are two things nobody reviewed together.

**A unit runs whatever checks it needs while it writes** — those are part of writing, not a second
opinion about the candidate. What never fans out is the **decision**: whether the assembled candidate
passes, what the review verdict is, and every step of delivery. Those read one candidate and belong to
one owner.

One plan, one candidate, one verdict, one merge.

An earlier revision of this paragraph ended "the parallelism lives in the writing and nowhere else",
which reads as forbidding a unit its own tests while the rule two paragraphs up forbids only a
parallel *testing decision*. One plugin, two readings — the same defect as finding 14, introduced by
the fix for finding 14.

`plan-lint.sh ready-batches` decides which ready slices have proven-disjoint Owned paths. This
reference only places the batch it returned; do not recalculate or widen that batch from plan prose.

## How a unit is dispatched

Units are **dispatched dynamically with the Agent tool**, not selected from a roster of named agents.
The plugin ships no agent definitions on purpose: a slice's brief is different every time, and it is
already written down — the committed spec plus the slice's own text. A named agent would add a second
place where that job is described, and the two would part company.

- **Type.** `general-purpose` for anything that writes code or forms a judgement, including a review
  lens; `Explore` only to locate things, because it reads excerpts and does not audit what it finds.
  Both are built in. If the host offers neither, do the work yourself rather than guessing at a type
  that may not exist.
- **Model.** `sonnet` for implementation; `haiku` only for mechanical retrieval where being wrong is
  visible immediately. The orchestrator stays on the session's own model, because what it does is
  decide. Escalate on evidence, not on feeling: a unit failing the same deciding check twice is
  re-dispatched once on a stronger model with the failure text attached, and after that the
  orchestrator takes the slice. A third cheap attempt costs more than the expensive one would have.
- **Concurrency.** Several dispatches in one message run at once; one per message runs in sequence.
  That is the whole difference, and it is easy to lose by narrating between calls.
- **Isolation.** `isolation: "worktree"` for every parallel implementation unit. Disjoint Owned paths
  prove two units will not fight over a *file*; they do not stop two units committing into one index.
- **Context.** A subagent inherits the `CLAUDE.md` hierarchy and nothing else from this session — not
  the transcript, not the output style, not what a review just said. Anything load-bearing goes into
  the brief as literal text or as a path it is told to read.

## Where each method runs

Ordering, not overrides. cc-tuner never rewrites another plugin's skill; it decides when each runs.
The axis is what a method **persists**, not whether it feels exploratory.

| method | workspace |
|---|---|
| `research`, `domain-modeling` | the task branch — their output is committed, and a saved artifact is a write |
| `prototype` | a disposable branch or worktree — its output is throwaway by definition, and landing it on the task branch is how a spike becomes the implementation by accident |
| `tdd` | the task branch, around the slice's deciding check |
| `diagnosing-bugs`, reading | the task branch |
| `diagnosing-bugs`, probe edits | a disposable workspace — instrumentation and bisect stubs are experiments, and an experiment that lands is a regression waiting |
| `code-review`, deep-review | the candidate SHA |

`/cc-tuner:spec` created the task branch before any of this, because its own grilling phase **may**
write `CONTEXT.md` and ADRs — `domain-modeling` creates those lazily, only when there is something to
write, and "may" is enough to force the branch first: the ordering has to hold for the runs where it
does write.
