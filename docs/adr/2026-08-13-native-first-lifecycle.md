# Native-first lifecycle: delete the machinery the platform already provides

**Date:** 2026-08-13
**Status:** proposed. The current completion checkpoint lives in Task 8 Step 7 of the branch plan;
the eval README owns its observations and provenance.

The lifecycle has been observed end to end, but not all of it against one current tree. Earlier
`accepted` statuses were withdrawn when review found that the production surface had moved beyond
the recorded eval. `tests/run.sh` refuses `accepted` while the production surface differs from
`EVALUATED_SHA`; scenario samples retain their own historical provenance but no longer force eight
paid model calls after every prose edit. The eval log is the step-by-step source for what was last seen
where, and its evidence is bounded: earlier sessions were driven headless; run 7 supplied the attended
terminal path through merge.

Two design questions are settled. Skill-hook lifetime is no longer load-bearing because `/run`
invokes the checked merge script directly. The checked path requires **one** SHA-bound verdict plus CI,
not three approvals, because GitHub refuses self-approval; reversing that would require three separate
GitHub identities or Apps, contrary to this ADR's simplification goal. See **What the checked path can
actually verify**.
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

3. **Every state-backed gate is inert without state.** With no `.claude/execute-task-runs/`, the
   shipped hook returned `rc=0` for both an `Edit` and a `gh pr merge`. The replacement therefore
   cannot depend on a separate init ritual: `/run` calls the checked delivery script directly.

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

The visible plan, dependency edges, statuses, and the hook events above.

**Amended 2026-08-20: the visible plan is a projection, not the store.** From Claude Code 2.1.233 the
Task tools are off by default on Opus 4.8, Sonnet 5 and later, restored only from outside the session
(`CLAUDE_CODE_ENABLE_TODO_TOOLS=1`, `--allowedTools`, `--tools`). Measured on 2.1.235: an Opus 5
session calling `TaskCreate` answers `UNAVAILABLE` both with and without this plugin loaded. So on a
current model, by default, there is no visible plan at all.

The design survives because the committed Markdown plan was always the durable store and a run drives
from it — three eval sessions produced commits, PRs and a merge with no task list in existence. What
this amendment corrects is the promise: **the committed plan is required, the native task list is an
optional projection of it.** `/cc-tuner:spec` names what is lost when the tools are absent, then
continues to the handoff after the single contract-and-slices approval; it cannot turn them on.

Plan mode is deliberately NOT used. `ExitPlanMode` reads `~/.claude/plans/<name>.md`, a different
document from the plan this flow commits, so wrapping the proposal in it would mean two plan
documents for one plan. `/cc-tuner:spec` asks for approval in conversation before committing both
artifacts instead; the cost — plan
mode physically prevents a write before approval and a conversation does not — is the same one already
recorded under **Consequences**.

### cc-tuner owns

- The `spec → run` flow: `/spec` owns discovery plus the one approved planning decision, and `/run`
  owns delivery. The plan remains an artifact, not a separate command.
- **The committed Markdown plan as the single readable store** — owned paths, acceptance, deciding
  checks, `Blocked by`, and `- [ ]` progress. Two independent measurements force this: `metadata`
  written through `TaskCreate` cannot be read back, and nothing survives a new session.
- Candidate SHA before review; three reviews run against that SHA — one of them checkable by the script,
  the other two mandatory steps of the flow; current-head CI; DoD before merge.
- Method placement — by ordering the branch, not by overriding the skills.

### Deleted

`.claude/execute-task-runs/*.state.json` and the state machine over it; the jq twin of the JSON schema;
the Write/Edit mutation fence and prepared-file hard-link machinery; the hand-rolled parse of
`installed_plugins.json` (`claude plugin list --json` returns `scope`, `version`, `installPath`,
`projectPath` and `enabled` directly, so nothing reads a plugin manifest any more); the Markdown
journal as a second state; generation/reclaim locks; and the
thirty-invariant list, reduced to seven, each of which says plainly whether code enforces it or a
skill merely states it. "Reduced to those with something that reads them at runtime" is how this line
read first, and it was the same overclaim recorded under the complexity budget below: five are
enforced by `merge.sh` and the path resolver, two are instructions in the run skill and nothing more.

