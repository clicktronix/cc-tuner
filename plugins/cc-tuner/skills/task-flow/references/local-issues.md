# Local issue files

Use this for every `tracker: local` read or write: the primary issue, groom comments and independent
future work. Take the relative issue path from `docs/agents/issue-tracker.md`. An absolute path
already recorded in the spec identifies the same issue across worktrees; use it directly.

For a new relative path, set `ISSUE_REL` to that path and run:

```bash
ROOT="$(git rev-parse --show-toplevel)" || exit 1
ISSUE_PATH="$ROOT/$ISSUE_REL"
if git -C "$ROOT" check-ignore -q -- "$ISSUE_REL"; then
  MAIN="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
  [ "$(git -C "$MAIN" rev-parse --is-bare-repository 2>/dev/null)" = false ] || {
    echo "No persistent main checkout: choose a lasting checkout for this ignored tracker before writing" >&2
    exit 1
  }
  ISSUE_PATH="$MAIN/$ISSUE_REL"
fi
printf '%s\n' "$ISSUE_PATH"
```

- **Tracked or not ignored:** write in the task checkout and commit with the candidate. Groom only
  appends its comment; the later spec/run commits it. Closing changes enter the candidate before review.
- **Ignored:** write in the main checkout, leave uncommitted and record the absolute path in the spec
  or hand-back. Close only after the issue's own work is complete and its merge is observed.
  Resolve companion link files the same way.

Before editing, read the existing issue and preserve its comments. If an ignored issue is still in
a temporary worktree, move it to the resolved location; reconcile an existing destination rather
than overwriting either history.

Before removing a task worktree, check its tracker directory for ignored issues or link files and
preserve them as above. A clean `git status` does not include ignored files.
