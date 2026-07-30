---
description: Install or update the canonical .claude/rules/task-flow.md in the current repo from the cc-tuner template (detects wiki/ vs docs/ plans root, preserves task-flow.local.md deltas, offers legacy cleanup).
---

# /cc-tuner:task-flow-setup

Claude Code plugins **cannot ship `.claude/rules/*`** — rules are not a plugin
component. This command installs the canonical task-flow rule from the plugin's
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
SRC="${CLAUDE_PLUGIN_ROOT:-}/assets/task-flow/rule.template.md"
if [ ! -f "$SRC" ]; then
  SRC=$(find "$HOME/.claude/plugins" -path '*/cc-tuner/assets/task-flow/rule.template.md' 2>/dev/null | sort | tail -1)
fi
[ -f "$SRC" ] || { echo "Could not locate rule.template.md — is cc-tuner installed?"; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository"; exit 1; }
DEST="$ROOT/.claude/rules/task-flow.md"
LOCAL="$ROOT/.claude/rules/task-flow.local.md"
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
`/cc-tuner:task-flow-setup` to update the paths."

## status

- No `$DEST` → report "not installed".
- `$DEST` exists → print its first line (the marker). If the file content equals
  `$RENDERED` → "up to date". Differs → "outdated or locally modified — run
  `/cc-tuner:task-flow-setup update`" and show `diff` output. Also report whether
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
   TMP=$(mktemp "$ROOT/.claude/rules/.task-flow.XXXXXX") || { echo "ERROR: mktemp failed"; exit 1; }
   if printf '%s\n' "$RENDERED" > "$TMP" && [ -s "$TMP" ] && mv "$TMP" "$DEST"; then
     echo "Installed $DEST (plans root: $PLANS_ROOT)"
   else
     rm -f "$TMP"; echo "ERROR: failed to write $DEST"; exit 1
   fi
   ```
2. **Existing file, content identical to `$RENDERED`** → report "up to date"
   and **skip only the destination write** — still run steps 5–7 below (a
   clone that committed the canonical file but git-ignored the deltas file
   would otherwise never get `task-flow.local.md` or the legacy cleanup).
3. **Existing file with our marker** (first line contains `cc-tuner:task-flow`)
   but different content → show `diff "$DEST" <(printf '%s\n' "$RENDERED")` to
   the user. Hand-edits would be lost — they belong in `task-flow.local.md`.
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
       "# task-flow — repo-specific deltas" \
       "" \
       "<!-- Overrides and additions to task-flow.md live here; /cc-tuner:task-flow-setup never touches this file." \
       "     Typical content: board name/number + cached field IDs, label taxonomy, merge-policy exceptions. -->" \
       > "$LOCAL"; then
       echo "Created $LOCAL (edit it for repo-specific deltas)"
     else
       rm -f "$LOCAL"; echo "ERROR: failed to write $LOCAL"; exit 1
     fi
   fi
   ```
6. **Migrate from the `git-flow` name** — this rule shipped as `git-flow.md`
   through v0.6.0. Run this BEFORE step 1 writes `$DEST`, so a repo on the old
   name keeps its deltas instead of silently starting from an empty local file:
   ```bash
   OLD="$ROOT/.claude/rules/git-flow.md"
   OLD_LOCAL="$ROOT/.claude/rules/git-flow.local.md"
   if [ -f "$OLD_LOCAL" ] && [ ! -f "$LOCAL" ]; then
     git -C "$ROOT" mv "$OLD_LOCAL" "$LOCAL" 2>/dev/null || mv "$OLD_LOCAL" "$LOCAL"
     echo "Migrated git-flow.local.md -> task-flow.local.md (your deltas, including cached board field IDs)"
   fi
   if [ -f "$OLD" ]; then
     git -C "$ROOT" rm -q "$OLD" 2>/dev/null || rm -f "$OLD"
     echo "Removed the superseded git-flow.md (its invariants are now in task-flow.md)"
   fi
   ```
   The local file is moved, never regenerated: it holds the cached board field
   IDs, and losing them is the friction that makes agents skip the board.
   `$OLD` is removed rather than kept, because two rule files both claiming to
   govern branches is worse than either one alone.
7. **Legacy cleanup** — if `$ROOT/.claude/rules/no-tiny-doc-prs.md` exists, tell
   the user that policy is now a case study in the `cc-tuner:task-flow` skill
   rather than a rule, and ask whether to delete it. Never delete without
   confirmation.
8. Remind: the rule carries invariants only (no hooks, by design). Procedures —
   epics, board recipes, post-merge cleanup, release notes — live in the
   `cc-tuner:task-flow` skill.

## Verification

- [ ] `$DEST` starts with the `cc-tuner:task-flow` marker line.
- [ ] `grep '{{PLANS_ROOT}}' "$DEST"` finds nothing (token substituted).
- [ ] Re-running the command reports "up to date" and writes nothing to `$DEST`
      (it may still create a missing `$LOCAL` — that is by design, branch 2).
- [ ] A failed render/mkdir/write reports ERROR and exits non-zero — no
      success message is ever printed for an operation that did not happen.
- [ ] In a repo that had `git-flow.md`: it is gone, `task-flow.md` is present,
      and any `git-flow.local.md` survived as `task-flow.local.md` with its
      cached board field IDs intact.
