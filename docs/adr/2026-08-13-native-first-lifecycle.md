# Native-first lifecycle: delete the machinery the platform already provides

**Date:** 2026-08-13
**Status:** proposed. One measurement gates acceptance — how long a skill's frontmatter hooks stay
active (see **Open**) — and one narrowing needs confirming: the merge gate checks **one** SHA-bound
verdict plus CI, not three approvals, because GitHub makes three unreachable here. See
**What the gate can actually check**.
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

### What the documentation adds, and what it leaves open

Read against the reference docs after the spike. Kept separate from the section above because none of
it was observed here — it constrains the design, it does not report behaviour.

- **A `command` hook cannot create a task.** *"Invoke Claude Code tools — NO. Hooks can only emit
  JSON/text."* It emits `hookSpecificOutput.additionalContext` and nothing more, so recovery cannot be
  performed by the hook — only *asked for*. Stated narrowly on purpose: handler types `agent` and
  `mcp_tool` do reach further (an `agent` handler spawns a subagent that can use tools), but neither
  writes the invoking session's task list, and cc-tuner ships `command` handlers.
- **`SessionStart` matches on more than `startup`** — `startup`, `resume`, `clear`, `compact`, `fork`.
  `/clear` empties the session's tasks exactly as a new session does, so a restore keyed only to
  `startup` has a hole. `superpowers` registers `startup|clear|compact`.
- **`TaskCreate` takes no dependency argument** (`subject`, `description`, `activeForm`, `metadata`).
  Edges exist only through `TaskUpdate.addBlockedBy`, so publishing a plan is inherently two-pass.
  The same reference lists the fields `TaskList` and `TaskGet` return — `metadata` is in neither,
  which is the documented form of what §1 of the spike measured.
- **A skill may declare its own hooks** in frontmatter, *"scoped to the component's lifecycle and only
  run when that component is active."* If an inline skill stays active across turns this removes the
  arming problem outright. **Nothing defines when a non-forked skill finishes**, and the neighbouring
  frontmatter fields are documented to clear "when you send your next message" — so the active window
  may well be one turn, in which case a guard declared this way is inert for a multi-turn run. That is
  the same failure this ADR exists to remove, so it is a measurement, not an assumption. See **Open**.

### Rejected: `disallowed-tools` as the mutation fence

The frontmatter field removes tools from the pool while a skill is active — a native Write/Edit fence
with no Bash at all. It is rejected because the documented lifetime is one message: *"The restriction
clears when you send your next message."* A run spans many turns, so the fence would lapse after the
first one. Recorded here so it is not proposed again.

## Decision

### The platform owns

The visible plan, dependency edges, statuses, plan-mode approval, and the hook events above.

### cc-tuner owns

- The `spec → plan → run` split and a Definition of Ready in the spec.
- **The committed Markdown plan as the single readable store** — owned paths, acceptance, deciding
  checks, `Blocked by`, and `- [ ]` progress. Two independent measurements force this: `metadata`
  written through `TaskCreate` cannot be read back, and nothing survives a new session.
- Candidate SHA before review; three reviews run against that SHA — one of them checkable by the gate,
  the other two mandatory steps of the flow; current-head CI; DoD before merge.
- Method placement — by ordering the branch, not by overriding the skills.

### Deleted

`.claude/execute-task-runs/*.state.json` and the state machine over it; the jq twin of the JSON schema;
the Write/Edit mutation fence and prepared-file hard-link machinery; the manifest resolver for
companion plugins (`claude plugin list --json` returns `scope`, `version`, `installPath`, `projectPath`
and `enabled` directly); the Markdown journal as a second state; generation/reclaim locks; and the
thirty-invariant list, reduced to those with something that reads them at runtime.

### Enforced

One fail-closed gate: **refuse `gh pr merge` unless the PR head equals the reviewed SHA, carries a
verdict review at that SHA, and CI is green on it.**

**Scope, which is also the arming.** The guard has an opinion exactly when the current branch carries
a committed cc-tuner plan file, and none otherwise. Two properties follow, and both are required:

- Outside a run cc-tuner does not touch the user's ordinary merges. A global fail-closed hook that
  denied every `gh pr merge` in every repository the plugin is installed in would be a regression, not
  a guardrail.
