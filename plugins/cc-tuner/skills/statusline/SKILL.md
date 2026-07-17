---
name: statusline
description: Use when the user wants a Claude Code statusline that shows rate-limit usage (5h / 7d windows with reset times), context-window %, git status (branch + staged/modified/untracked counts), model, and session duration — or wants to install, update, or remove the cc-tuner usage statusline.
---

# Usage Statusline

A two-line Claude Code statusline focused on **how much budget is left**:

```
➜ my-project git:(main) S:2 M:1 U:4 | Opus 4.8 xhigh | 1h12m
 | 5h:66%[▓▓▓▓▓░░░]>23:30  7d:9%[▓░░░░░░░]>17:00 | ctx:8%[▓░░░░░░░░░]
```

- **Line 1** — current dir, git branch with `S:`taged / `M:`odified / `U:`ntracked counts (or `✓` when clean), model + reasoning effort (`low`/`medium`/`high`/`xhigh`, shown only when the model exposes it), session duration (rolls over to hours).
- **Line 2** — the 5-hour and 7-day rate-limit windows (utilization %, colored bar, local reset time), then context-window usage. Bars turn green → yellow (≥50%) → red (≥80%).

## Install / update / remove

Claude Code plugins can't register a statusline on their own — it has to live in the
user's `settings.json`. Run the bundled command, which copies the script and wires it
in (with a settings backup):

**To set it up, follow `${CLAUDE_PLUGIN_ROOT}/commands/statusline-setup.md`** —
`/cc-tuner:statusline-setup` (install by default; also `update`, `remove`, `status`).
After install, the user restarts Claude Code or runs `/reload`.

## How the rate-limit data works

The 5h/7d figures come from Claude Code's OAuth usage endpoint
(`api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`), cached for
5 minutes via an atomic `mkdir` lock so concurrent sessions don't stampede the refresh.

> **This is an unofficial / internal endpoint.** Anthropic does not document it and may
> change or remove it without notice. The statusline degrades gracefully — if the
> endpoint, token, or dependencies are unavailable, the rate-limit segment is simply
> dropped and the rest still renders. Mention this caveat to the user when they install.

On HTTP 429 the script honors the server's `retry-after` (clamped 5–60 min, 15 min
when absent) and suspends refresh attempts for that window — the endpoint's throttle
extends on repeated hits, so fixed-interval retries would keep it throttled forever.
The rate-limit segment reappears automatically after the first successful refresh.

The OAuth token is read locally: macOS Keychain (`security find-generic-password -s
'Claude Code-credentials'`), or `~/.claude/.credentials.json` on Linux/Windows (honoring
`$CLAUDE_CONFIG_DIR`). The token is only ever sent to `api.anthropic.com`.

## Requirements

`bash`, `jq`, `python3`, `git`. The statusline JSON fields it reads
(`workspace.current_dir`, `model.display_name`, `effort.level`,
`cost.total_duration_ms`, `context_window.used_percentage`) are all from Claude Code's
documented statusline payload.

## Customizing

Edit the installed copy at `~/.claude/cc-tuner-statusline.sh`:
- **Colors / thresholds** — the `make_bar` helper (green <50, yellow ≥50, red ≥80).
- **Bar length** — second arg to `make_bar` (8 for rate-limit windows, 10 for context).
- **Cache TTL** — `USAGE_CACHE_TTL` (default 300s).
- **Segments** — each section (`git_info`, `model_info`, `duration_info`,
  `usage_info`, `context_info`) is independent; drop any you don't want from the final
  `printf`.

Re-run `/cc-tuner:statusline-setup update` after a plugin upgrade to refresh the copy
(note: that overwrites local edits — keep customizations in a fork of the script).
