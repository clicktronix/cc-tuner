#!/usr/bin/env bash
set -u

SCRIPT="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/preflight.sh"
RUNS_REL=".claude/execute-task-runs"
failures=0

make_repo() {
  REPO="$(mktemp -d)" || exit 1
  (
    cd "$REPO" && git init -q -b main && git config user.email test@example.com \
      && git config user.name test && printf 'base\n' > file.txt && git add file.txt \
      && git commit -qm init && git switch -qc task
  ) || exit 1
}

run_preflight() {
  CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" "$@"
}

make_repo
JOURNAL="$(run_preflight run-1 main --expected-branch task)"
SHA="$(git -C "$REPO" rev-parse main)"
if [ -f "$REPO/$JOURNAL" ] \
  && grep -qxF 'run_id=run-1' "$REPO/$RUNS_REL/run-1.meta" \
  && grep -qxF 'branch=task' "$REPO/$RUNS_REL/run-1.meta" \
  && grep -qxF "target_sha=$SHA" "$REPO/$RUNS_REL/run-1.meta" \
  && (cd "$REPO" && git check-ignore -q "$JOURNAL"); then
  echo "PASS clean-preflight-owned"
else
  echo "FAIL clean-preflight-owned"
  failures=1
fi
rm -rf "$REPO"

make_repo
printf 'change\n' >> "$REPO/file.txt"
run_preflight dirty main --expected-branch task >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$REPO/$RUNS_REL/dirty.md" ]; then
  echo "PASS dirty-blocks"
else
  echo "FAIL dirty-blocks (rc=$rc)"
  failures=1
fi
rm -rf "$REPO"

make_repo
mkdir -p "$REPO/packages/app"
printf 'nested\n' > "$REPO/packages/app/app.txt"
(cd "$REPO" && git add packages/app/app.txt && git commit -qm "add nested project")
JOURNAL="$(CLAUDE_PROJECT_DIR="$REPO/packages/app" bash "$SCRIPT" nested-root main --expected-branch task)"
if [ "$JOURNAL" = "$RUNS_REL/nested-root.md" ] \
  && [ -f "$REPO/$JOURNAL" ] \
  && [ ! -e "$REPO/packages/app/.claude" ] \
  && (cd "$REPO" && git check-ignore -q "$JOURNAL"); then
  echo "PASS subdirectory-run-state-is-git-root-owned"
else
  echo "FAIL subdirectory-run-state-is-git-root-owned (journal=$JOURNAL)"
  failures=1
fi
rm -rf "$REPO"

make_repo
mkdir -p "$REPO/packages/app"
printf 'nested\n' > "$REPO/packages/app/app.txt"
(cd "$REPO" && git add packages/app/app.txt && git commit -qm "add nested project")
printf 'dirty outside project\n' >> "$REPO/file.txt"
CLAUDE_PROJECT_DIR="$REPO/packages/app" bash "$SCRIPT" nested-dirty main --expected-branch task >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$REPO/$RUNS_REL/nested-dirty.md" ] \
  && [ ! -e "$REPO/packages/app/$RUNS_REL/nested-dirty.md" ]; then
  echo "PASS repo-wide-dirty-blocks-from-subdirectory"
else
  echo "FAIL repo-wide-dirty-blocks-from-subdirectory (rc=$rc)"
  failures=1
fi
rm -rf "$REPO"

make_repo
run_preflight 'same/id' main --expected-branch task >/dev/null 2>&1; slash_rc=$?
run_preflight 'Run' main --expected-branch task >/dev/null 2>&1; upper_rc=$?
run_preflight run main --expected-branch task >/dev/null 2>&1; lower_rc=$?
if [ "$slash_rc" -eq 1 ] && [ "$upper_rc" -eq 1 ] && [ "$lower_rc" -eq 0 ]; then
  echo "PASS filesystem-colliding-run-ids-rejected"
else
  echo "FAIL filesystem-colliding-run-ids-rejected (slash=$slash_rc upper=$upper_rc lower=$lower_rc)"
  failures=1
fi
rm -rf "$REPO"

make_repo
run_preflight wrong-branch main --expected-branch other >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS expected-branch-enforced" \
  || { echo "FAIL expected-branch-enforced (rc=$rc)"; failures=1; }
(cd "$REPO" && git switch -q main)
run_preflight target-branch main --expected-branch main >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS target-cannot-own-run" \
  || { echo "FAIL target-cannot-own-run (rc=$rc)"; failures=1; }
(cd "$REPO" && git switch -q task)
run_preflight non-branch HEAD --expected-branch task >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS non-branch-target-rejected" \
  || { echo "FAIL non-branch-target-rejected (rc=$rc)"; failures=1; }
rm -rf "$REPO"

make_repo
run_preflight shared-run main --expected-branch task >/dev/null
(cd "$REPO" && git switch -qc other)
run_preflight shared-run main --expected-branch other >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS cross-branch-reuse-rejected" \
  || { echo "FAIL cross-branch-reuse-rejected (rc=$rc)"; failures=1; }
rm -rf "$REPO"

make_repo
run_preflight tampered main --expected-branch task >/dev/null
sed 's/^run_id=.*/run_id=other/' "$REPO/$RUNS_REL/tampered.meta" > "$REPO/$RUNS_REL/tampered.meta.new"
mv "$REPO/$RUNS_REL/tampered.meta.new" "$REPO/$RUNS_REL/tampered.meta"
run_preflight tampered main --expected-branch task >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS metadata-run-id-enforced" \
  || { echo "FAIL metadata-run-id-enforced (rc=$rc)"; failures=1; }
rm -rf "$REPO"

make_repo
OUTSIDE="$(mktemp -d)" || exit 1
ln -s "$OUTSIDE" "$REPO/.claude"
run_preflight symlink main --expected-branch task >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$OUTSIDE/execute-task-runs/symlink.md" ]; then
  echo "PASS symlinked-state-rejected"
else
  echo "FAIL symlinked-state-rejected (rc=$rc)"
  failures=1
fi
rm -rf "$OUTSIDE" "$REPO"

NOGIT="$(mktemp -d)" || exit 1
CLAUDE_PROJECT_DIR="$NOGIT" bash "$SCRIPT" bad-root main --expected-branch task >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS bad-root" || { echo "FAIL bad-root (rc=$rc)"; failures=1; }
rm -rf "$NOGIT"

exit "$failures"
