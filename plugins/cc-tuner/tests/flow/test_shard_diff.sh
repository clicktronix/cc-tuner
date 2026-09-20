#!/usr/bin/env bash
# shard-diff.sh: the arithmetic deep-review used to do in prose, run against real repositories.
#
# The field incident (#38): one lens over a 1071-file candidate spawned five readers of its own,
# because the threshold and the grouping lived in a sentence. Here every threshold, grouping and cap
# is an assertion on stdout of the script over a repository built for the case.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SHARD="$FLOW_PLUGIN/scripts/shard-diff.sh"

# repo_with <count> [dir-pattern] -> a repo whose candidate commit adds <count> files; prints path.
# dir-pattern is a printf format taking the file index, so callers spread files across directories.
repo_with() {
  local n="$1" pat="${2:-src/f%d.txt}" d i
  d="$(flow_repo)"
  (
    cd "$d" || exit 1
    git tag base
    i=1
    while [ "$i" -le "$n" ]; do
      f="$(printf "$pat" "$i")"; mkdir -p "$(dirname "$f")"; printf 'line %d\n' "$i" > "$f"; i=$((i + 1))
    done
    git add -A && git commit -q -m 'candidate'
  ) || { printf 'FATAL: could not build repo\n'; exit 1; }
  printf '%s' "$d"
}
shard() {  # shard <repo> [args...] -> stdout only
  local d="$1"; shift; (cd "$d" && bash "$SHARD" base HEAD "$@" 2>/dev/null)
}
lines_of() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k' ; }

# --- size and mode -------------------------------------------------------------------------------
R="$(repo_with 5)"
OUT="$(shard "$R")"
check  "size-line-reports-files-and-lines" "SIZE	5	5" "$OUT"
check  "below-thresholds-is-single"        "MODE	single" "$OUT"
absent "single-emits-no-shards"            "SHARD"       "$OUT"

R="$(repo_with 300 'src/d%d/f.txt')"
OUT="$(shard "$R")"
check "threshold-300-files-shards" "MODE	sharded" "$OUT"
OUT="$(shard "$R" --files 301)"
check "threshold-is-inclusive-at-files" "MODE	single" "$OUT"

R="$(flow_repo)"
( cd "$R" && git tag base && awk 'BEGIN{for(i=1;i<=5000;i++)print "l"i}' > a.txt && awk 'BEGIN{for(i=1;i<=5000;i++)print "m"i}' > b.txt \
  && git add -A && git commit -q -m c )
OUT="$(shard "$R")"
check "threshold-10000-lines-shards" "MODE	sharded" "$OUT"
check "lines-counted-as-insertions-plus-deletions" "SIZE	2	10000" "$OUT"

# --- grouping without a plan: first path component, root for top-level ---------------------------
R="$(flow_repo)"
( cd "$R" && git tag base && mkdir -p src/x lib docs && for f in src/x/a src/b lib/c docs/d top; do printf 'x\n' > "$f.txt"; done \
  && git add -A && git commit -q -m c )
OUT="$(shard "$R" --files 1)"
equals "no-plan-groups-by-first-component" "SHARD	1	docs	docs/d.txt
SHARD	2	lib	lib/c.txt
SHARD	3	root	top.txt
SHARD	4	src	src/b.txt,src/x/a.txt" "$(lines_of "$OUT" SHARD)"

# --- grouping with a plan: Owned paths through plan-lint.sh owned, unmatched in rest --------------
PLAN="$R/plan.md"
printf '%s\n' '**Spec:** docs/PLANS/x.md' '**Branch:** feat/x' '' '## Slice 1 — A' 'Blocked by: none' \
  'Owned paths: src/x/,lib/c.txt' 'Deciding check: true' 'Delivers: a.' '' '- [ ] a' '' \
  '## Slice 2 — B' 'Blocked by: none' 'Owned paths: docs/' 'Deciding check: true' 'Delivers: b.' '' '- [ ] b' > "$PLAN"
OUT="$(shard "$R" --files 1 --plan plan.md)"
equals "plan-groups-by-owned-paths-with-rest" "SHARD	1	slice-1	lib/c.txt,src/x/a.txt
SHARD	2	slice-2	docs/d.txt
SHARD	3	rest	src/b.txt,top.txt" "$(lines_of "$OUT" SHARD)"
( cd "$R" && printf '## Slice 1 — A\nBlocked by: 9\n\n- [ ] a\n' > bad.md )
out="$(cd "$R" && bash "$SHARD" base HEAD --files 1 --plan bad.md 2>/dev/null)"; rc=$?
equals "invalid-plan-fails-closed-rc" "1" "$rc"
equals "invalid-plan-prints-nothing"  ""  "$out"

# --- the cap: more groups than --max merge smallest into neighbour until it holds -----------------
OUT="$(shard "$R" --files 1 --max 2)"
equals "cap-holds-at-max"     "2" "$(lines_of "$OUT" SHARD | wc -l | tr -d ' ')"
equals "cap-keeps-every-file" "5" "$(lines_of "$OUT" SHARD | cut -f4 | tr ',' '\n' | wc -l | tr -d ' ')"
check  "cap-names-merged-keys" "+" "$(lines_of "$OUT" SHARD)"

# --- a bad ref exits non-zero with an empty stdout -----------------------------------------------
out="$(cd "$R" && bash "$SHARD" base no-such-ref 2>/dev/null)"; rc=$?
equals "bad-ref-rc-nonzero" "1" "$rc"
equals "bad-ref-empty-stdout" "" "$out"

out="$(bash "$SHARD" 2>&1)"; rc=$?
check  "usage-on-missing-args" "usage:" "$out"
equals "usage-rc1" "1" "$rc"

exit $fails
