#!/usr/bin/env bash
# Decide whether a candidate diff is reviewed whole or in shards, and print the shards.
#
#   shard-diff.sh <base> <candidate> [--plan <path>] [--max 4] [--files 300] [--lines 10000]
#
# Prints, tab-separated:
#   SIZE  <changed files> <insertions+deletions>
#   MODE  single|sharded
#   SHARD <n> <key> <path,...>          one per shard, only when sharded
#
# Sharded when the file count reaches --files OR the line count reaches --lines. With --plan, files
# are grouped by the plan's Owned paths (through `plan-lint.sh owned`, so one parser owns that
# grammar; unmatched files go to `rest`); without one, by first path component (`root` for top-level
# files). More groups than --max are merged, smallest into its neighbour, until the cap holds.
#
# This used to be prose in deep-review, and prose arithmetic is what failed in the field: a lens
# handed a 1071-file candidate spawned five readers of its own (#38). A bad ref exits 1 with nothing
# on stdout, so a caller that reads MODE can never mistake an error for `single`.
# bash 3.2: no associative arrays, no mapfile.
set -u

die() { printf 'shard-diff: %s\n' "$1" >&2; exit 1; }
usage() { die 'usage: shard-diff.sh <base> <candidate> [--plan <path>] [--max <n>] [--files <n>] [--lines <n>]'; }

BASE="${1:-}"; CAND="${2:-}"
[ -n "$BASE" ] && [ -n "$CAND" ] || usage
shift 2
PLAN=""; MAX=4; FILES=300; LINES=10000
num() { case "$2" in ''|*[!0-9]*|0) die "$1 requires a positive integer, got '${2:-}'" ;; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)  [ $# -ge 2 ] && [ -n "$2" ] || die '--plan requires a path'; PLAN="$2"; shift 2 ;;
    --max)   [ $# -ge 2 ] || usage; num --max "$2";   MAX="$2";   shift 2 ;;
    --files) [ $# -ge 2 ] || usage; num --files "$2"; FILES="$2"; shift 2 ;;
    --lines) [ $# -ge 2 ] || usage; num --lines "$2"; LINES="$2"; shift 2 ;;
    *) usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die "not a commit: $BASE"
git rev-parse --verify --quiet "$CAND^{commit}" >/dev/null || die "not a commit: $CAND"

# Owned paths come from the linter's parser, never from a second reader of the plan grammar. An
# invalid plan fails closed: the review must not shard along lines nobody scheduled.
OWNED=""
if [ -n "$PLAN" ]; then
  OWNED="$(bash "$SCRIPT_DIR/plan-lint.sh" owned "$PLAN")" || die "plan-lint.sh owned refused $PLAN"
fi

# numstat: <ins>\t<del>\t<path>; binary files print `-`, which counts as no lines but still a file.
STAT="$(git diff --numstat --find-renames "$BASE...$CAND")" || die "git diff failed for $BASE...$CAND"

# OWNED rows travel on stdin ahead of the numstat rows: BSD awk refuses a -v value with a newline.
{ [ -z "$OWNED" ] || printf '%s\n' "$OWNED"; printf '%s\n' "$STAT"; } \
  | awk -F'\t' -v files_t="$FILES" -v lines_t="$LINES" -v max="$MAX" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# The same prefix rule plan-lint.sh applies between slices: a path owns itself and everything below.
function owns(prefix, path) { sub(/\/+$/, "", prefix); return (path == prefix || index(path, prefix "/") == 1) }
function key_of(path,   i, m, parts, j) {
  if (on > 0) {
    for (i = 1; i <= on; i++) {
      m = split(opaths[i], parts, ",")
      for (j = 1; j <= m; j++) if (owns(trim(parts[j]), path)) return "slice-" onum[i]
    }
    return "rest"
  }
  return (index(path, "/") > 0) ? substr(path, 1, index(path, "/") - 1) : "root"
}
BEGIN { on = 0 }
$1 == "OWNED" { on++; onum[on] = $2; opaths[on] = $3; next }
NF == 3 {
  files++
  # A rename prints `{old => new}` or `old => new`; the path that exists at the candidate is the
  # one a lens reads, so keep the right-hand side.
  path = $3
  if (match(path, /\{[^}]* => [^}]*\}/)) {
    seg = substr(path, RSTART + 1, RLENGTH - 2); sub(/^[^=]* => /, "", seg)
    path = substr(path, 1, RSTART - 1) seg substr(path, RSTART + RLENGTH)
  } else if (index(path, " => ") > 0) { sub(/^.* => /, "", path) }
  w = ($1 == "-") ? 0 : $1 + $2
  lines += w
  k = key_of(path)
  if (!(k in gsize)) { gc++; gorder[gc] = k; gsize[k] = 0; gfiles[k] = "" }
  gsize[k] += (w > 0 ? w : 1)
  gfiles[k] = (gfiles[k] == "") ? path : gfiles[k] "," path
}
END {
  printf "SIZE\t%d\t%d\n", files, lines
  if (files < files_t && lines < lines_t) { print "MODE\tsingle"; exit 0 }
  print "MODE\tsharded"
  # Deterministic order: plan groups in plan order with rest last, directories alphabetically.
  # gorder is diff order; sort keys so two runs over the same diff print the same shards.
  for (i = 1; i <= gc; i++) keys[i] = gorder[i]
  for (i = 2; i <= gc; i++) { v = keys[i]; j = i - 1; while (j > 0 && rank(keys[j]) > rank(v)) { keys[j + 1] = keys[j]; j-- } keys[j + 1] = v }
  # Merge smallest into its neighbour (the next shard, or the previous when it is last) until the
  # cap holds. Keys join with "+", so a reader can still see what a merged shard was made of.
  n = gc
  while (n > max) {
    s = 1; for (i = 2; i <= n; i++) if (gsize[keys[i]] < gsize[keys[s]]) s = i
    t = (s < n) ? s + 1 : s - 1
    a = keys[(s < t) ? s : t]; b = keys[(s < t) ? t : s]
    gsize[a] += gsize[b]; gfiles[a] = gfiles[a] "," gfiles[b]; delete gsize[b]
    keys[(s < t) ? s : t] = a "+" b; gsize[a "+" b] = gsize[a]; gfiles[a "+" b] = gfiles[a]
    for (i = ((s < t) ? t : s); i < n; i++) keys[i] = keys[i + 1]
    n--
  }
  for (i = 1; i <= n; i++) {
    m = split(gfiles[keys[i]], pf, ","); for (j = 2; j <= m; j++) { v = pf[j]; jj = j - 1; while (jj > 0 && pf[jj] > v) { pf[jj + 1] = pf[jj]; jj-- } pf[jj + 1] = v }
    list = pf[1]; for (j = 2; j <= m; j++) list = list "," pf[j]
    printf "SHARD\t%d\t%s\t%s\n", i, keys[i], list
  }
}
# Ordering rank: slice-<n> by n, rest after every slice, directory keys by name.
function rank(k) {
  if (k ~ /^slice-[0-9]+$/) return sprintf("0%08d", substr(k, 7))
  if (k == "rest") return "1"
  return "2" k
}
'
