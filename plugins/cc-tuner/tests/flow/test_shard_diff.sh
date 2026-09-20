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
OUT="$(shard "$R" --lines 5)"
equals "no-plan-groups-by-first-component" "SHARD	1	docs	docs/d.txt
SHARD	2	lib	lib/c.txt
SHARD	3	root	top.txt
SHARD	4	src	src/b.txt,src/x/a.txt" "$(lines_of "$OUT" SHARD)"

# --- grouping with a plan: Owned paths through plan-lint.sh owned, unmatched in rest --------------
PLAN="$R/plan.md"
printf '%s\n' '**Spec:** docs/PLANS/x.md' '**Branch:** feat/x' '' '## Slice 1 — A' 'Blocked by: none' \
  'Owned paths: src/x/,lib/c.txt' 'Deciding check: true' 'Delivers: a.' '' '- [ ] a' '' \
  '## Slice 2 — B' 'Blocked by: none' 'Owned paths: docs/' 'Deciding check: true' 'Delivers: b.' '' '- [ ] b' > "$PLAN"
OUT="$(shard "$R" --lines 5 --plan plan.md)"
equals "plan-groups-by-owned-paths-with-rest" "SHARD	1	slice-1	lib/c.txt,src/x/a.txt
SHARD	2	slice-2	docs/d.txt
SHARD	3	rest	src/b.txt,top.txt" "$(lines_of "$OUT" SHARD)"
( cd "$R" && printf '## Slice 1 — A\nBlocked by: 9\n\n- [ ] a\n' > bad.md )
out="$(cd "$R" && bash "$SHARD" base HEAD --lines 5 --plan bad.md 2>/dev/null)"; rc=$?
equals "invalid-plan-fails-closed-rc" "1" "$rc"
equals "invalid-plan-prints-nothing"  ""  "$out"

# --- the cap: more groups than --max merge smallest into neighbour until it holds -----------------
OUT="$(shard "$R" --lines 5 --max 2)"
equals "cap-holds-at-max"     "2" "$(lines_of "$OUT" SHARD | wc -l | tr -d ' ')"
equals "cap-keeps-every-file" "5" "$(lines_of "$OUT" SHARD | cut -f4 | tr ',' '\n' | wc -l | tr -d ' ')"
check  "cap-names-merged-keys" "+" "$(lines_of "$OUT" SHARD)"

