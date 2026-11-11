# Node: the delivery route

Procedure for the **delivery route** node of `/cc-tuner:setup`. On GitHub `/cc-tuner:run` merges through
`merge.sh`. On other hosts it follows a route text in the plugin (`skills/run/references/route-gitlab.md`,
`route-local.md`), where a candidate cannot edit it. The repository holds only a short key block in
`.claude/rules/task-flow.local.md`, between two markers. `scripts/setup/route.sh` alone writes and checks
that block; this node runs it and restates none of its rules.

**Shell state does not persist between Bash calls.** Re-run the **Locate** block at the start of every Bash
call that uses `$HOST`, `$ROOT`, `$LOCAL`, `$PLUGIN` or `$ROUTE`; it is read-only.

## Contents

- [Locate the host and the file](#locate-the-host-and-the-file)
- [check](#check)
- [install](#install)
- [Verification](#verification)

## Locate the host and the file

Run the **Plugin root** block from [SKILL.md](../SKILL.md#plugin-root) first, in the same Bash call, then:

```bash
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository"; exit 1; }
ROUTE="$PLUGIN/scripts/setup/route.sh"
LOCAL="$ROOT/.claude/rules/task-flow.local.md"
ROW=$(bash "$PLUGIN/scripts/setup/host.sh" "$ROOT") || { echo "host not detected"; exit 1; }
HOST=${ROW%%$(printf '\t')*}
[ -f "$LOCAL" ] || { echo "$LOCAL does not exist: run the task-flow rule node first"; exit 1; }
echo "host: $HOST"
```

`$HOST` is `github`, `gitlab`, `local`, `other` or `ambiguous`. `ambiguous` (several remotes, none named
`origin`) blocks this node: report it and tell the user to rename one remote to `origin`
(`git remote rename <remote> origin`).

## check

Write nothing. `bash "$ROUTE" check "$HOST" "$ROOT"` prints one word (with a host or two counts), and its
exit code matches:

| prints | meaning | report |
|---|---|---|
| `current` | `gitlab`/`local` block equals the plugin's key block | up to date |
| `present-other` | `other` block is there; the user's words are not compared | present, user-described |
| `none-needed` | `github`, no block | nothing to write: `merge.sh` is the route |
| `missing` | no block | not written: `/cc-tuner:setup install delivery-route` |
| `mismatch <host>` | the block is for another host | `/run` stops until it is replaced |
| `drift` | the block differs from the plugin's key block | show `diff <(bash "$ROUTE" canonical "$HOST") <(the block)` |
| `malformed <opens> <closes>` | markers do not pair, or more than one block | fix by hand; setup refuses to guess |
| `stale-on-github <host>` | a block exists on a github repository | remove by hand, below |

## install

1. **`github`** → `none-needed`: report "nothing to write: merge.sh is the route" and finish. On
   `stale-on-github`, show the block with
   `sed -n '/^<!-- cc-tuner:delivery-route /,/^<!-- \/cc-tuner:delivery-route -->$/p' "$LOCAL"`, say that
   `/run` stops on it until the user deletes it by hand, opening marker through closing marker, and finish.
2. **`malformed`** → report the counts, say the block is fixed by hand in
   `.claude/rules/task-flow.local.md`, and finish. `route.sh write` refuses it too (exit 3).
3. **`other`** → the block body is written from the user's own words, never from another host's route. Ask
   in plain text (the answer is free-form): how is a candidate **opened**, how are verdicts and verification
   **recorded**, how is it **checked** (review, CI), and how is it **merged**? Tidy the answer into steps
   without adding to it. If one of the four is missing, ask for it once more; if it is still missing, write
   "not described", never a step taken from the GitLab or local route. Save the text to a temp file with
   the Write tool, so quotes and backticks stay text:

   ```bash
   BODY=$(mktemp) || { echo "ERROR: mktemp failed"; exit 1; }
   echo "$BODY"    # write the description to this path
   ```
4. **Decide by what `check` said.**
   - `missing` → additive, covered by the install request: write it.
   - `current` → report "up to date" and write nothing.
   - `drift`, `mismatch`, or a re-described `other` block → show the diff (`route.sh canonical "$HOST"`
     against the current block, or the new description against the old one) and ask before replacing
     (AskUserQuestion: overwrite / keep). Say that hand edits inside the block would be lost; they belong
     outside the markers. On **keep**, report "kept existing block, not updated"; the other nodes still run.
5. **Write.** `route.sh write` replaces only the block and an older file's legacy header comment, writes
   atomically and checks its own result:

   ```bash
   bash "$ROUTE" write "$HOST" "$LOCAL" ${BODY:+"$BODY"}    # prints written | replaced | unchanged
   ```

   Exit 3 is a malformed existing block (step 2), exit 2 a refusal such as an empty description (nothing
   written), exit 1 an operational failure. Report the word it printed, never a success it did not print.
   Remove `$BODY` afterwards.
6. **Say that the block must be committed.** `/run` works in task worktrees, which have only committed
   files: the block is committed together with `task-flow.local.md`, or `/run` stops on a missing block.
   Setup leaves the commit to the user.

## Verification

- [ ] After a write, `bash "$ROUTE" check "$HOST" "$ROOT"` prints `current` (`gitlab`, `local`) or
      `present-other` (`other`).
- [ ] `git diff -- "$LOCAL"` shows the block, and on an older file the rewritten header comment, and nothing
      else.
- [ ] Re-running the node says "up to date" (`gitlab`, `local`) and `route.sh write` prints `unchanged`.
- [ ] A failed write reports the script's error and a non-zero exit; success is never printed for an
      operation that did not happen.
- [ ] `bash "$PLUGIN/scripts/setup/doctor.sh" quick` now says `delivery route (<host>)` with `ok`, not `WARN`.
