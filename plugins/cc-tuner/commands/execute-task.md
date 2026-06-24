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
   If it reports "config created", STOP and ask the user to fill `.claude/execute-task.md`, then re-run. Otherwise **Read** `.claude/execute-task.md` — those values drive every step below.
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

1. **Intake + DoR/DoD.** Fetch the issue per `tracker`. If anything is unclear, invoke `superpowers:brainstorming`. Write DoR/DoD with acceptance criteria, each tagged `[machine]` or `[eyes]`. `🚦` always (this is the point of `brainstorm-only`).
2. **Plan.** `superpowers:writing-plans`, then stress-test via cc-codex-triage `/plan` to APPROVE. Validate each objection; refute wrong ones with file:line. `🚦` in supervised; autonomous otherwise.
3. **Implement.** `superpowers:subagent-driven-development`. If units are independent, fan out with a Workflow (worktree isolation for parallel file edits).
4. **3.5 — cheap gate.** Run the config's `cheap_gate` (types/lint/unit). Red → fix before going further (hard-stop in every mode).
5. **4 — smoke / acceptance.** Run `test` per the acceptance criteria. `[machine]` criteria you verify with chrome-devtools / `verify`; `[eyes]` criteria are a hard-stop (see below). **`🚦` in supervised AND checkpoints** (UI acceptance is a checkpoints stop).
6. **5 — code-review.** Run `/code-review` (xhigh), validate findings, fix the neighborhood.
7. **6 — peer review (conditional).** Run `superpowers:requesting-code-review` only when the config's `review_passes` risk rules fire (diff touches auth / migrations / public API, or > 20 files — use the threshold set in `review_passes`). Else skip and journal why.
8. **7 — Codex review.** cc-codex-triage `/review` to APPROVE; validate objections. `🚦` in supervised.
9. **7.5 — re-verify.** If the fixes in 5–7 touched FE/behaviour, re-run the relevant smoke from step 4.
10. **8 — reconcile.** Tick off plan + DoD items; journal what shipped vs deferred.
11. **9a — CI.** Run `ci` (trigger if manual). Red → hard-stop.
12. **9b — CD (if `cd` set).** Before running `cd`, do the **full outward-facing preflight** (same bar as merge): run the guard, show the exact commit/diff, **classify the side effect** (deploy / publish / data migration), state the **rollback path**, and journal all of it.
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/guard-artifacts.sh"
    ```
    Exit 3 → unstage the operational artifacts. CD is an outward-facing **hard-stop** in every mode — autonomy never runs it unattended.
13. **10 — merge.** Run the guard again, show the exact commit/diff + rollback path, then merge per `merge`. Default: stop for confirmation even in `brainstorm-only`; only `merge: auto` waives that.

## Hard-stops (what autonomy can NEVER waive)

Whatever the mode, STOP and involve the human for: a failed prereq (0); a dirty tree at preflight (0.7); a red cheap-gate (3.5) or CI (9a); an unmet `[eyes]` acceptance criterion (4/7.5) — `merge: auto` does NOT override it, only an explicit `allow_unverified_manual: true` does; any outward-facing side effect — CD (9b) and merge (10); and any fork you cannot resolve from the code yourself (ask — autonomy ≠ guess). `merge: auto` is the single exception, and it only waives the routine merge confirm.

## Artifact hygiene

All local-only operational artifacts live under `.claude/execute-task-runs/<run-id>/` — the journal **and** any screenshots / raw test+CI logs (write them there, e.g. `.claude/execute-task-runs/<run-id>/smoke.png`). Preflight git-ignores that single directory, so every class is covered at once. Never `git add -A`; the guard refuses to proceed if any are staged and shows untracked files in the final diff. The project config and any plan/spec files ARE committable. The config's optional `artifacts` field may redirect/extend this — honor it if set.
