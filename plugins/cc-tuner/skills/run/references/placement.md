# Where the work happens

`/cc-tuner:run` owns the plan, integration, acceptance, aggregate review and delivery decisions.
A unit receives one bounded implementation job and returns evidence; it does not own a PR or issue.

## Parallelism, only where it is safe

Delegate when saved context or independent work justifies the brief and verification cost. One
unit may work sequentially in the task checkout. Concurrent writers require independent slices,
disjoint Owned paths and separate worktrees. Use the batch from `plan-lint.sh ready-batches --active`;
do not recalculate ownership from prose or substitute `frontier`.

The concurrency cap counts running units plus proposed starts, not just a returned batch. Respect
available host slots; on build-heavy repositories keep at most two implementation units active.
Heavy checks — full build, full suite, e2e, container start — run through `scripts/heavy.sh`, whose
slots are shared by every session on the machine, so parallel units and parallel sessions queue
instead of exhausting memory together. Focused checks are part of implementation and run directly.
Candidate acceptance and delivery remain sequential.

Independent read-only review is the exception to sequential review: its own skill defines the
reviewers and packets, while one owner aggregates. `deep-review` owns its agent availability and
coverage refusals. Model/cost anecdotes are in [case studies](../../task-flow/references/case-studies.md),
not dispatch thresholds. Estimate the actual model/effort and input/output cost before paid fan-out.

## Brief and return

Build the brief from committed files: repository/worktree, candidate starting SHA, spec path with
an instruction to read it, the slice verbatim (title, Owned paths, deciding check, delivery, criteria),
any shared-task prerequisites, and whether other units run beside it. Tell the unit to:

- load applicable repository rules and write within Owned paths. A unit working alone may make a
  mechanical consequence outside them (lockfile, i18n catalog, generated types, a re-export) and list
  it in the return. A unit running beside others returns that change instead of making it — the
  batch proved only Owned paths disjoint — and the owner applies it once after integration. Anything
  else outside Owned paths is returned as a need;
- prove the expected RED or approved non-code baseline and return commands and deciding output;
- commit after every green step, so a stop at the turn cap leaves committed work;
- run the slice's targeted checks — one browser or API regression test when that is the deciding
  check — not the full suite or the e2e suite; anything heavy goes through `heavy.sh`; never decide
  integrated acceptance;
- avoid further implementation delegation; a bounded lookup is permitted;
- commit under repository conventions, but never push, open/comment on PRs, merge, create issues
  or claim approval;
- report incomplete criteria, assumptions and blockers to the owner.

The owner reads the diff, verifies paths and actual check inputs/output, and integrates commits into
one candidate per repository. Reuse evidence only when it still covers the assembled result; rerun
affected checks otherwise. Shared-task readiness is checked across the whole candidate set.

## Agent selection

Use `cc-tuner:slice-unit` for implementation. Its definition supplies sonnet, `effort: high` and
`maxTurns: 300`.
If unavailable, do the slice as owner; do not substitute an uncapped worker. Use Explore for location
search, not exhaustive auditing, and a suitable general-purpose reader for other bounded questions.
Review lenses use their own restricted definition, without an unrestricted fallback.

A subagent's model is the dispatch's `model` parameter, else its definition's, else
`CLAUDE_CODE_SUBAGENT_MODEL` when set, else the session's;
effort is its definition's, else the session's, and a dispatch cannot set it. A brief configures
neither. The ladder:

- **Units and lenses: Sonnet** at `effort: high`, from their definitions — whatever the session
  runs on, so a Fable or `max` orchestrator does not multiply every unit's cost.
- **Opus when the slice needs it** (`model: "opus"`), chosen by the orchestrator without asking:
  a slice that is genuinely hard from the start, or a retry after the same deciding check failed
  twice, with the failure evidence in the brief. Say which slice ran on Opus and why in the run log.
  After an Opus attempt fails, the orchestrator takes the slice.
- **Fable only for the orchestrator.** A unit or reader on Fable needs the user's explicit decision.
- **Readers name their model.** Pass `model: "sonnet"` to a `general-purpose` reader; use `Explore`
  for location search.

The orchestrator keeps the session's model and effort for its own decisions.

Track handles and completions. Multiple spawns can be in flight even when sent in separate messages;
wait for a slot before adding work. Do not claim prompt-prefix cache savings without evidence from
the current host. The setup spawn-depth setting limits nesting layers; the brief limits which work
may be handed down within those layers.

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
Remove only the clean worktree. Cherry-picking can leave the source branch outside target ancestry;
`git branch -D <slice-branch>` is allowed only after those integration checks. Never discard unlanded
work or use force to hide a dirty checkout.

## Unit size and partial returns

A capped slice returns partial when unfinished. The owner reads landed commits/diff, check evidence,
proven and remaining criteria. Permit one fresh unit with those facts — not a `SendMessage`
continuation, which resumes the 300k–600k-token context the cap stopped and pays for it on every
turn; after a second partial, the owner finishes or reports the concrete blocker. A slice that
reaches the cap twice was too large: split what remains in the plan rather than feeding it again. Record the consumed retry beneath the slice:

```text
Partial: <unit> at maxTurns; landed <commits>; redispatched once
```

The plan parser ignores this line; it preserves the retry decision across resume. A partial return
is not completion and does not reset the slice's failed-check escalation history.

## Method placement

| Method | Workspace |
|---|---|
| research, domain-modeling | task branch; their saved design artifacts are committed |
| prototype | disposable branch/worktree for the experiment |
| tdd | task branch around the slice's deciding check |
| diagnosing-bugs, reading | task branch |
| diagnosing-bugs, probe edits | disposable workspace |
| code-review, deep-review | immutable candidate SHA |

Spec creates the task branch before a method writes design artifacts. Keep load-bearing facts in
the brief even when a host can inherit session context; return evidence as files/commits or a concise
result the owner can verify.
