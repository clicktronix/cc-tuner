---
description: Install or update the canonical .claude/rules/git-flow.md in the current repo from the cc-tuner template (detects wiki/ vs docs/ plans root, preserves git-flow.local.md deltas, offers legacy cleanup).
---

# /cc-tuner:git-flow-setup

Claude Code plugins **cannot ship `.claude/rules/*`** — rules are not a plugin
component. This command installs the canonical git-flow rule from the plugin's
template into the current repository, the same way `/cc-tuner:statusline-setup`
installs the statusline.

Parse `$ARGUMENTS`: first token is `install` (default if empty), `update`
(alias of install — the flow is identical and idempotent), or `status`.

## Locate the template and the repo

```bash
SRC="${CLAUDE_PLUGIN_ROOT:-}/assets/git-flow/rule.template.md"
if [ ! -f "$SRC" ]; then
  SRC=$(find "$HOME/.claude/plugins" -path '*/cc-tuner/assets/git-flow/rule.template.md' 2>/dev/null | sort | tail -1)
fi
[ -f "$SRC" ] || { echo "Could not locate rule.template.md — is cc-tuner installed?"; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository"; exit 1; }
DEST="$ROOT/.claude/rules/git-flow.md"
LOCAL="$ROOT/.claude/rules/git-flow.local.md"
```

## Detect the plans root and render the template

`wiki/` directory exists at the repo root → plans root is `wiki`; otherwise `docs`.

```bash
if [ -d "$ROOT/wiki" ]; then PLANS_ROOT="wiki"; else PLANS_ROOT="docs"; fi
RENDERED=$(sed "s|{{PLANS_ROOT}}|$PLANS_ROOT|g" "$SRC")
```

When `PLANS_ROOT` is `docs`, tell the user after installing: "plans root is
`docs/` — when this repo migrates human docs to `wiki/`, re-run
`/cc-tuner:git-flow-setup` to update the paths."

## status

- No `$DEST` → report "not installed".
- `$DEST` exists → print its first line (the marker). If the file content equals
  `$RENDERED` → "up to date". Differs → "outdated or locally modified — run
  `/cc-tuner:git-flow-setup update`" and show `diff` output. Also report whether
  `$LOCAL` exists. Take no other action.
- Note: the marker version is the plugin version at the template's **last
  change** — a newer plugin with an unchanged template still reports "up to
  date" with an older marker. That is expected; comparison is by content, not
  by version number. Do not "fix" the mismatch.

## install / update

1. **No existing file** → write it:
   ```bash
   mkdir -p "$ROOT/.claude/rules"
   printf '%s\n' "$RENDERED" > "$DEST"
   echo "Installed $DEST (plans root: $PLANS_ROOT)"
   ```
2. **Existing file, content identical to `$RENDERED`** → "up to date", stop.
3. **Existing file with our marker** (first line contains `cc-tuner:git-flow`)
   but different content → show `diff "$DEST" <(printf '%s\n' "$RENDERED")` to
   the user. Hand-edits would be lost — they belong in `git-flow.local.md`.
   Ask before overwriting (AskUserQuestion: overwrite / keep). On overwrite,
   suggest moving any local edits visible in the diff into `$LOCAL`.
4. **Existing file WITHOUT our marker** — a legacy hand-maintained copy (the
   11 pre-plugin copies across marqa/stokli). Show the diff, say this replaces
   the legacy copy with the canonical versioned one, and ask before
   overwriting. Never overwrite a legacy file silently.
5. **Deltas file** — if `$LOCAL` does not exist, create it (plain `if`, not
   `|| ... &&` — that chain would echo "Created" even when the file already
   exists, because `(a || b) && c` runs `c` on the short-circuit path too):
   ```bash
   if [ ! -f "$LOCAL" ]; then
     printf '%s\n' \
       "# git-flow — repo-specific deltas" \
       "" \
       "<!-- Overrides and additions to git-flow.md live here; /cc-tuner:git-flow-setup never touches this file." \
       "     Typical content: board name/number + cached field IDs, label taxonomy, merge-policy exceptions. -->" \
       > "$LOCAL"
     echo "Created $LOCAL (edit it for repo-specific deltas)"
   fi
   ```
6. **Legacy cleanup** — if `$ROOT/.claude/rules/no-tiny-doc-prs.md` exists,
   tell the user its policy now lives inside the canonical rule (Pull Requests
   section) and ask whether to delete it. Never delete without confirmation.
7. Remind: the rule is advisory (no hooks, by design), and the procedures live
   in the `cc-tuner:git-flow` skill.

## Verification

- [ ] `$DEST` starts with the `cc-tuner:git-flow` marker line.
- [ ] `grep '{{PLANS_ROOT}}' "$DEST"` finds nothing (token substituted).
- [ ] Re-running the command reports "up to date" and writes nothing.
