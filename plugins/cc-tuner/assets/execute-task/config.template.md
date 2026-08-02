# run config (repo-level defaults)

Repo-level defaults for `/cc-tuner:run`, so every spec does not have to repeat the same commands. A
spec's own **Run config** block always wins where both specify; this file fills the blanks. Phase 0
reads it. Leave a field out if it does not apply.

Everything about *this task* — acceptance criteria, scope, waivers, whether the run may go `--auto` —
belongs in the spec, not here. This file is only the repo's stable facts.

- **cheap_gate**: the fast gate for phase 2 — types/lint/unit only (e.g. `npm run typecheck && npm run lint`)
- **test**: the full suite for phase 3, including UI (e.g. `npm test`, or `manual: open http://localhost:3000`)
- **ci**: CI/checks command, and how to trigger it if it is manual (e.g. `gh workflow run ci.yml`)
- **cd**: deploy/publish/migrate command. Outward-facing, so `--auto` stops before it in every case. Blank = none.
- **merge**: `squash` | `merge`, and the target branch (default: squash into the default branch)
- **tracker**: how to fetch the issue — `gh` | `glab` | `none`
- **board**: GitHub Project for task cards — title + owner (e.g. `"Dev Board", owner clicktronix`).
  Blank = the board steps are skipped and journaled. Cache field IDs in `.claude/rules/task-flow.local.md`
  per the `cc-tuner:task-flow` skill.
- **effort_tiering**: `on` | `off` (default `on`) — phase 1 picks each implementation unit's reasoning
  effort per `assets/tiering/tiering.md`. Planning, reviews and acceptance judgement always stay on the
  main agent at full effort.
- **small_diff_budget**: the phase-4 review-skip budget (default: ≤ 50 changed lines AND ≤ 5 files).
  The **sensitive-surface list lives in `assets/tiering/tiering.md` and only there** — a second copy is
  a security list that goes quietly out of date. Any sensitive-surface touch runs the full review
  regardless of size, and an unconfirmable size or surface fails closed into running it.

Task-specific `branch`, `target`, `auto_ready`, acceptance criteria, scope, and waivers belong in the
committed spec. Repo defaults must never grant unattended authority.
