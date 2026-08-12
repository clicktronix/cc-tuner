# Native-first lifecycle: delete the machinery the platform already provides

**Date:** 2026-08-13
**Status:** accepted
**Supersedes:** the approach shipped through 0.10.0, in which `/cc-tuner:run` carried its own state
machine, mutation fence and gate protocol.

## Why this rework started

Not from a design review. From a user watching real runs and finding the thing the plugin exists to
produce simply absent.

### What was observed in production

Runs in `marqa` and `stokli` on 2026-08-11/12, with cc-tuner 0.10.0 and cc-codex-triage 0.10.0 both
installed:

- **No visible plan in any run.** Journals and `.meta` existed; no `*.state.json` existed anywhere
  under either project. `preflight.sh` had run, `runctl.sh init` never had — so there were no phases,
  no tasks, no bindings, and every hook gate was inert, because they all `allow` when no active state
  file is found.
- **The cause was version staleness, not a bug in 0.10.0.** Extracting actual `tool_use` Bash calls
  from the session transcripts: in `marqa`, 104 executions of `0.9.0` scripts and **zero** of `0.10.0`;
  in `stokli/frontend`, only `0.9.0/preflight.sh`. `runctl` was never executed at all. The `0.10.0`
  paths that appeared were file *reads*. Sessions started before the 00:49 upgrade kept a frozen
  `${CLAUDE_PLUGIN_ROOT}`.
- **One review round in `stokli/backend`.** `review-feat-334-ssh-deploy` had `rounds=1` and a last
  verdict of `REQUEST_CHANGES` — a stopped loop, not a finished one. Comparable threads in the same
  repo ran 4–12 rounds.
- **No `--required` gate had ever been used.** No `.candidate`, `.review-state` or `.approved` files
  existed in either project; every Codex thread was advisory.

### What the user said

Verbatim, in the order it was said:

> «почему я до сих пор не вижу плана? и в стокли был вызван всего один раунд ревью cc-codex-triage.
> Версии 0.10.0 стоят»

> «а у нас не перебор ограничений и сложности в этих плагинах? я вижу кучу кода на баш скриптах»

> «а что в итоге с упрощением? код выглядит как лапша и не поддерживаемый»

> «"почему я до сих пор не вижу плана" было про вот такой план, я не думаю что для этого нужен миллион
> проверок, просто правильное использование api клод кода (я уже приводил скилы superpower +
> mattpockok как пример)»

> «может быть надо уделить внимание именно скилу по работе с командами а не куче проверок через баш
> скрипты?»

> «может быть ты более детально API изучишь и мы сможем убрать кучу кодовой лапши и баш скриптов и
> ограничиться более узким набором?»

> «mattpocock скилы уже предлагаю много возможностей и проверь насколько мы их используем в нашем
> флоу»

> «ну дублируй в .md файл, плюс я это дублирую в задачу, при закрытии сесси — агент сможет
> восстановить план»

The fourth quote is the pivot. The missing "plan" was never a missing task engine — it was Claude
Code's own task list, which never appeared because `TaskCreate` was never called. Every one of these
turned out to be correct against measurement, including the two that were argued with first.

### What was built in response, and rejected

PR #19 (closed, not merged) answered the missing plan by building a task graph in Bash: `blocked_by` in
run state, schema v2, an atomic `plan import` with cycle and path validation, `plan frontier`, a
`startable` predicate, a new `/cc-tuner:plan`, thirty invariants, every guard mutation-proven. It
reimplemented `addBlockedBy`, and then needed `bind-ui`, a reconciliation pass and a
"visible-plan-is-a-recoverable-projection" invariant purely to keep the reimplementation in sync with
the thing it copied.

A review of it found five blockers, all reproduced by running the flow — including that
`spec → plan → run` could not start at all, and that the prepared plan path was refused by the
branch's own mutation fence. **All 82 assertions were green**, because they were `grep` over markdown.

That is the real defect this ADR is written against: not the graph, but a test suite that could not
observe whether the product worked.

## What was measured

A black-box spike in a disposable repository (`spike-native-flow`), instrumented with hook probes.
Seven of eight questions answered by observation. The full record, including four occasions where a
probe's silence was misread as a result, is reproduced in `docs/spike-native-flow.md`.

### The platform already reports all of this

