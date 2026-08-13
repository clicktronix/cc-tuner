---
description: Install, update, or remove the cc-tuner usage statusline (rate-limit 5h/7d + context % + git) in the user's Claude Code settings.
---

# /cc-tuner:statusline-setup

Claude Code plugins **cannot register a statusline themselves** — only the user's
`settings.json` can. This command bundles the statusline script and wires it into
the user's settings for them.

Parse `$ARGUMENTS`: first token is `install` (default if empty), `update`, `remove`,
or `status`.

## Locate the bundled script

The script ships at `${CLAUDE_PLUGIN_ROOT}/skills/statusline/statusline.sh`. If
`$CLAUDE_PLUGIN_ROOT` is unset for some reason, fall back to a search:

```bash
SRC="${CLAUDE_PLUGIN_ROOT:-}/skills/statusline/statusline.sh"
if [ ! -f "$SRC" ]; then
  SRC=$(find "$HOME/.claude/plugins" -path '*/cc-tuner/skills/statusline/statusline.sh' 2>/dev/null | sort | tail -1)
fi
[ -f "$SRC" ] || { echo "Could not locate statusline.sh — is cc-tuner installed?"; exit 1; }
```

`DEST="$HOME/.claude/cc-tuner-statusline.sh"` — the stable install path the
statusline setting points at (so a plugin update just needs `update`, not a
settings edit).

## install / update

1. **Check dependencies** and warn (don't fail) on anything missing:
   ```bash
   for dep in jq python3 git; do command -v "$dep" >/dev/null || echo "WARNING: '$dep' not found — the statusline needs it"; done
   ```
2. **Copy the script** and make it executable:
   ```bash
   cp "$SRC" "$DEST" && chmod +x "$DEST" && echo "Installed script -> $DEST"
   ```
3. **Patch `~/.claude/settings.json`** (preserve all other keys; back up first). On
   `install`, if a *different* `statusLine` already exists, show it and the backup
   path before overwriting so the user can restore it.
   ```bash
   S="$HOME/.claude/settings.json"
   command -v jq >/dev/null || { echo "ERROR: jq is required to patch settings.json"; exit 1; }
   [ -f "$S" ] || echo '{}' > "$S"
   jq -e . "$S" >/dev/null 2>&1 || { echo "ERROR: $S is not valid JSON — fix it first; not touching it"; exit 1; }
   BACKUP="$S.bak-$(date +%Y%m%d-%H%M%S)"
   cp "$S" "$BACKUP" || { echo "ERROR: could not create backup $BACKUP — aborting"; exit 1; }
   echo "Backed up settings -> $BACKUP"
   existing=$(jq -r '.statusLine.command // empty' "$S")
   [ -n "$existing" ] && echo "Existing statusLine.command: $existing (restore from $BACKUP if you want it back)"
   TMP=$(mktemp "$(dirname "$S")/.cc-tuner-statusline.XXXXXX")   # same dir => mv is atomic
   if jq '.statusLine = {type:"command", command:"bash ~/.claude/cc-tuner-statusline.sh"}' "$S" > "$TMP" && [ -s "$TMP" ] && mv "$TMP" "$S"; then
     echo "settings.json statusLine -> bash ~/.claude/cc-tuner-statusline.sh"
   else
     rm -f "$TMP"; echo "ERROR: failed to patch $S — left unchanged (backup at $BACKUP)"; exit 1
   fi
   ```
4. Tell the user to **restart Claude Code or run `/reload`** for the statusline to take effect.

For `update`, do steps 1–2 only (refresh the copied script); skip the settings patch
if `.statusLine.command` already points at `~/.claude/cc-tuner-statusline.sh`.

## remove

```bash
S="$HOME/.claude/settings.json"
command -v jq >/dev/null || { echo "ERROR: jq is required"; exit 1; }
if [ -f "$S" ]; then
  jq -e . "$S" >/dev/null 2>&1 || { echo "ERROR: $S is not valid JSON — fix it first; not touching it"; exit 1; }
  if [ "$(jq -r '.statusLine.command // empty' "$S")" = "bash ~/.claude/cc-tuner-statusline.sh" ]; then
    BACKUP="$S.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$S" "$BACKUP" || { echo "ERROR: could not create backup $BACKUP — aborting"; exit 1; }
    echo "Backed up settings -> $BACKUP"
    TMP=$(mktemp "$(dirname "$S")/.cc-tuner-statusline.XXXXXX")   # same dir => mv is atomic
    if jq 'del(.statusLine)' "$S" > "$TMP" && [ -s "$TMP" ] && mv "$TMP" "$S"; then
      echo "Removed statusLine from settings.json"
    else
      rm -f "$TMP"; echo "ERROR: failed to edit $S — left unchanged (backup at $BACKUP)"; exit 1
    fi
  else
    echo "settings.json statusLine does not point at cc-tuner — leaving it alone"
  fi
fi
rm -f "$HOME/.claude/cc-tuner-statusline.sh" && echo "Removed $HOME/.claude/cc-tuner-statusline.sh"
```

## status

Report whether `~/.claude/cc-tuner-statusline.sh` exists and what
`jq -r '.statusLine.command' ~/.claude/settings.json` currently is.

## Notes

- The rate-limit (5h/7d) segment uses Claude Code's **unofficial** OAuth usage
  endpoint and may break without notice; it degrades silently if unavailable.
  See the `statusline` skill for the full disclaimer.
- The script reads the OAuth token from the macOS Keychain, or
  `~/.claude/.credentials.json` on Linux/Windows (honoring `$CLAUDE_CONFIG_DIR`).
  It only ever sends that token to `api.anthropic.com`.
