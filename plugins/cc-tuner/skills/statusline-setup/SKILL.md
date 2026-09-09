---
description: Install, update, or remove the cc-tuner usage statusline (rate-limit 5h/7d + context % + git) in the user's Claude Code settings. Now the statusline node of /cc-tuner:setup; this entry point forwards for one release.
disable-model-invocation: true
---

# /cc-tuner:statusline-setup

This command is the **statusline node** of `/cc-tuner:setup`, kept as a separate entry point for one
release so existing habits and docs keep working. It runs the same guarded `settings.json` patch
with the same backup and the same restart note; it does not keep a workflow of its own.

Parse `$ARGUMENTS`: `install` or `update` (the default) → run the node as
`/cc-tuner:setup install statusline`; `status` → `/cc-tuner:setup check statusline`; `remove` →
the **remove** section of the node's reference, which `/cc-tuner:setup` itself never runs.

The procedure lives in [../setup/references/statusline.md](../setup/references/statusline.md).
Read it and execute the section for the mode above. Report the node's row exactly as
`/cc-tuner:setup` would.

This entry point is removed in the release after next; the node stays.
