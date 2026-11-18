# Node: the task-flow rule

Procedure for the **task-flow rule** node of `/cc-tuner:setup`. Claude Code plugins cannot ship
`.claude/rules/*`, so the canonical rule is written into the repository from the plugin's template.

Rerun **Locate** at the start of each Bash call; shell variables do not persist between calls.

**Run the steps in the order they are numbered.**

## Contents

- [Locate the template and the repo](#locate-the-template-and-the-repo)
- [check](#check)
- [install](#install)
- [Verification](#verification)

## Locate the template and the repo

Run the **Plugin root** block from [SKILL.md](../SKILL.md#plugin-root) first, in the same Bash call, then:

```bash
SRC="$PLUGIN/assets/task-flow/rule.template.md"
[ -f "$SRC" ] || { echo "Could not locate rule.template.md — is cc-tuner installed?"; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository"; exit 1; }
DEST="$ROOT/.claude/rules/task-flow.md"
LOCAL="$ROOT/.claude/rules/task-flow.local.md"
RENDERED=$(cat "$SRC") || { echo "ERROR: cannot read $SRC"; exit 1; }
[ -n "$RENDERED" ] || { echo "ERROR: template is empty — aborting"; exit 1; }
```

The template carries no substitution tokens; it installs verbatim.

## check

- No `$DEST` → report "not installed".
- `$DEST` exists → print its first line (the marker). If the file content equals `$RENDERED` →
  "up to date". Differs → "outdated or locally modified — run `/cc-tuner:setup install task-flow`"
  and show `diff` output. Also report whether `$LOCAL` exists. Take no other action.
- Compare by content, not by marker version: the marker is the plugin version at the template's last
  change, so an older marker on an unchanged template is expected.

## install

1. **No existing file** → write it fail-closed and atomically (same-dir tmp → `mv`) — success is
   claimed only after every step actually succeeded:
   ```bash
   mkdir -p "$ROOT/.claude/rules" || { echo "ERROR: cannot create $ROOT/.claude/rules"; exit 1; }
   TMP=$(mktemp "$ROOT/.claude/rules/.task-flow.XXXXXX") || { echo "ERROR: mktemp failed"; exit 1; }
   if printf '%s\n' "$RENDERED" > "$TMP" && [ -s "$TMP" ] && mv "$TMP" "$DEST"; then
     echo "Installed $DEST"
   else
     rm -f "$TMP"; echo "ERROR: failed to write $DEST"; exit 1
   fi
   ```
2. **Existing file, content identical to `$RENDERED`** → report "up to date" and **skip only the
   destination write** — still run steps 5–6 below (a clone that committed the canonical file but
   git-ignored the deltas file would otherwise never get `task-flow.local.md`).
3. **Existing file with our marker** (first line contains `cc-tuner:task-flow`) but different
   content → show `diff "$DEST" <(printf '%s\n' "$RENDERED")` to the user. Hand-edits would be lost
   — they belong in `task-flow.local.md`. Ask before overwriting (AskUserQuestion: overwrite /
   keep). On **overwrite**, write via the same guarded tmp+`mv` writer as branch 1 and suggest
   moving any local edits visible in the diff into `$LOCAL`. On **keep**, report "kept existing
   file — not updated" and mark this node kept; the other nodes still run.
4. **Existing file WITHOUT our marker** — a legacy hand-maintained copy of this rule, carried
   between repositories before the plugin existed. Show the diff, say this replaces the legacy copy
   with the canonical versioned one, and ask before overwriting — same overwrite/keep semantics as
   branch 3. Never overwrite a legacy file silently.
5. **Deltas file** — if `$LOCAL` does not exist, create it (plain `if`, not `|| ... &&` — that chain
   would echo "Created" even when the file already exists):
   ```bash
   if [ ! -f "$LOCAL" ]; then
     if { printf '%s\n' "# task-flow — repo-specific deltas" "" &&
          bash "$PLUGIN/scripts/setup/route.sh" header; } > "$LOCAL"; then
       echo "Created $LOCAL (edit it for repo-specific deltas)"
     else
       rm -f "$LOCAL"; echo "ERROR: failed to write $LOCAL"; exit 1
     fi
   fi
   ```
   If the companions node declined `cc-codex-triage` in this run while `$LOCAL` did not yet exist, its
   decision was held for this step: now that the file exists, run the **Record the decline** block of
   [companions.md](companions.md#record-the-decline).
6. If `$ROOT/.claude/rules/no-tiny-doc-prs.md` exists, tell the user that policy is now a case study
   in the `cc-tuner:task-flow` skill rather than a rule, and ask whether to delete it. Never delete
   without confirmation.

## Verification

- [ ] `$DEST` starts with the `cc-tuner:task-flow` marker line and is byte-identical to the
      template.
- [ ] Re-running the node reports "up to date" and writes nothing to `$DEST` (it may still create
      a missing `$LOCAL` — that is by design, branch 2).
- [ ] A failed read/mkdir/write reports ERROR and exits non-zero — no success message is ever
      printed for an operation that did not happen.
