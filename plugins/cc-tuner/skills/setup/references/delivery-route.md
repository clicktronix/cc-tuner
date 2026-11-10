# Node: the delivery route

Procedure for the **delivery route** node of `/cc-tuner:setup`. `/cc-tuner:run` merges through
`merge.sh` only on GitHub. For any other host it follows a route written in the repository: the
plugin's asset for GitLab or a remote-less repository, or the user's own words for another host. The
route lives in `.claude/rules/task-flow.local.md` between two markers, so the file stays the
repository's and setup owns only the block.

**Shell state does not persist between Bash calls.** Claude Code keeps the working directory but NOT
shell variables across separate Bash invocations, and the questions below guarantee the flow splits
into several. Re-run the **Locate** block at the start of every Bash invocation that references
`$HOST`, `$ROOT`, `$LOCAL`, `$SRC`, `$NEW`, `$OPEN` or `$CLOSE`: it is read-only and idempotent, so
re-running it is always safe and never optional after a prompt.

**Run the steps in the order they are numbered.**

## Contents

- [Locate the host, the asset and the file](#locate-the-host-the-asset-and-the-file)
- [check](#check)
- [install](#install)
- [Verification](#verification)

## Locate the host, the asset and the file

Set `HOST` to the word after `host:` in node 0's output (`github`, `gitlab`, `local` or `other`). When
node 0 printed `host not detected`, this node is blocked: report it and stop.

```bash
HOST=gitlab   # replace with node 0's host
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository"; exit 1; }
LOCAL="$ROOT/.claude/rules/task-flow.local.md"
OPEN='<!-- cc-tuner:delivery-route '
CLOSE='<!-- /cc-tuner:delivery-route -->'
case "$HOST" in
  gitlab|local)
    SRC="${CLAUDE_PLUGIN_ROOT:-}/assets/task-flow/route-$HOST.md"
    if [ ! -f "$SRC" ]; then
      SRC=$(find "$HOME/.claude/plugins" -path "*/cc-tuner/assets/task-flow/route-$HOST.md" 2>/dev/null | sort | tail -1)
    fi
    [ -f "$SRC" ] || { echo "Could not locate route-$HOST.md — is cc-tuner installed?"; exit 1; }
    ;;
esac
[ -f "$LOCAL" ] || { echo "$LOCAL does not exist — run the task-flow rule node first"; exit 1; }
N_OPEN=$(grep -c "^$OPEN" "$LOCAL"); N_CLOSE=$(grep -c "^$CLOSE\$" "$LOCAL")
if [ "$N_OPEN" -gt 1 ] || [ "$N_OPEN" -ne "$N_CLOSE" ]; then
  echo "ERROR: $LOCAL has $N_OPEN opening and $N_CLOSE closing delivery-route markers; expected one block or none — fix it by hand"; exit 1
fi
BLOCK=$(sed -n "/^$OPEN/,\#^$CLOSE\$#p" "$LOCAL")
BLOCK_HOST=$(printf '%s\n' "$BLOCK" | head -n 1 | sed -n 's/^<!-- cc-tuner:delivery-route \([a-z][a-z]*\).*/\1/p')
```

`$BLOCK` is empty when there is no block; `$BLOCK_HOST` is the host named by its opening marker.
The block of a `gitlab` or `local` route is the asset verbatim followed by the closing marker, so it
is compared by content: the version in the marker is the plugin version at the asset's last change,
and an older marker on an unchanged asset is expected. A block is at most one per file; the guard
above stops on a half-written or duplicated one rather than guessing which part to replace.

## check

Write nothing.

- `github` → "nothing to write: merge.sh is the route". When `$BLOCK` exists anyway, say it belongs
  to another host and `/cc-tuner:run` will stop on the mismatch until it is removed by hand.
- `gitlab`, `local` → compare `$BLOCK` with `$(cat "$SRC"; printf '%s\n' "$CLOSE")`:
  - no block → "not written — run `/cc-tuner:setup install delivery-route`";
  - identical → "up to date";
  - `$BLOCK_HOST` is not `$HOST` → "block is for `$BLOCK_HOST`, this repository is `$HOST`", with the
    diff;
  - otherwise → "differs from the plugin's asset" with the `diff`, and the same install command.
- `other` → no block → "not written"; a block → print it and say it is the user's description, not
  compared with anything.

## install

1. **`github`** → report "nothing to write: merge.sh is the route" and finish; touch nothing.
2. **Build the new block in a temp file** next to the target, fail-closed:
   - `gitlab`, `local`:
     ```bash
     NEW=$(mktemp "$ROOT/.claude/rules/.route-new.XXXXXX") || { echo "ERROR: mktemp failed"; exit 1; }
     if ! { cat "$SRC"; printf '%s\n' "$CLOSE"; } > "$NEW" || [ ! -s "$NEW" ]; then
       rm -f "$NEW"; echo "ERROR: cannot build the route block"; exit 1
     fi
     ```
   - `other` → the block is written from the user's own words, never from another host's asset.
     Ask once, in plain text (the answer is free-form, not a choice): how is a candidate **opened**,
     how are verdicts and verification **recorded**, how is it **checked** (review, CI), and how is it
     **merged**? Write their answer as the body between `<!-- cc-tuner:delivery-route other -->` and
     `$CLOSE`, tidied into steps but not extended. When the answer leaves out one of the four, name
     which and ask once more; a gap that remains is written as "not described", never filled in from
     the GitLab or local route.
3. **Decide by what is there** (`$BLOCK`, `$BLOCK_HOST`):
   - **No block** → additive, covered by the install request: append `$NEW` after a blank line
     (writer below, mode `append`).
   - **Block identical to `$NEW`** (`gitlab`, `local`) → report "up to date" and write nothing.
   - **Block differs** (drift, another host's block, or a re-described `other`) → show
     `diff <(printf '%s\n' "$BLOCK") "$NEW"` and ask before replacing (AskUserQuestion: overwrite /
     keep). Hand edits inside the block would be lost, so say that; they belong outside the markers.
     On **overwrite**, use the writer in mode `replace`. On **keep**, report "kept existing block —
     not updated" and mark this node kept; the other nodes still run.
4. **Write** atomically and fail-closed: a same-directory temp file, then `mv`.
   Replace only the text between the markers, and never touch the rest of the file.
   ```bash
   TMP=$(mktemp "$ROOT/.claude/rules/.task-flow-local.XXXXXX") || { echo "ERROR: mktemp failed"; exit 1; }
   if [ -z "$BLOCK" ]; then
     { cat "$LOCAL"; printf '\n'; cat "$NEW"; } > "$TMP"
   else
     START=$(grep -n "^$OPEN" "$LOCAL" | cut -d: -f1)
     END=$(grep -n "^$CLOSE\$" "$LOCAL" | cut -d: -f1)
     { head -n $((START - 1)) "$LOCAL"; cat "$NEW"; tail -n +$((END + 1)) "$LOCAL"; } > "$TMP"
   fi
   if [ -s "$TMP" ] && mv "$TMP" "$LOCAL"; then
     rm -f "$NEW"; echo "Wrote the $HOST delivery route to $LOCAL"
   else
     rm -f "$TMP" "$NEW"; echo "ERROR: failed to write $LOCAL"; exit 1
   fi
   ```
   Report that the route is a copy: a later plugin release that changes it shows up as drift in
   doctor, and this node offers the update then.

## Verification

- [ ] After a write, re-run **Locate**: `$BLOCK` equals the new block byte for byte
      (`gitlab`, `local`: `$(cat "$SRC"; printf '%s\n' "$CLOSE")`), its first line is its opening
      marker, and `grep -c "^$OPEN" "$LOCAL"` prints 1.
- [ ] Everything outside the markers is unchanged: the file with the block deleted
      (`sed "/^$OPEN/,\#^$CLOSE\$#d"`) is identical before and after the write.
- [ ] Re-running the node reports "up to date" (`gitlab`, `local`) and writes nothing.
- [ ] A failed read, mktemp or write reports ERROR and exits non-zero; success is never printed for
      an operation that did not happen.
- [ ] `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/doctor.sh" quick` now says `delivery route (<host>)`
      with `ok`, not `WARN`.