### Checked delivery path

The flow has one fail-closed checked path, and it is a **script, not a parser**:
`scripts/merge.sh <pr> <strategy> <sha> [review-thread]`
re-reads the companion's exact-candidate approval, the public verdict, required checks and the head,
and refuses unless the PR head equals the reviewed SHA and every gate agrees at that SHA.

An earlier revision put the checking in the hook, reading the agent's Bash command string. That failed
three rounds running — `bash -c`, `eval`, an absolute path to `gh`, a line continuation, `G=gh; "$G"`,
`$(printf gh)`. A shell command is a program, and a hook reading it as text is guessing. Moving the
checks to a script whose inputs are explicit arguments ends the class; removing the global parser also
stops cc-tuner from intercepting unrelated merges.

**Scope.** The script applies cc-tuner checks exactly when the target pull request's
**net diff** touches a cc-tuner plan file, and none otherwise. The subject is the PR named in the
arguments, never the branch that happens to be checked out. It reads the changed files through the
paginated REST endpoint; `gh pr view --json files` returns only the first 100 GraphQL nodes.

An earlier revision of this ADR specified the PR's commit *history* instead, to close one hole: a run
that commits its plan and then deletes it before merging leaves the net diff and so leaves scope. That
is not what was built, and rather than leave the decision record and the code disagreeing, the record
now describes the code. The reason: history costs one API call per commit on every merge attempt, or
fetch refs written into the user's repository, and it closes an adversarial hole in a tool whose
stated threat model is an agent's mistake — while raw CLI, the web button, `git push` and the REST API
bypass the checked path entirely. The escape is documented beside those routes and asserted in the
scenarios so it cannot be forgotten. Three properties follow:

- Outside a run cc-tuner does not touch the user's ordinary merge commands. Calling `merge.sh`
  explicitly for an out-of-scope PR still gives a head-pinned pass-through path.
- Inside a run the checked path does not go inert the way 0.10.0's did *by accident*. Its scope is
  its evidence: a run exists only if the plan file was committed, and `/spec` commits it before `/run`
  will start. The old failure — run in progress, state file absent, every gate silently allowing —
  has no equivalent, because nothing has to be separately initialised.

  It can still be disarmed *deliberately*, by deleting the plan file before merging, and that is the
  escape recorded above. A pull request whose file list cannot be read at all is a third case and
  refuses: not knowing whether this is a run is not the same as knowing it is not. The distinction is the whole point and is not a quibble: 0.10.0 failed with
  nobody doing anything, this one requires someone removing the thing that says a run is happening.
- Failing to *determine* scope is not the same as being out of scope, and denies.

Earlier drafts armed this from `UserPromptSubmit`. That is dropped: it added a second store answering
a question the branch already answers, which is exactly the duplication this ADR removes elsewhere.

**What the checked path can actually verify, which is less than three approvals.** §8 of the spike measured
this and an earlier draft of this ADR contradicted it. GitHub refuses to let an author approve their
own pull request, and all three of cc-tuner's reviewers act as the PR author — so their reviews come
back `COMMENTED`, never `APPROVED`. "Three approvals" is not a policy choice the user can make; it is
unreachable without three separate GitHub identities or Apps, which is the opposite of simplifying
this plugin.

What survives is weaker and true:

- **One checked required-review result bound to the candidate SHA.** `merge.sh` re-runs
  `cc-codex-triage`'s `review-state.sh check` for the same worktree and thread that `/run` used. This
  distinguishes a completed required-review workflow from a verdict string the subject simply typed.
- **One public verdict record on that SHA.** GitHub binds the review comment to the PR head and author;
  it remains useful traceability, but the author-controlled text is not the required-review proof.
- **Green CI on that same SHA**, which GitHub owns.

The companion state is local and the workflow can still be bypassed or deliberately altered, so this
remains a guardrail rather than an adversarial security boundary. The checked path's claim is narrower:
it refuses unless the required-review state, public record, CI and current PR head agree.

