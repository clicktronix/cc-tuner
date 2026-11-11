# Node: the statusline

Read this for the statusline node of `/cc-tuner:setup`. Offer it once; install only after the user
agrees. It writes to the active Claude profile. Run after session env and re-read settings before
patching, as [SKILL.md](../SKILL.md#the-nodes) requires.

## Locate the bundled script

Run the **Plugin root** block from [SKILL.md](../SKILL.md#plugin-root), then this block at the start
of each Bash call below:

```bash
SRC="$PLUGIN/skills/statusline/statusline.sh"
[ -f "$SRC" ] || { echo "Could not locate statusline.sh — is cc-tuner installed?"; exit 1; }
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
S="$CONFIG_DIR/settings.json"
DEST="$CONFIG_DIR/cc-tuner-statusline.sh"
command -v jq >/dev/null || { echo "ERROR: jq is required"; exit 1; }
# Quote the path for the shell that executes statusLine.command.
COMMAND="bash $(printf '%s' "$DEST" | jq -Rrs @sh)"
```

## check

Report the script and command in this profile. Write nothing.

```bash
[ ! -f "$DEST" ] || echo "Installed script: $DEST"
if [ -f "$S" ]; then
  jq -r '.statusLine.command // "No statusline command"' "$S"
else
  echo "No settings file: $S"
fi
```

## install

Show a different existing statusline command before replacing it. Preserve other settings and back
up before patching. When the command already matches, refresh only the script.

```bash
for dep in python3 git; do command -v "$dep" >/dev/null || echo "WARNING: '$dep' not found — the statusline needs it"; done
mkdir -p "$CONFIG_DIR" || exit 1
[ -f "$S" ] || printf '{}\n' > "$S" || exit 1
jq -e . "$S" >/dev/null 2>&1 || { echo "ERROR: $S is not valid JSON — left unchanged"; exit 1; }
cp "$SRC" "$DEST" && chmod +x "$DEST" || exit 1
existing=$(jq -r '.statusLine.command // empty' "$S")
if [ "$existing" != "$COMMAND" ]; then
  BACKUP="$S.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$S" "$BACKUP" || { echo "ERROR: backup failed — left settings unchanged"; exit 1; }
  echo "Backed up settings -> $BACKUP"
  TMP=$(mktemp "$CONFIG_DIR/.cc-tuner-statusline.XXXXXX") || exit 1
  if jq --arg command "$COMMAND" '.statusLine = {type:"command", command:$command}' "$S" > "$TMP" && mv "$TMP" "$S"; then
    echo "settings.json statusLine -> $COMMAND"
  else
    rm -f "$TMP"; echo "ERROR: failed to patch $S — restore from $BACKUP if needed"; exit 1
  fi
fi
echo "Installed script -> $DEST"
```

Tell the user to restart Claude Code or run `/reload` for the statusline to take effect.

## remove

Remove the setting only when it points at this profile's cc-tuner script. The old default-profile
command is also recognized; a different command is left alone.

```bash
if [ -f "$S" ]; then
  jq -e . "$S" >/dev/null 2>&1 || { echo "ERROR: $S is not valid JSON — left unchanged"; exit 1; }
  existing=$(jq -r '.statusLine.command // empty' "$S")
  if [ "$existing" = "$COMMAND" ] || { [ "$CONFIG_DIR" = "$HOME/.claude" ] && [ "$existing" = 'bash ~/.claude/cc-tuner-statusline.sh' ]; }; then
    BACKUP="$S.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$S" "$BACKUP" || { echo "ERROR: backup failed — left unchanged"; exit 1; }
    TMP=$(mktemp "$CONFIG_DIR/.cc-tuner-statusline.XXXXXX") || exit 1
    if jq 'del(.statusLine)' "$S" > "$TMP" && mv "$TMP" "$S"; then
      echo "Removed statusLine from $S"
    else
      rm -f "$TMP"; echo "ERROR: failed to patch $S — restore from $BACKUP if needed"; exit 1
    fi
  fi
fi
rm -f "$DEST" && echo "Removed $DEST"
```

Data sources and token handling: [statusline skill](../../statusline/SKILL.md).
