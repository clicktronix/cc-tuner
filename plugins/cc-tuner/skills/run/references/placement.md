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

**Review is the exception.** Independent read-only lenses of the selected advisory workflow may
fan out over one immutable candidate, including Matt's Spec/Standards pair. One owner aggregates
findings; candidate changes and delivery remain sequential.

**A fanned-out unit hands back commits, never a pull request.** Whoever fanned the work out is the
one owner: they take the units' commits into **one candidate per repository**, run the authoritative
tests and review for each candidate, and verify the shared outcome against that set of commits. A
unit does not open its own PR, does not merge, and does not claim its own approval.

**A unit runs whatever checks it needs while it writes** — those are part of writing, not a second
opinion about the candidate. What never fans out is the **decision**: whether the assembled candidate
passes, what the review verdict is, and every step of delivery. Those read the assembled work and belong to
one owner.

One orchestrator and shared outcome; each repository has its own plan, candidate, verdict and merge.
Dispatch and integrate a unit only in its named repository. Local ready batches do not establish
cross-repository readiness: the orchestrator checks the shared spec's prerequisites before dispatch.

`plan-lint.sh ready-batches --active <running slices>` decides which ready slices have Owned paths
proven disjoint from each other and from every running one. This reference only places the batch it
returned; do not recalculate or widen that batch from plan prose, and do not fall back to `frontier`
for candidates — it carries no path proof.

## Implementation brief and return

The orchestrator builds the brief from committed files, not session history. Include the local spec
path with an instruction to read it, the slice verbatim (title, Owned paths, Deciding check, Delivers,
criteria), and any shared-task prerequisites. Give the unit these constraints:

- Write only inside Owned paths; prove the deciding check with its expected RED or approved non-code baseline.
- Do not delegate further. Nested delegation previously spawned dozens of unrequested agents.
- Report commands, results, what was not verified, and any incorrect assumptions in the slice.
- Commit using repository conventions; do not push, open/comment on a PR, merge or claim approval.
- Return findings to the orchestrator; do not create issues or own the task list.

On return, the orchestrator reads the diff, checks Owned paths and inspects the actual check output
and tested inputs. Reuse evidence only when it still covers the integrated result; otherwise run
the deciding check here. An unsupported success summary does not establish completion. The orchestrator owns mutation-log interpretation,
slice completion, full regression, runtime acceptance, review verdict, DoD and delivery.

## How a unit is dispatched

Units are **dispatched dynamically with the Agent tool**. The plugin ships one agent definition,
`cc-tuner:deep-review-lens`, and no others, and the line between the two is what a definition can
hold that a brief cannot: a tool list, a model, an effort. A slice's brief is different every time
and is already written down — the committed spec plus the slice's own text — so a named
implementation agent would only add a second place where that job is described. A read-only lens
needs the opposite: the same constraint every time, enforced by the tool list rather than by prose.
Ship a definition when the constraint repeats; write a brief when the task does.

- **Type.** `cc-tuner:slice-unit` for an implementation slice: it is `general-purpose` with a
  200-turn cap and `sonnet` as the default model, which is what makes a partial return possible at
  all. `general-purpose` for any other judgement-forming work, and as the fallback when the host does
  not list the unit type — same brief, no cap, say so in the run log. `Explore` only to locate
  things, because it reads excerpts and does not audit what it finds, and because it skips the
  CLAUDE.md hierarchy, which is what makes it the cheap one. Review lenses use
  `cc-tuner:deep-review-lens`. If the host offers none of these, do the work yourself rather than
  guessing at a type that may not exist.
- **Model.** Choose by the difficulty of the slice, honestly: `sonnet` for implementation from a
  clear brief, which is where the saving is — it is also `cc-tuner:slice-unit`'s default, and a
  `model` on the dispatch overrides the definition's; a stronger model when the slice itself is hard, not as a
  sign the brief is unfinished. The session's own model for what is a judgement: an architectural
  choice, or a final review whose findings are contested. Reasoning effort is **not** settable on a
  dynamic dispatch — the Agent tool takes a model, not an effort, and a subagent inherits the
  session's; only an agent definition's `effort` field changes it. Do not write an effort into a
  brief and count it as configured. `haiku` only for
  mechanical retrieval where being wrong is visible immediately. The orchestrator stays on the
  session's own model, because what it does is decide. Escalate on evidence, not on feeling: a unit
  failing the same deciding check twice is re-dispatched once on a stronger model with the failure
  text attached, and after that the orchestrator takes the slice.
- **Cost is not automatic.** A fresh unit pays its own system prompt, tool list and the whole
  CLAUDE.md hierarchy before it reads a line: measured on one repository, 34k–42k tokens per
  `general-purpose` spawn against 57k for the parent's first request. Delegation pays when the unit
  reads more than that on the parent's behalf, or when two units genuinely run at once; a slice
  that fits in a handful of tool calls costs more delegated than done. A long brief plus a
  verification pass can cost more than doing the slice. Say the expected saving when proposing a
  fan-out, and count builds separately from agents — two units are two agents and, on a repository
  with a heavy build, two full builds. Subagent cache entries live five minutes, so units of one
  batch dispatched in one message share a prefix and a late joiner past that window rebuilds it.
