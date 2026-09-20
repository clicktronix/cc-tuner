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
# files). A group that itself reaches a threshold is split into chunks below it (`<key>#1`, `#2`…),
# because a shard as large as the diff it came from reviews nothing. Groups are then merged, smallest
# into its neighbour, while the merged pair stays below the thresholds and more than --max remain.
# If the cap still does not hold, the script refuses (exit 1, empty stdout) and says how many shards
# the candidate needs: an owner raises --max or the thresholds knowingly, rather than dispatching a
# lens set that cannot cover the diff.
#
# A rename lists both of its paths, so that `git diff -- <paths>` shows it as a rename and not as an
# added file. Paths come from `--numstat -z`, never from the quoted text form, so a non-ASCII name is
# the name a lens can read. A path the SHARD grammar cannot carry (comma, tab, newline) is refused.
#
# This used to be prose in deep-review, and prose arithmetic is what failed in the field: a lens
# handed a 1071-file candidate spawned five readers of its own (#38). A bad ref exits 1 with nothing
# on stdout, so a caller that reads MODE can never mistake an error for `single`.
# bash 3.2: no associative arrays, no mapfile. `read -d ''` splits on NUL, which is what -z needs.
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

# -z numstat: `<ins>\t<del>\t<path>\0` for a change, `<ins>\t<del>\t\0<old>\0<new>\0` for a rename.
# Binary files print `-` for both counts. Normalised here to one line per change:
# `<ins>\t<del>\t<path>\t<old-path-or-empty>`, which is what awk below reads.
TAB="$(printf '\t')"; NL='
'
ROWS="$(
  git diff --numstat -z --find-renames "$BASE...$CAND" 2>/dev/null | {
    while IFS= read -r -d '' rec; do
      ins="${rec%%$TAB*}"; rest="${rec#*$TAB}"; del="${rest%%$TAB*}"; path="${rest#*$TAB}"
      old=""
      if [ -z "$path" ]; then
        IFS= read -r -d '' old || exit 3
        IFS= read -r -d '' path || exit 3
      fi
      for p in "$path" "$old"; do
        # Balanced parentheses: bash 3.2 cannot parse an unbalanced `)` inside $( ... ).
        case "$p" in
          (*,*)      printf 'shard-diff: cannot list a path containing a comma: %s\n' "$p" >&2; exit 2 ;;
          (*"$TAB"*) printf 'shard-diff: cannot list a path containing a tab: %s\n' "$p" >&2; exit 2 ;;
          (*"$NL"*)  printf 'shard-diff: cannot list a path containing a newline: %s\n' "$p" >&2; exit 2 ;;
        esac
      done
      printf '%s\t%s\t%s\t%s\n' "$ins" "$del" "$path" "$old"
    done
  }
)"
case $? in
  0) ;;
  2) exit 1 ;;
  *) die "could not read the diff for $BASE...$CAND" ;;
esac

