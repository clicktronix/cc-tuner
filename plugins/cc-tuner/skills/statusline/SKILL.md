---
name: statusline
description: Use when the user wants to install, update or remove the cc-tuner usage statusline.
---

# Usage statusline

Run the statusline node of `/cc-tuner:setup`: `/cc-tuner:setup install statusline`, or `check
statusline` / `remove statusline`. Plugins cannot register a statusline, so the node copies the
script into the user's profile and patches `settings.json` with a backup.

When it installs, tell the user that rate limits come from Claude Code's own payload, and that a
client which does not send them makes the script fall back to an unofficial OAuth usage endpoint
Anthropic does not document and may change or remove; the rate-limit segment then disappears and the
rest of the line still renders.