- **One heavy check at a time.** A full build, a full suite, a container start: run those in sequence
  even when the units writing the code run in parallel. **The concurrency cap counts running units,
  not the batch.** With rolling dispatch a new batch joins units still working, so on a repository
  where the deciding check is a build, hold the *active set* — running plus about-to-start — at two,
  and dispatch from a returned batch only up to that ceiling; the rest waits for a unit to return.
  Machines run out of memory before they run out of agents, and a run killed for memory grades
  nothing — it only spends.
- **Concurrency.** Every dispatch runs in the background: the Agent tool returns at once with a
  handle, the unit's result arrives later as a task notification, and the orchestrator cannot ask
  for a blocking foreground run. So the number of units in flight is the number dispatched and not
  yet returned, whatever the message boundaries — one dispatch per message does **not** serialise
  them. The cap above is therefore held by the orchestrator: dispatch up to the ceiling, then do
  nothing that starts a unit until a notification returns one. Several dispatches in one message
  still matter for one reason: same-prefix first requests share a cache. Do not delegate further
  from inside a unit beyond a lookup; `/cc-tuner:setup` offers `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`
  at `1` or `2`, which makes that a limit the platform enforces rather than a line in the brief.
- **Isolation.** A single unit with nothing else in flight works in this checkout and needs nothing.
  **For slice work the plugin makes the worktree itself and does not rely on the Agent tool's
  `isolation: "worktree"`.** Native isolation branches from the repository's *default branch* unless
  the user has set `worktree.baseRef: "head"` in their settings — a key the plugin cannot set per
  dispatch and that accepts no branch name. A unit opened from the default branch has no spec, no
  plan and none of the slices already landed, and its shell is fenced inside that tree. Native
  isolation is right for a throwaway experiment; a slice needs the task branch, so it gets an
  explicit worktree from `HEAD`, below.
- **Parallel units, when a batch has more than one.** Make the worktrees yourself, from the task
  branch, and hand each unit a path:

  ```bash
  git worktree add -b <slice-branch> ../wt-<slice> HEAD
  ```

  Dispatch an ordinary (non-isolated) unit told to work in that directory. When it returns, bring its
  commits over with `git cherry-pick <task-branch>..<slice-branch>`, confirm the work actually landed —
  the deciding check covers the integrated result under the evidence rule above, and
  `git diff <slice-branch> -- <its Owned paths>` is empty —
  then `git worktree remove ../wt-<slice> && git branch -D <slice-branch>`.

  Cherry-pick can leave the source branch outside the target's ancestry, so `-d` may refuse it.
  Use `-D` only after verifying integration and removing the clean worktree; never discard unlanded
  work. Disjoint paths prevent file overlap; worktrees prevent a shared index.
- **Context.** A subagent inherits the `CLAUDE.md` hierarchy, the MCP servers and the skill list, and
  nothing else from this session — not the transcript, not files already read, not the output style,
  not what a review just said. Only the final message comes back. Anything load-bearing goes into
  the brief as literal text or as a path it is told to read; anything the orchestrator needs back
  is a file the unit writes or a commit it makes, not a long report.

## Unit size and partial returns

A `cc-tuner:slice-unit` stops at 200 turns and returns marked partial. That number comes from the
field: across 399 observed units the median was 76 turns, 320 fit in 150, and the ones past 200
were the ones whose context had grown past 300k and was being re-read on every turn — the cost the
cap exists to stop. A partial return is a run event, not a failure, and it is the orchestrator's:

1. **Read what landed.** The worktree's commits, its diff against the slice branch's base, and the
   deciding-check output the unit reported. A criterion counts as proven only after you have read
   its evidence; the unit's closing summary is not that.
2. **Redispatch once, fresh.** A new `cc-tuner:slice-unit` with a brief that states what landed
   (the commits, the proven criteria) and what remains. Fresh, because a new unit starts at the
   spawn cost while resuming the old one through `SendMessage` continues the 300k–400k context the
   cap just stopped.
3. **Take the second partial yourself.** A slice that two capped units could not finish is not
   going to fit a third; the orchestrator finishes the remainder, the way it already takes a slice
   whose unit failed the deciding check twice.

Record it in the plan under the slice, one line the next reader can act on:

```text
Partial: <unit> at maxTurns; landed <commits>; redispatched once
```

The parser ignores the line, like `Evidence:`. It exists so a resumed session knows the slice has
already spent its redispatch.

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

`/cc-tuner:spec` creates the task branch before methods that may write design artifacts.

The prior ordering failures and their evidence live in
[case studies](../../task-flow/references/case-studies.md).
