---
description: Drives a coding task from intake through merge as a guided, gated playbook with a chosen autonomy level. Use when the user wants a whole task or issue taken start-to-finish for them, says "execute this task", "run this ticket end to end", or asks to automate the task lifecycle. Requires the superpowers and cc-codex-triage plugins.
argument-hint: '<issue-ref> [--autonomy brainstorm-only|checkpoints|supervised]'
disable-model-invocation: true
---

# /cc-tuner:execute-task

<!-- No `allowed-tools` restriction on purpose: the playbook needs broad access
     (Bash, Read/Edit/Write, Task, TodoWrite, AskUserQuestion, the Skill tool,
     and chrome-devtools MCP for [machine] acceptance checks). Restricting it
     would silently break gates/autonomy prompts. -->

Walk a task from intake to merge, stopping for the human only at the gates the
chosen autonomy level keeps. You (the main agent) drive every step; you only
fan out to a Workflow on genuine fan-out phases. Validate every review/plan
objection against the code before acting on it — an objection can be wrong.

Design of record: `docs/superpowers/specs/2026-06-21-execute-task-design.md`.

## Step 0 — prereqs + config + autonomy

1. Prereqs:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/prereq-check.sh"
   ```
   Non-zero exit → show its message and STOP (the playbook needs superpowers + cc-codex-triage).
2. Config:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/config-init.sh" "${CLAUDE_PLUGIN_ROOT}/assets/execute-task/config.template.md"
   ```
   On **exit 2** (config freshly created), STOP and ask the user to fill `.claude/execute-task.md`, then re-run. On **exit 0** (config already exists), **Read** `.claude/execute-task.md` — those values drive every step below.
3. Autonomy: take `--autonomy` if passed, else the config's `autonomy:`, else ask once (AskUserQuestion): `brainstorm-only` / `checkpoints` / `supervised`. Which `🚦` gates stay in the human loop:
   - `supervised` — every `🚦`.
   - `checkpoints` — step 1 (brainstorm / DoR-DoD), step 4 (UI acceptance), step 10 (merge).
   - `brainstorm-only` — step 1 only.
   In every mode the **Hard-stops** below still apply — autonomy can't waive those.

## Step 0.7 — preflight

1. Pick a `run-id` (e.g. `<issue>-<short-sha>`). Create the feature branch per the config's `branch` policy (you do this — `git checkout -b <name>`).
2. ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/preflight.sh" <run-id> <target-branch>
   ```
   Exit 2 (dirty tree) → STOP, surface the files, let the user commit/stash. On success it prints the journal path; append to it after each step:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" append <run-id> "<what happened>"
   ```

## Steps 1–10 (the spine)

Record each step's outcome to the journal. `🚦` = a human gate in `supervised`; see Hard-stops for `brainstorm-only`/`checkpoints`.

