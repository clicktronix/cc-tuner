---
description: Install or update the canonical .claude/rules/task-flow.md in the current repo from the cc-tuner template (migrates repos off the old git-flow name preserving their cached board field IDs, keeps task-flow.local.md deltas untouched, offers legacy cleanup). Now the task-flow node of /cc-tuner:setup; this entry point forwards for one release.
disable-model-invocation: true
---

# /cc-tuner:task-flow-setup

This command is the **task-flow rule node** of `/cc-tuner:setup`, kept as a separate entry point for
one release so existing habits and docs keep working. It runs the same procedure with the same
idempotency and the same diffs; it does not keep a workflow of its own.

Parse `$ARGUMENTS`: `install` or `update` (the default) → run the node as
`/cc-tuner:setup install task-flow`; `status` → `/cc-tuner:setup check task-flow`.

The procedure — locate, migrate `git-flow.local.md` first, write or diff the rule, create the deltas
file, remove the legacy `git-flow.md` last — lives in
[../setup/references/task-flow-rule.md](../setup/references/task-flow-rule.md). Read it and execute
it with the mode above. Report the node's row exactly as `/cc-tuner:setup` would.

This entry point is removed in the release after next; the node stays.
