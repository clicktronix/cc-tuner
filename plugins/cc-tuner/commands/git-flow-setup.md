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

**Shell state does not persist between Bash calls.** Claude Code keeps the
working directory but NOT shell variables across separate Bash invocations —
and the confirmation prompts in branches 3/4 below guarantee the flow splits
into separate calls. Re-run the **Locate** and **Detect/render** blocks at the
start of every Bash invocation that references `$SRC` / `$ROOT` / `$DEST` /
`$LOCAL` / `$PLANS_ROOT` / `$RENDERED`: they are read-only and idempotent, so
re-running them is always safe and never optional after a prompt.

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
RENDERED=$(sed "s|{{PLANS_ROOT}}|$PLANS_ROOT|g" "$SRC") || { echo "ERROR: failed to render template"; exit 1; }
[ -n "$RENDERED" ] || { echo "ERROR: rendered template is empty — aborting"; exit 1; }
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

1. **No existing file** → write it fail-closed and atomically (same-dir tmp →
   `mv`, the statusline-setup pattern) — success is claimed only after every
   step actually succeeded:
   ```bash
   mkdir -p "$ROOT/.claude/rules" || { echo "ERROR: cannot create $ROOT/.claude/rules"; exit 1; }
   TMP=$(mktemp "$ROOT/.claude/rules/.git-flow.XXXXXX") || { echo "ERROR: mktemp failed"; exit 1; }
   if printf '%s\n' "$RENDERED" > "$TMP" && [ -s "$TMP" ] && mv "$TMP" "$DEST"; then
     echo "Installed $DEST (plans root: $PLANS_ROOT)"
   else
     rm -f "$TMP"; echo "ERROR: failed to write $DEST"; exit 1
   fi
   ```
2. **Existing file, content identical to `$RENDERED`** → report "up to date"
   and **skip only the destination write** — still run steps 5–7 below (a
   clone that committed the canonical file but git-ignored the deltas file
   would otherwise never get `git-flow.local.md` or the legacy cleanup).
3. **Existing file with our marker** (first line contains `cc-tuner:git-flow`)
   but different content → show `diff "$DEST" <(printf '%s\n' "$RENDERED")` to
   the user. Hand-edits would be lost — they belong in `git-flow.local.md`.
   Ask before overwriting (AskUserQuestion: overwrite / keep). On **overwrite**,
   write via the same guarded tmp+`mv` writer as branch 1 and suggest moving
   any local edits visible in the diff into `$LOCAL`. On **keep**, report
   "kept existing file — not updated" and stop (terminal state; no other
   changes made).
4. **Existing file WITHOUT our marker** — a legacy hand-maintained copy (the
   11 pre-plugin copies across marqa/stokli). Show the diff, say this replaces
   the legacy copy with the canonical versioned one, and ask before
   overwriting — same overwrite/keep semantics as branch 3 (guarded writer /
   terminal "kept" state). Never overwrite a legacy file silently.
5. **Deltas file** — if `$LOCAL` does not exist, create it (plain `if`, not
   `|| ... &&` — that chain would echo "Created" even when the file already
   exists, because `(a || b) && c` runs `c` on the short-circuit path too):
   ```bash
   if [ ! -f "$LOCAL" ]; then
     if printf '%s\n' \
       "# git-flow — repo-specific deltas" \
       "" \
       "<!-- Overrides and additions to git-flow.md live here; /cc-tuner:git-flow-setup never touches this file." \
       "     Typical content: board name/number + cached field IDs, label taxonomy, merge-policy exceptions. -->" \
       > "$LOCAL"; then
       echo "Created $LOCAL (edit it for repo-specific deltas)"
     else
       rm -f "$LOCAL"; echo "ERROR: failed to write $LOCAL"; exit 1
     fi
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
- [ ] Re-running the command reports "up to date" and writes nothing to `$DEST`
      (it may still create a missing `$LOCAL` — that is by design, branch 2).
- [ ] A failed render/mkdir/write reports ERROR and exits non-zero — no
      success message is ever printed for an operation that did not happen.