# --- what a lens gets must be the change that happened -----------------------------------------
# A packet is `git --literal-pathspecs diff <base>...<candidate> -- <paths>` over a SHARD's path list.
# Every case below builds that packet and reads it, because the script's stdout looking right proved
# nothing about the diff a lens would read (review of the first candidate, 2026-09-20).
packet() {  # packet <repo> <shard-line> -> name-status of the packet the owner would write
  local d="$1" paths; paths="$(printf '%s' "$2" | cut -f4 | tr ',' '\n')"
  ( cd "$d" && printf '%s\n' "$paths" | tr '\n' '\0' | xargs -0 git -c core.quotePath=false --literal-pathspecs diff --find-renames --name-status base...HEAD -- )
}
R="$(flow_repo)"
( cd "$R" && git tag base && mkdir -p old src && printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > old/a.txt && git add -A && git commit -q -m base2 && git tag -f base >/dev/null \
  && mkdir -p new && git mv old/a.txt new/b.txt && printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl11\n' > new/b.txt \
  && printf 'x\n' > 'src/привет.ts' && printf 'k\n' > ':(exclude)keep.ts' && printf 'k\n' > keep.ts \
  && git -c core.quotePath=true add -A && git commit -q -m c )
OUT="$(shard "$R" --lines 5 --max 8)"
check  "rename-lists-both-sides"      "SHARD	1	new	new/b.txt,old/a.txt" "$OUT"
check  "rename-packet-is-a-rename"    "R"                             "$(packet "$R" "$(lines_of "$OUT" SHARD | awk -F'\t' '$3=="new"')")"
check  "non-ascii-path-is-unquoted"   "src/привет.ts"                 "$OUT"
check  "non-ascii-packet-is-not-empty" "src/привет.ts"                "$(packet "$R" "$(lines_of "$OUT" SHARD | awk -F'\t' '$3=="src"')")"
equals "pathspec-magic-is-off-in-packets" "A	:(exclude)keep.ts
A	keep.ts" "$(packet "$R" "$(lines_of "$OUT" SHARD | awk -F'\t' '$3=="root"')")"
equals "size-counts-a-rename-once-and-both-lines" "SIZE	4	5" "$(lines_of "$OUT" SIZE)"

# --- a group that reaches a threshold is split, and the cap is a refusal, not a lie ---------------
R="$(repo_with 7 'src/f%d.txt')"
OUT="$(shard "$R" --files 3 --max 8)"
equals "oversized-group-splits-below-threshold" "SHARD	1	src#1	src/f1.txt,src/f2.txt
SHARD	2	src#2	src/f3.txt,src/f4.txt
SHARD	3	src#3	src/f5.txt,src/f6.txt
SHARD	4	src#4	src/f7.txt" "$(lines_of "$OUT" SHARD)"
out="$(cd "$R" && bash "$SHARD" base HEAD --files 3 --max 2 2>"$R/err")"; rc=$?
equals "cap-that-cannot-hold-rc1"          "1" "$rc"
equals "cap-that-cannot-hold-empty-stdout" ""  "$out"
check  "cap-that-cannot-hold-says-how-many" "need 4 shards below --files 3" "$(cat "$R/err")"
# One atomic change must also fit; a fresh chunk does not waive its budget.
for count in 10000 10001; do
  R="$(flow_repo)"
  ( cd "$R" && git tag base && awk -v n="$count" 'BEGIN{for(i=1;i<=n;i++)print "l"i}' > big.txt \
    && { [ "$count" -eq 10000 ] || printf 'x\n' > small.txt; } && git add -A && git commit -q -m c )
  out="$(cd "$R" && bash "$SHARD" base HEAD 2>"$R/err")"; rc=$?
  equals "oversized-singleton-$count-rc1" "1" "$rc"
  equals "oversized-singleton-$count-empty-stdout" "" "$out"
  check "oversized-singleton-$count-names-file" "big.txt" "$(cat "$R/err")"
  # The owner can explicitly change the budget after seeing the refusal.
  OUT="$(shard "$R" --lines 20000)"
  check "oversized-singleton-$count-explicit-budget" "MODE	single" "$OUT"
done

# Pure renames cost zero changed lines; file count still controls chunking.
R="$(repo_with 3)"
( cd "$R" && git tag -f base HEAD >/dev/null && git mv src dst && git commit -q -m renames )
OUT="$(shard "$R" --files 2 --lines 1)"
check "pure-renames-have-zero-line-cost" "SIZE	3	0" "$OUT"
equals "pure-renames-fit-line-budget" "3" "$(lines_of "$OUT" SHARD | wc -l | tr -d ' ')"

# --- merging never loses a file to a label collision ---------------------------------------------
R="$(flow_repo)"
( cd "$R" && git tag base && for d in a 'a!' 'a+a!' y z; do mkdir -p "$d"; printf 'x\n' > "$d/f.txt"; done && git add -A && git commit -q -m c )
OUT="$(shard "$R" --lines 5)"
equals "merge-keeps-every-file-under-a-colliding-label" "5" "$(lines_of "$OUT" SHARD | cut -f4 | tr ',' '\n' | sort -u | wc -l | tr -d ' ')"
equals "merge-holds-the-cap" "4" "$(lines_of "$OUT" SHARD | wc -l | tr -d ' ')"

# --- a path the grammar cannot carry is refused, not split ---------------------------------------
R="$(flow_repo)"
( cd "$R" && git tag base && printf 'x\n' > 'a,b.txt' && git add -A && git commit -q -m c )
out="$(cd "$R" && bash "$SHARD" base HEAD 2>"$R/err")"; rc=$?
equals "comma-path-rc1"          "1" "$rc"
equals "comma-path-empty-stdout" ""  "$out"
check  "comma-path-names-the-file" "cannot list a path containing a comma: a,b.txt" "$(cat "$R/err")"

# --- a bad ref exits non-zero with an empty stdout -----------------------------------------------
out="$(cd "$R" && bash "$SHARD" base no-such-ref 2>/dev/null)"; rc=$?
equals "bad-ref-rc-nonzero" "1" "$rc"
equals "bad-ref-empty-stdout" "" "$out"

# --- Git errors must not look like a successfully read empty diff -------------------------------
R="$(repo_with 1)"
( cd "$R" && git config diff.algorithm not-an-algorithm )
out="$(cd "$R" && bash "$SHARD" base HEAD 2>"$R/err")"; rc=$?
equals "git-diff-failure-rc1" "1" "$rc"
equals "git-diff-failure-empty-stdout" "" "$out"
check "git-diff-failure-diagnostic" "could not read the diff" "$(cat "$R/err")"
( cd "$R" && git config --unset diff.algorithm && git checkout -q --orphan unrelated \
  && git commit -q -m 'unrelated root' )
out="$(cd "$R" && bash "$SHARD" base HEAD 2>"$R/err")"; rc=$?
equals "no-merge-base-rc1" "1" "$rc"
equals "no-merge-base-empty-stdout" "" "$out"
check "no-merge-base-diagnostic" "could not read the diff" "$(cat "$R/err")"
out="$(cd "$R" && bash "$SHARD" HEAD HEAD 2>/dev/null)"; rc=$?
equals "empty-diff-remains-successful" "0" "$rc"
equals "empty-diff-is-single" "SIZE	0	0
MODE	single" "$out"

out="$(bash "$SHARD" 2>&1)"; rc=$?
check  "usage-on-missing-args" "usage:" "$out"
equals "usage-rc1" "1" "$rc"

exit $fails
