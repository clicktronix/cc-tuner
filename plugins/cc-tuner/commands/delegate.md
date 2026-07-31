---
description: Take a free-form task, decompose it, and run the implementation on cheaper subagent models (sonnet/opus) with main-model planning and verification. Use when the user wants work fanned out economically — "делегируй", "run this on cheaper models", "distribute this task" — without the full execute-task lifecycle.
argument-hint: '<free-form task description>'
disable-model-invocation: true
---

# /cc-tuner:delegate

<!-- No `allowed-tools` restriction on purpose: dispatching needs Agent,
     verification needs Bash/Read/Grep, and hygiene needs git. -->

You (the main, expensive model) do the thinking — decomposition, dispatch
prompts, verification, judgment. Subagents do the typing on the cheapest
model that fits each unit. This is the economical middle ground between
doing everything yourself and the full `/cc-tuner:run` lifecycle:
no gates, no journal, no board — just tiered fan-out with verification.

## Steps

1. **Context.** If `.claude/execute-task.md` exists (the run config), Read it — reuse its
   `cheap_gate` and `test` commands. Otherwise derive a cheap gate from the
   repo (e.g. `package.json` scripts, `pyproject.toml` tooling) and say which
   you'll use. If the task in `$ARGUMENTS` is genuinely ambiguous about WHAT
   to build (not how), ask once before decomposing.

2. **Decompose.** Split the task into units, each with: files in scope, a
   named sibling/convention to copy, acceptance criteria checkable from the
   unit itself, and what NOT to touch. Mark which units are independent
   (parallelizable) and which chain. Show the user the unit list with tiers
   before dispatching — one compact table, no gate, then proceed.

3. **Classify each unit** per `${CLAUDE_PLUGIN_ROOT}/assets/delegate/tiering.md`
   (Read it): mechanical → `sonnet`, standard → `opus`,
   architectural/sensitive → keep on the main model (usually: do it
   yourself). When unsure, the higher tier. Planning, verification, review,
   and anything user-facing are never delegated.

4. **Dispatch.** Independent units go out in ONE message (parallel Agent
   calls) with the tier's `model` parameter; units that edit files in
   parallel get worktree isolation. Each prompt is self-contained per
   tiering.md's dispatch-prompt requirements.

5. **Verify every unit** per tiering.md's verification contract: read the
   full diff, run the cheap gate, check the acceptance criteria. Failure →
   one redispatch with file:line feedback; second failure → escalate one
   tier. If the change is behavioral/frontend, exercise it for real (the
   smoke-verify bar: render/run, don't just typecheck) before calling it done.

6. **Hygiene + report.** Never `git add -A`; stage surgically; commit/push
   only if the user asked. Report per unit: tier and model used, verification
   outcome, escalations, and anything left unverified — stated plainly.

## Hard limits

- Outward-facing actions (deploy, publish, merge, anything leaving the
  machine) are never delegated and never run without the user's say-so.
- Sensitive surfaces (tiering.md list) never run below the main model, even
  if the diff looks trivial.
- A subagent's claim of success is not evidence — only your own verification
  (step 5) is.