# OWNED rows travel on stdin ahead of the change rows: BSD awk refuses a -v value with a newline.
{ [ -z "$OWNED" ] || printf '%s\n' "$OWNED"; printf '%s\n' "$ROWS"; } \
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
# Ordering rank: slice-<n> by n, rest after every slice, directory keys by name.
function rank(k) {
  if (k ~ /^slice-[0-9]+$/) return sprintf("0%08d", substr(k, 7))
  if (k == "rest") return "1"
  return "2" k
}
# Groups are numbered; the key is a label and never an identity, so `a` + `a!` can never collide
# with a directory called `a+a!`. Per group g: gk[g] label, gn[g] files, gl[g] lines, gf[g, i] the
# i-th change as `<path>` or `<path>,<old>` (a rename carries both sides so git can show it as one).
BEGIN { on = 0; gc = 0; entries = 0 }
$1 == "OWNED" { on++; onum[on] = $2; opaths[on] = $3; next }
NF >= 3 && $3 != "" {
  files++
  w = ($1 == "-") ? 0 : $1 + $2
  lines += w
  entries++; epath[entries] = $3; eold[entries] = $4; ew[entries] = (w > 0 ? w : 1); ekey[entries] = key_of($3)
}
END {
  if (files < files_t && lines < lines_t) { printf "SIZE\t%d\t%d\nMODE\tsingle\n", files, lines; exit 0 }
  # Sort changes by path so two runs over the same diff print the same shards; then group in that
  # order, groups ranked plan-first.
  for (i = 1; i <= entries; i++) idx[i] = i
  for (i = 2; i <= entries; i++) { v = idx[i]; j = i - 1; while (j > 0 && epath[idx[j]] > epath[v]) { idx[j + 1] = idx[j]; j-- } idx[j + 1] = v }
  for (i = 1; i <= entries; i++) {
    e = idx[i]; k = ekey[e]
    if (!(k in gid)) { gc++; gid[k] = gc; gk[gc] = k; gn[gc] = 0; gl[gc] = 0 }
    g = gid[k]; gn[g]++; gl[g] += ew[e]
    gf[g, gn[g]] = (eold[e] == "") ? epath[e] : epath[e] "," eold[e]; gw[g, gn[g]] = ew[e]
  }
  for (i = 1; i <= gc; i++) ord[i] = i
  for (i = 2; i <= gc; i++) { v = ord[i]; j = i - 1; while (j > 0 && rank(gk[ord[j]]) > rank(gk[v])) { ord[j + 1] = ord[j]; j-- } ord[j + 1] = v }
  # Split any group that reaches a threshold into chunks below it. A chunk closes when adding the
  # next change would reach either threshold; one change above --lines is a chunk of its own.
  sc = 0
  for (oi = 1; oi <= gc; oi++) {
    g = ord[oi]
    if (gn[g] < files_t && gl[g] < lines_t) {
      sc++; sk[sc] = gk[g]; sn[sc] = gn[g]; sl[sc] = gl[g]
      for (i = 1; i <= gn[g]; i++) sf[sc, i] = gf[g, i]
      continue
    }
    part = 0; cur = 0
    for (i = 1; i <= gn[g]; i++) {
      if (cur == 0 || sn[cur] + 1 >= files_t || sl[cur] + gw[g, i] >= lines_t) {
        part++; sc++; cur = sc; sk[sc] = gk[g] "#" part; sn[sc] = 0; sl[sc] = 0
      }
      sn[cur]++; sl[cur] += gw[g, i]; sf[cur, sn[cur]] = gf[g, i]
    }
  }
  # Merge smallest into its neighbour (the next shard, or the previous when it is last) while more
  # than --max remain and the merged pair stays below the thresholds. Labels join with "+".
  n = sc
  while (n > max) {
    s = 0
    for (i = 1; i <= n; i++) {
      t = (i < n) ? i + 1 : i - 1
      if (sn[i] + sn[t] >= files_t || sl[i] + sl[t] >= lines_t) continue
      if (s == 0 || sl[i] < sl[s]) s = i
    }
    if (s == 0) {
      printf "shard-diff: %d files / %d lines need %d shards below --files %d and --lines %d, but --max is %d; raise --max or the thresholds knowingly\n", files, lines, n, files_t, lines_t, max > "/dev/stderr"
      exit 1
    }
    t = (s < n) ? s + 1 : s - 1
    a = (s < t) ? s : t; b = (s < t) ? t : s
    for (i = 1; i <= sn[b]; i++) sf[a, sn[a] + i] = sf[b, i]
    sn[a] += sn[b]; sl[a] += sl[b]; sk[a] = sk[a] "+" sk[b]
    for (i = b; i < n; i++) { sk[i] = sk[i + 1]; sn[i] = sn[i + 1]; sl[i] = sl[i + 1]; for (j = 1; j <= sn[i]; j++) sf[i, j] = sf[i + 1, j] }
    n--
  }
  # Nothing reaches stdout before the decision is final: a refusal above leaves it empty.
  printf "SIZE\t%d\t%d\nMODE\tsharded\n", files, lines
  for (i = 1; i <= n; i++) {
    list = sf[i, 1]; for (j = 2; j <= sn[i]; j++) list = list "," sf[i, j]
    printf "SHARD\t%d\t%s\t%s\n", i, sk[i], list
  }
}
'