- **1 — Intake + DoR/DoD.** Fetch the issue per `tracker`. If `tracker` is `gh` and the config's `board` is set, move the issue's card to **In Progress** (recipes: `cc-tuner:git-flow` skill; board not set or card lookup fails → journal and continue, never block intake on the board; if the human rejects the task at this step's gate, move the card back and journal it). If anything is unclear, invoke `superpowers:brainstorming`. Write DoR/DoD with acceptance criteria, each tagged `[machine]` or `[eyes]`. `🚦` always (this is the point of `brainstorm-only`).
- **1.5 — Research (skip if certain).** Gather what you need to plan well: for any library / framework / SDK / API / CLI in scope, pull **current** docs via Context7 MCP (do not rely on memory — versions drift; if Context7 isn't configured, WebFetch the official docs instead); for anything else (unfamiliar domain, error signatures, prior art), use WebSearch / WebFetch. Send only a generic technical query (library name, error text) — never paste proprietary issue/ticket text to an external service. **Skip only when you're certain no doc/web lookup would change the plan** — and journal that you skipped and why. Feeds step 2. Autonomous in every mode (queries external doc/search services but performs no local or outward-facing mutation; no `🚦`).
- **2 — Plan.** `superpowers:writing-plans`, then stress-test via cc-codex-triage `/plan` to APPROVE. Validate each objection; refute wrong ones with file:line. `🚦` in supervised; autonomous otherwise.
- **3 — Implement.** `superpowers:subagent-driven-development`. If units are independent, fan out with a Workflow (worktree isolation for parallel file edits).
- **3.5 — cheap gate.** Run the config's `cheap_gate` (types/lint/unit). Red → fix before going further (hard-stop in every mode).
- **4 — smoke / acceptance.** Exercise real behavior against the DoR/DoD acceptance criteria from step 1 — not just the unit run. Run the config's `test` (full smoke: backend behavior scripts and/or UI). Verify each `[machine]` criterion by actually driving it — UI flows via chrome-devtools MCP (navigate / click / screenshot), backend behavior via the `test` scripts. `[eyes]` criteria are a human hard-stop (see below). **`🚦` in supervised AND checkpoints** (UI acceptance is a checkpoints stop).
- **5 — code-review.** Skip when the diff is **small and non-sensitive** — within `review_passes`'s small-diff budget (default ≤ 50 changed lines (added + removed) AND ≤ 5 files) AND it touches **none** of the sensitive surfaces: auth / secrets / crypto, DB migrations or destructive data ops (DELETE / DROP / rm), public API, money / payments / pricing, infra / CI / deploy config, security-relevant input handling (injection / SSRF / path-traversal guards, server-side allowlists — not ordinary client-side form validation). Journal why, and let Codex `/review` (step 7) be the review layer. **Fail closed: if you cannot compute the diff size, or are unsure whether a surface is sensitive, do NOT skip — run `/code-review` (xhigh) and journal why** (skip needs positive confirmation of both). Any sensitive-surface touch, or any non-small diff, runs `/code-review` (xhigh); validate findings, fix the neighborhood.
- **6 — peer review (conditional).** Run `superpowers:requesting-code-review` only when the config's `review_passes` risk rules fire (diff touches auth / migrations / public API, or > 20 files — use the threshold set in `review_passes`). Else skip and journal why.
- **7 — Codex review.** cc-codex-triage `/review` to APPROVE; validate objections. `🚦` in supervised.
- **7.5 — re-verify.** If the fixes in 5–7 touched FE/behaviour, re-run the relevant smoke from step 4.
- **8 — reconcile.** Tick off plan + DoD items; journal what shipped vs deferred. If a promoted plan document exists for this task (`wiki/PLANS/` or `docs/PLANS/`) and its work is complete, move it to the matching `ARCHIVE/PLANS/` dir as part of this branch — per the git-flow rule, plan archival rides the PR that completes it, never a standalone doc PR.
- **9a — CI.** Run `ci` (trigger if manual). Red → hard-stop.
- **9b — CD (if `cd` set).** Before running `cd`, do the **full outward-facing preflight** (same bar as merge): run the guard **with the merge target** (so it also rejects run artifacts hiding in branch history that a non-squash merge would publish), show the exact commit/diff, **classify the side effect** (deploy / publish / data migration), state the **rollback path**, and journal all of it.
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/guard-artifacts.sh" <merge-target-branch>
  ```
  Exit 3 → unstage/uncommit the operational artifacts. CD is an outward-facing **hard-stop** in every mode — autonomy never runs it unattended.
- **10 — merge.** Run the guard again with the merge target (`guard-artifacts.sh <merge-target>`), show the exact commit/diff + rollback path, then merge per `merge`. Default: stop for confirmation even in `brainstorm-only`; only `merge: auto` waives that. After a successful merge, when `board` is set: verify the PR carried its issue link (`Closes #N`/`Refs #N`) and move the card to **Done** (recipes: `cc-tuner:git-flow` skill; failures here are journaled, they do not un-merge).

## Hard-stops (what autonomy can NEVER waive)

Whatever the mode, STOP and involve the human for: a failed prereq (0); a dirty tree at preflight (0.7); a red cheap-gate (3.5) or CI (9a); an unmet `[eyes]` acceptance criterion (4/7.5) — `merge: auto` does NOT override it, only an explicit `allow_unverified_manual: true` does; any outward-facing side effect — CD (9b) and merge (10), with one exemption: board card moves (1/10) are journaled and reversible, they never require a stop and never block on failure; and any fork you cannot resolve from the code yourself (ask — autonomy ≠ guess). `merge: auto` is the single exception, and it only waives the routine merge confirm.

## Artifact hygiene

All local-only operational artifacts live under `.claude/execute-task-runs/` — the journal is the flat file `.claude/execute-task-runs/<run-id>.md`, and the run's other artifacts (screenshots / raw test+CI logs) go in the sibling subdir `.claude/execute-task-runs/<run-id>/` (e.g. `.claude/execute-task-runs/<run-id>/smoke.png`). Preflight git-ignores that single top directory, so every class is covered at once. Never `git add -A`; the guard refuses to proceed if any are staged **or already committed** under that dir, and shows untracked files in the final diff. The project config and any plan/spec files ARE committable.
