# Run defaults

Optional stable repository defaults for `/cc-tuner:run`. Save a customized copy as
`.claude/execute-task.md`. A committed spec wins where both provide a value.

- **cheap_gate**: fast type/lint/unit command.
- **test**: full regression or behavior-level command.
- **ci**: required hosted checks and how to observe them.
- **merge**: `squash` or `merge`, plus the default target branch.
- **tracker**: `gh` or `none`.
- **board**: project title and owner, or `none`.

Task-specific branch, target, scope, acceptance criteria, waivers, and `auto_ready` belong in the spec.
This file never grants unattended or outward-facing authority.
