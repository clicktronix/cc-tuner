# Run defaults

Optional stable repository defaults for `/cc-tuner:run`. Save a customized copy as
`.claude/execute-task.md`. A committed spec wins where both provide a value.

- **cheap_gate**: fast type/lint/unit command.
- **target_test**: focused regression command for the changed behavior.
- **full_test**: full regression command.
- **static/build checks**: typecheck, lint, build, generated-artifact, or migration commands that are
  stable for this repository; task-specific exceptions stay in the spec.
- **ci**: required hosted checks and how to observe them.
- **merge**: `squash` or `merge`, plus the default target branch.
- **tracker**: `gh` or `none`.
- **board**: project title and owner, or `none`.

Task-specific first-failure proof, branch, target, scope, acceptance criteria, waivers, and
`auto_ready` belong in the spec. This file never grants unattended or outward-facing authority.