| fact | source |
|---|---|
| a slash command was invoked, raw and unexpanded | `UserPromptSubmit.prompt`, before any tool call |
| which mode the turn runs in | `permission_mode` — `plan`, `bypassPermissions`, … |
| reasoning effort | `effort.level` |
| the whole turn, correlated | `prompt_id`, identical across the turn's `Pre`/`PostToolUse` |
| a plan was submitted for approval, and its full text | `PreToolUse` on `ExitPlanMode`, `tool_input.plan` |
| what the user chose | `PostToolUse` on `AskUserQuestion`, `tool_input.answers` |
| tasks created, updated, listed | `Pre`/`PostToolUse` on `Task*` |
| the outcome of a call, not only its input | `PostToolUse.tool_response` — `success`, `statusChange` with old and new value |
| why this session started | `SessionStart.source` — `startup` / `compact` / `resume` |

The task graph — rows, statuses and `blockedBy` edges — survives `/compact` and `resume` byte for byte.

### The two limits, also measured

1. **`blockedBy` is data, not a gate.** `TaskUpdate` moves a blocked task to `in_progress` without
   complaint, and the list then renders `[in_progress] … [blocked by #2]`.
2. **Nothing crosses a session boundary.** Tasks live in `~/.claude/tasks/<session_id>/*.json`; a fresh
   session starts with `{"tasks": []}` and no directory of its own.

And one that reframes the whole enforcement story:

3. **Every gate is inert without state.** With no `.claude/execute-task-runs/`, the shipped hook
   returned `rc=0` for both an `Edit` and a `gh pr merge`. The merge guard — the one piece worth
   keeping — fails open exactly like the rest. A design that keeps one fail-closed gate must say what
   *arms* it, or the original defect survives the simplification untouched.

## Decision

### The platform owns

The visible plan, dependency edges, statuses, plan-mode approval, and the hook events above.

### cc-tuner owns

- The `spec → plan → run` split and a Definition of Ready in the spec.
- **The committed Markdown plan as the single readable store** — owned paths, acceptance, deciding
  checks, `Blocked by`, and `- [ ]` progress. Two independent measurements force this: `metadata`
  written through `TaskCreate` cannot be read back, and nothing survives a new session.
- Candidate SHA before review; three reviews bound to that SHA; current-head CI; DoD before merge.
- Method placement — by ordering the branch, not by overriding the skills.

### Deleted

`.claude/execute-task-runs/*.state.json` and the state machine over it; the jq twin of the JSON schema;
the Write/Edit mutation fence and prepared-file hard-link machinery; the manifest resolver for
companion plugins (`claude plugin list --json` returns `scope`, `version`, `installPath`, `projectPath`
and `enabled` directly); the Markdown journal as a second state; generation/reclaim locks; and the
thirty-invariant list, reduced to those with something that reads them at runtime.

### Enforced

One fail-closed gate: **refuse `gh pr merge` unless the PR head equals the reviewed SHA, with three
approvals on it and green CI.** Armed from `UserPromptSubmit`, which was measured to carry the raw
slash text before any tool call. Under `--auto` only, one further check refuses to start a task whose
`blockedBy` is non-empty — because that is the one thing the platform stores but does not enforce, and
nobody is watching.

`gh pr merge` is not the only route to a merge; the web button, `git push` and the API bypass any local
hook. This is a guardrail against an agent's mistake and must not be described as anything stronger.

## Consequences

- The runtime becomes a skill, one merge hook and a setup check. No new language: with no state
  machine there is no controller to port, and what remains reads `git`, `gh` and the plan file.
- **The plan is advisory in attended mode.** With the mutation fence gone, nothing stops an edit before
  a plan exists except the model following its instructions and the user watching. Recorded as a
  decision rather than a side effect: the observed failure was never an agent bypassing the fence, it
  was the fence being inert because state did not exist.
- Recovery is part of the normal flow, not an error path — a fresh session reads the plan and
  re-creates the unticked tasks, keyed off `SessionStart.source == "startup"`.
- `tracker: none` is dropped from `/run`: it was already inconsistent, since `/run` requires a PR and
  GitHub CI unconditionally.

## Complexity budget

- **Runtime** Bash: the merge guard, and under `--auto` the one frontier check. Nothing else.
  Setup-time checks are a separate category with a separate home (`/cc-tuner:setup` doctor).
- One fail-closed gate, and a stated answer for what arms it.
- No more than seven normative invariants, each with something that reads it at runtime.
- **End-to-end scenarios are the primary test.** Phrase-matching assertions may support them, never
  replace them.

## Open

- **§6 of the spike — checkbox progress — is untested.** Whether ticking `- [ ]` plus git history is
  enough to reconstruct state after a lost session is the one thing here resting on judgement.
- A session that has already loaded an older version of a command cannot be repaired by anything
  shipped in a newer one. Only a reload or a cache purge fixes an existing session — which is what
  produced the original symptom, and what no amount of enforcement would have prevented.
