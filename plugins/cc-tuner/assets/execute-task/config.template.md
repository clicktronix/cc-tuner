# execute-task config

Per-project settings for `/cc-tuner:execute-task`. The agent reads this file
directly. Fill in the commands for THIS repo; leave a field blank if N/A.

- **test**: how to run the full test/smoke suite (incl. UI, e.g. `manual: open http://localhost:3000`)
- **cheap_gate**: fast gate for step 3.5 — types/lint/unit only (e.g. `npm run typecheck && npm run lint`)
- **ci**: CI/checks command; whether manual and how to trigger (e.g. `gh workflow run ci.yml`)
- **cd**: deploy/publish/migrate command (outward-facing, step 9b). Blank = none.
- **branch**: branch policy — create a feature branch? name pattern? require a clean tree? (default: create `task/<id>`, require clean)
- **merge**: squash|merge, target branch, and `auto` (zero-touch) or confirm (default: squash into the default branch, confirm)
- **tracker**: how to fetch the issue — `gh` | `glab` | `none`
- **dor_dod**: DoR/DoD template + acceptance criteria. Mark each criterion `[machine]` (chrome-devtools-checkable) or `[eyes]` (human hard-stop).
- **allow_unverified_manual**: `true` to finish with an unmet `[eyes]` criterion (default `false`; `merge: auto` does NOT override this)
- **review_passes**: which review layers run. Default: code-review + Codex always; requesting-code-review when the diff touches auth / migrations / public API, or > 20 files.
- **autonomy**: default mode — `brainstorm-only` | `checkpoints` | `supervised`