- Inside a run the gate cannot go inert the way 0.10.0's did. Its scope condition *is* its evidence:
  a run exists only if the plan file is committed, and `/plan` commits it before `/run` will start. The
  old failure — run in progress, state file absent, every gate allowing — has no equivalent here,
  because the thing that says "a run is happening" is the same thing `git` guarantees is present.

Earlier drafts armed this from `UserPromptSubmit`. That is dropped: it added a second store answering
a question the branch already answers, which is exactly the duplication this ADR removes elsewhere.

**What the gate can actually check, which is less than three approvals.** §8 of the spike measured
this and an earlier draft of this ADR contradicted it. GitHub refuses to let an author approve their
own pull request, and all three of cc-tuner's reviewers act as the PR author — so their reviews come
back `COMMENTED`, never `APPROVED`. "Three approvals" is not a policy choice the user can make; it is
unreachable without three separate GitHub identities or Apps, which is the opposite of simplifying
this plugin.

What survives is weaker and true:

- **One machine-checkable verdict bound to the candidate SHA.** A review exists on the exact head SHA,
  from the expected author, whose body carries the verdict. GitHub stamps the SHA and the plugin
  cannot forge it — a local file claiming "we reviewed X" can be written any time, a review at X can
  only exist if X was head when it was submitted. The SHA binding is external and strong.
- **Green CI on that same SHA**, which GitHub also owns.

The verdict itself travels in review prose the author can edit, so it is a guardrail, not a proof —
the same standing this ADR already gives the merge interception. Saying otherwise would rebuild the
thing being deleted: a gate that reads a record its own subject controls.

**The other two reviews stay mandatory steps of the flow and are not gates.** Deep-review and the
`mattpocock` review run and must be addressed; they simply have no durable, unforgeable home, and
counting them would be counting the author's own word twice.

Under `--auto` only, one further check refuses to start a task whose `blockedBy` is non-empty — because
that is the one thing the platform stores but does not enforce, and nobody is watching.

`gh pr merge` is not the only route to a merge; the web button, `git push` and the API bypass any local
hook. This is a guardrail against an agent's mistake and must not be described as anything stronger.

## Consequences

- The runtime becomes a skill, one merge hook and a setup check. No new language: with no state
  machine there is no controller to port, and what remains reads `git`, `gh` and the plan file.
- **The plan is advisory in attended mode.** With the mutation fence gone, nothing stops an edit before
  a plan exists except the model following its instructions and the user watching. Recorded as a
  decision rather than a side effect: the observed failure was never an agent bypassing the fence, it
  was the fence being inert because state did not exist.
- **Recovery is asked for, not performed.** It is part of the normal flow rather than an error path,
  but a hook cannot call `TaskCreate`: the hook injects the plan file's unticked lines as context and
  the agent re-creates the tasks. So recovery carries exactly the same standing as the plan itself —
  advisory, and dependent on the model following its instructions. Any claim that a session "will"
  restore its tasks is a claim about the model, not about a gate.
- **Recovery runs on `startup` and `clear`, not on `compact`.** §4 measured that the task graph
  survives compaction and resume byte for byte, so asking for a restore there would duplicate every
  row. The instruction is written to be idempotent regardless — read `TaskList` first, create only what
  is missing — because a rule that depends on the trigger being exactly right is one trigger change
  away from silently doubling the plan.
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

In priority order, by what each one decides.

- **How long a skill's frontmatter hooks stay active.** This decides whether the single fail-closed
  gate needs an arming file at all — and, if the active window is one turn, whether a guard declared
  that way fires during a run or is inert. It is the only open item that can leave the merge guard
  silently not working, which is the defect this ADR is written against. Measure first, in a
  disposable repository, the same way the rest of this was measured.
- **§6 of the spike — checkbox progress — is untested.** Whether ticking `- [ ]` plus git history is
  enough to reconstruct state after a lost session. This decides how good recovery feels, not whether
  anything is enforced, so it ranks below the item above.
- A session that has already loaded an older version of a command cannot be repaired by anything
  shipped in a newer one. Only a reload or a cache purge fixes an existing session — which is what
  produced the original symptom, and what no amount of enforcement would have prevented.
