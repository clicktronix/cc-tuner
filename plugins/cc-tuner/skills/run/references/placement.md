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
do not recalculate ownership from prose or substitute `frontier`.

The concurrency cap counts running units plus proposed starts, not just a returned batch. Respect
available host slots; on build-heavy repositories keep at most two implementation units active.
Heavy checks queue through machine-wide slots ([below](#heavy-checks)), so parallel units and parallel
sessions do not exhaust memory together. Candidate acceptance and delivery remain sequential.

Independent read-only review is the exception to sequential review: its own skill defines the
reviewers and packets, while one owner aggregates. `deep-review` owns its agent availability and
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
- **The owner runs the full suite**, at the cadence `/run`'s Test cadence names.
- **`verify-feature` runs the e2e suite.**
- **Browser MCP sessions and dev servers belong to the owner and `verify-feature`.** A regression test
  that starts and stops its own server inside its test command is still focused.

Every heavy check, from whoever runs it, goes through the machine's slots:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/heavy.sh" --label "<repo>: <what>" -- <command>
```

The slots are shared by every session on the machine (`CC_TUNER_HEAVY_SLOTS`, default 1), so the call
may wait. Start it as a Bash call with `run_in_background: true`, do other work meanwhile, and read
the output when it exits; the command's own output and exit code pass through unchanged.

## Brief and return

Build the brief from committed files: repository/worktree, candidate starting SHA, spec path with
an instruction to read it, the slice verbatim (title, Owned paths, deciding check, delivery, criteria),
any shared-task prerequisites, and whether other units run beside it. Tell the unit to:

- load applicable repository rules and write within Owned paths. `agents/slice-unit.md` says what a
  unit may do outside them when it works alone and what it returns when others run beside it, so the
  brief only states which case applies; the owner applies a returned out-of-path change once after
  integration;
- prove the expected RED or approved non-code baseline and return commands and deciding output;
- commit after every green step, so a stop at the turn cap leaves committed work;
- run only the checks [Heavy checks](#heavy-checks) gives a unit, through the `heavy.sh` command the
  owner resolved to an absolute path in the brief; never decide integrated acceptance;
- follow the remaining rules in `agents/slice-unit.md` (container cleanup, no further implementation
  delegation, commit per green step, never push, open or comment on PRs, merge, create issues or
  claim approval) and report incomplete criteria, assumptions and blockers to the owner.

The owner reads the diff, verifies paths and actual check inputs/output, and integrates commits into
one candidate per repository. Reuse evidence only when it still covers the assembled result.
Shared-task readiness is checked across the whole candidate set.

## Agent selection

Use `cc-tuner:slice-unit` for implementation. Its definition supplies sonnet, `effort: high` and
the turn cap.
If unavailable, do the slice as owner; do not substitute an uncapped worker. Use Explore for location
search, not exhaustive auditing, and a suitable general-purpose reader for other bounded questions.
Review lenses use their own restricted definition, without an unrestricted fallback.

A brief configures neither model nor effort: pass them as the dispatch's `model` and `effort`
parameters, else the agent definition's, else the session's. The ladder:

- **Units and lenses: Sonnet** at `effort: high`, from their definitions — whatever the session
  runs on, so a Fable or `max` orchestrator does not multiply every unit's cost — except where
  `deep-review`, `/spec` or `/run` name the model of an agent they dispatch.
- **Opus on evidence** for implementation units (`model: "opus", effort: "medium"`), chosen by the
  orchestrator without asking, in two cases only: a retry after the same deciding check failed twice on Sonnet, with that
  failure output in the brief; or a slice the plan marks `Model: opus — <reason>`. Write the reason
  as one line in the brief and beneath the slice in the plan, where `Evidence:` lines go:
  `Opus-reason: <the failed check and its output | the plan's reason>`. Pass the effort explicitly:
  medium is Opus's own API default, and without it the unit's definition would run Opus at high.
  After an Opus attempt fails, the orchestrator takes the slice and runs
  `mattpocock-skills:diagnosing-bugs` on that check before editing: three failed attempts mean the
  cause is not where the briefs looked.
- **Fable only for the orchestrator.** A unit or reader on Fable needs the user's explicit decision.
- **Readers: Haiku** (`model: "haiku", effort: "high"`) for a bounded read-only question with a
  literal answer — locate, extract, list, summarise named files or command output. It decides
  nothing, so the owner checks what it uses. Pass `model: "sonnet", effort: "high"` instead when
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

A capped slice returns partial when unfinished. The owner reads landed commits/diff, check evidence,
proven and remaining criteria. Permit one fresh unit with those facts — not a `SendMessage`
continuation, which resumes the large context the cap stopped and pays for it on every turn. After a
second partial the owner finishes the slice, or reports the concrete blocker. A slice that reached the
cap twice was too large, but splitting what remains changes the approved plan: propose the split to the
user and apply it only on their decision. Record the consumed retry beneath the slice:

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
