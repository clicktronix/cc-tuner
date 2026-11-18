# Where the work happens

`/cc-tuner:run` owns the plan, integration, acceptance, aggregate review and delivery decisions.
A unit receives one bounded implementation job and returns evidence; it does not own a PR or issue.

## Contents

- [Parallelism, only where it is safe](#parallelism-only-where-it-is-safe)
- [Heavy checks](#heavy-checks)
- [Brief and return](#brief-and-return)
- [Agent selection](#agent-selection)
- [Worktree isolation](#worktree-isolation)
- [Unit size and partial returns](#unit-size-and-partial-returns)
- [Method placement](#method-placement)

## Parallelism, only where it is safe

Delegate when saved context or independent work justifies the brief and verification cost. One
unit may work sequentially in the task checkout. Concurrent writers require independent slices,
disjoint Owned paths and separate worktrees. Use the batch from `plan-lint.sh ready-batches --active`;
do not recalculate ownership from prose.

The concurrency cap counts running units plus proposed starts, not just a returned batch. Respect
available host slots; on build-heavy repositories keep at most two implementation units active.
Heavy checks queue through machine-wide slots ([below](#heavy-checks)), so parallel units and
sessions run only as many at once as the machine allows. Candidate acceptance and delivery remain
sequential.

Independent read-only review is the exception to sequential review: its own skill defines the
reviewers and packets, while the orchestrator aggregates. `deep-review` owns its agent availability and
coverage refusals. Before paid fan-out, state the count, model and effort; a dollar figure needs a
source you can name.

## Heavy checks

This section owns the definition, who runs what, and the command; `/run`, `slice-unit` and
`verify-feature` point here.

A check is **heavy** when it is a full build, the full test suite, an e2e suite or a container start.
A **focused** check is the slice's targeted command, including its one browser or API regression test
when that is the deciding check, and anything else that finishes in seconds.

- **A unit runs focused checks.** A build or container start runs from a unit only when it is the
  slice's deciding check: once, through `heavy.sh`, and stopped before the unit returns.
- **The orchestrator runs the full suite**, at the cadence `/run`'s Test cadence names.
- **`verify-feature` runs the e2e suite.**
- **Browser MCP sessions and dev servers belong to the orchestrator and `verify-feature`.** A regression test
  that starts and stops its own server inside its test command is still focused.

Every heavy check, from whoever runs it, goes through the machine's slots:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/heavy.sh" --weight <w> --label "<repo>: <what>" -- <command>
```

The weight is how many of the machine's slots the check holds:

- e2e suite: `--weight 2`;
- full suite, build, container start: `--weight 1`. The slot does not bound containers that keep running
  after their start command returns.

A heavy.sh call inside another one runs in its slots; the outer call's weight governs. Capacity is
shared by every session on the machine and waiters start in arrival order, so the call may wait.
Start it as a Bash call with `run_in_background: true`, do other work meanwhile, and read the output
when it exits; the command's own output and exit code pass through unchanged.

While the system reports memory pressure, a check waits up to `CC_TUNER_HEAVY_MEM_WAIT` (600 s), then
starts anyway; for the next 600 s the wait is skipped for every check. A check also waits at most
`CC_TUNER_HEAVY_WAIT` (1800 s) for a slot, then starts without one. Carry into your report every
output line that starts with `heavy.sh: started under memory pressure`,
`heavy.sh: memory pressure not measured` or `heavy.sh: started without a slot`: a failure in that run
may be the machine, not the code.
heavy.sh's own failures exit 64; any other code is the command's.

## Brief and return

Pass the worktree, starting SHA, spec path, slice text, shared prerequisites, concurrent writers,
any partial result and the resolved `heavy.sh` command. The unit definition owns its checks and
return format. In local-only mode the orchestrator works directly in the approved checkout.

The orchestrator reads the diff, verifies paths and actual check inputs/output, and integrates commits into
one candidate per repository. Reuse evidence only when it still covers the assembled result.
Shared-task readiness is checked across the whole candidate set.

## Agent selection

Use `cc-tuner:slice-unit` for implementation. Its definition supplies sonnet, `effort: high` and
the turn cap; the ladder below says when to override the model. If unavailable, do the slice
yourself; do not substitute an uncapped worker. Use Explore for location search, not exhaustive
auditing, and a suitable general-purpose reader for other bounded questions. Review lenses use their
own restricted definition; `deep-review` owns their model and effort.

A brief configures neither model nor effort: pass them as the dispatch's `model` and `effort`
parameters, else the agent definition's, else the session's. The ladder:

- **Sonnet by default** for units, ordinary review and verification, at `effort: high` — whatever the
  session runs on, so a Fable or `max` orchestrator does not multiply every agent's cost.
- **Opus by complexity** (`model: "opus", effort: "medium"`), chosen by the orchestrator without
  asking, for a unit, ordinary reviewer or verifier whose work is one of:
  - a sensitive surface, as [delivery.md](delivery.md) step 2 lists them (authorization, secrets,
    cryptography, migrations, money, public contracts, infrastructure);
  - performance decided by measurement: profiling, a benchmark, a query plan;
  - concurrency, ordering or data-integrity logic;
  - an invariant that spans several modules or services;
  - a slice the plan marks `Model: opus — <reason>`;
  - a retry after the same deciding check failed twice on Sonnet, with that failure output in the brief.

  Size alone is not a case: a long mechanical slice stays on Sonnet. Write the reason as one line in
  the brief and, for a slice, beneath it in the plan, where `Evidence:` lines go:
  `Opus-reason: <the failed check and its output | the plan's reason | the case above>`. Pass the
  effort explicitly, or the agent's definition would run Opus at high. After an Opus attempt fails,
  the orchestrator takes the slice and runs `mattpocock-skills:diagnosing-bugs` on that check before
  editing: repeated failed attempts mean the cause is not where the briefs looked.
- **Fable only for the orchestrator.** A unit or reader on Fable needs the user's explicit decision.
- **Readers: Haiku** (`model: "haiku", effort: "high"`) for a bounded read-only question with a
  literal answer — locate, extract, list, summarise named files or command output. It decides
  nothing, so the orchestrator checks what it uses. Pass `model: "sonnet", effort: "high"` instead when
  the reader must judge — compare designs, assess a risk, explain why something fails. Readers have
  no definition of their own, so pass the effort explicitly. Use `Explore` for location search.

The orchestrator keeps the session's model and effort for its own decisions.

Track handles and completions. Multiple spawns can be in flight even when sent in separate messages;
wait for a slot before adding work.

## Worktree isolation

Create parallel slice worktrees explicitly from the current task candidate. This avoids depending on
host isolation defaults that may start from another branch without the spec or landed slices:

```bash
git worktree add -b <slice-branch> ../wt-<slice> HEAD
```

Give the unit that directory. On return, inspect its commits and integrate them:

```bash
git cherry-pick <task-branch>..<slice-branch>
git diff <slice-branch> -- <its Owned paths> <any outside paths it listed>
```

Require an empty path diff and deciding-check evidence covering the integrated result before cleanup.
Remove only the clean worktree. Cherry-picking leaves the source branch outside target ancestry, so
`git branch -D <slice-branch>` is allowed only after those integration checks. Never discard unlanded
work or use force to hide a dirty checkout.

## Unit size and partial returns

A capped slice returns partial when unfinished. The orchestrator reads landed commits/diff, check evidence,
proven and remaining criteria. Permit one fresh unit with those facts — not a `SendMessage`
continuation, which resumes the large context the cap stopped and pays for it on every turn. After a
second partial, finish directly or split the remainder into independently verifiable slices.
Coordinate ownership, preserve the acceptance criteria and validate updated dependencies before dispatch.
Escalate only a scope decision or a concrete external blocker. Record the consumed retry beneath the slice:

```text
Partial: <unit> at maxTurns; landed <commits>; redispatched once
```

The plan parser ignores this line; it preserves the retry decision across resume. A partial return
is not completion.

## Method placement

| Method | Workspace |
|---|---|
| domain-modeling | task branch; its saved design artifacts are committed |
| prototype | disposable branch/worktree for the experiment |
| diagnosing-bugs, reading | task branch |
| diagnosing-bugs, probe edits | disposable workspace |
| code-review, deep-review | immutable candidate SHA |

Spec creates the task branch before a method writes design artifacts.
