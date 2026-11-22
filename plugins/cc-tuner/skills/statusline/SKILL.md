---
name: statusline
description: Use when the user wants to install, update or remove the cc-tuner usage statusline.
---

# Usage statusline

Run the statusline node of `/cc-tuner:setup`: `/cc-tuner:setup install statusline`, or `check
statusline` / `remove statusline`. Plugins cannot register a statusline, so the node copies the
script into the user's profile and patches `settings.json` with a backup.