**The flow gains the step that writes the public record.** `cc-codex-triage` owns the exact-candidate
state but does not post a GitHub review, so `/run` publishes each returned verdict on the SHA it
reviewed before changing that candidate. The merge boundary reads the final approval and companion
state instead of asking one to stand in for the other.

**Author review is advisory and each applicable layer runs at most once.** The `mattpocock` review
runs first for every task. After its findings are addressed, deep-review is added only for a sensitive,
cross-boundary or large candidate (15 production files, 500 production lines, or a major architectural
boundary). Claude Code's capped `/code-review` never stacks with a matched deep-review. Later fixes
re-run only the affected checks and the authoritative exact-SHA review; restarting every advisory lens
produced 22 reviewer agents on a small eval fixture without improving the merge boundary.

Under `--auto`, `/run` is instructed to refuse a task whose `blockedBy` is non-empty — the one thing
the platform stores but does not enforce. **This is an instruction, not a gate.** It was described
here as runtime enforcement; it is not, and cannot easily be: nothing outside the session can see
which task the agent picked. Calling it enforcement while it is a paragraph is the overclaim this ADR
exists to remove, so it is named for what it is and counted with the advisory half of the design.

Raw `gh pr merge`, the web button, `git push` and the API all bypass the checked script. This is
workflow discipline against an agent's mistake and must not be described as anything stronger.

## Consequences

- The runtime becomes a skill, one checked merge script, a mutation harness the spec's negative proof
  runs through, and a setup check. `mutate.sh` was added on 2026-08-22 and is the one piece here that
  grew rather than shrank; it is invoked only where a spec assigns a negative proof, which is what
  keeps it off the path of an ordinary slice. No new language: with no state
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

- **Lifecycle** Bash is limited to five pieces: `merge.sh`; spec-driven `mutate.sh`; the
  `SessionStart` restore hook; the plan linter; and the branch→path resolver. Frontier and safe-batch
  selection are modes of the plan linter, already one of the five: `/run` asks which slices may start
  together instead of deriving graph and path overlap by hand. That makes the Markdown-only fallback
  real and keeps parallelism fail-closed without adding another runtime piece.
- The opt-in smoke-verification feature is a separate runtime surface: its registered fail-open
  `Stop` hook, shared fingerprint library, and `mark.sh`. It is inert unless the repository opts in
  with `.claude/smoke-verify.cfg`.
- Setup-time checks are a separate category with a separate home, and now literally so: `scripts/setup/`
  holds `doctor.sh`, `prereq-check.sh` and `plugin-here.sh`. The last exists because "which install
  of a plugin applies here" was answered in two places that had already diverged twice over — doctor
  skipped `enabled: false` and the preflight did not; doctor took the top install and the preflight
  searched them all, which passed a broken `local` install because a complete `user` one sat below
  it. Both callers now run the one program, and it answers with a single install, because a resolver
  that hands back three has not answered the question.
- One checked delivery path, fail-closed whenever it cannot determine whether its target is in scope.
- No more than seven normative invariants. Each says plainly whether code enforces it or a skill
  merely states it, and none may claim a gate it does not have. The earlier wording — "each with
  something that reads it at runtime" — was itself an overclaim: two of the seven are instructions,
  and pretending otherwise is the failure mode this ADR was written against.
- **Use proportional evidence.** Deterministic scripts have product-route tests; skill text has small
  contract checks for load-bearing output and targeted model scenarios only when a repeated
  behavioural failure justifies them. Live eval covers the external lifecycle boundary.

## Open

Nothing here blocks the decision. Each was, at some point, believed to.

- **How long a skill's frontmatter hooks stay active — no longer load-bearing.** An earlier revision
  ranked this first because a merge hook might have been declared there. There is no merge hook in
  this design; `/run` invokes the checked script directly. It is worth measuring one day, but nothing
  waits on it.
- **§6 of the spike — checkbox progress — is untested.** Whether ticking `- [ ]` plus git history is
  enough to reconstruct state after a lost session. This decides how good recovery feels, not whether
  anything is enforced.
- A session that has already loaded an older version of a command cannot be repaired by anything
  shipped in a newer one. Only a reload or a cache purge fixes an existing session — which is what
  produced the original symptom, and what no amount of enforcement would have prevented.
