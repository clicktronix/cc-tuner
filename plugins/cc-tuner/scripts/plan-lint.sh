#!/usr/bin/env bash
# The plan file's format, in one place: a validator and the parser that reads it back.
#
#   plan-lint.sh check  <file>   exit 0 if the plan parses, otherwise print what is wrong
#   plan-lint.sh slices <file>   emit the parsed slices for the SessionStart hook
#
# Two modes, one parser, on purpose. If the hook grew its own reader, a plan the linter accepted could
# still restore wrongly, and nothing would say so.
#
# The format:
#
#   ## Slice 3 — Wire the retry budget
#   Blocked by: 1, 2
#   Owned paths: src/retry/, tests/retry/
#   Deciding check: pnpm test tests/retry
#   Delivers: a request that exhausts its budget fails with one typed error.
#
#   - [ ] budget is read from config, not hardcoded
#   - [ ] exhaustion is observable in the returned error
#
# `Blocked by` is slice-level; `- [ ]` lines are acceptance criteria INSIDE a slice, never slices.
# There is no status field: a slice is done when every one of its criteria is ticked. A second record
# of the same fact is one that goes stale.
#
# `slices` output is tab-separated, one record per line, stable for `while IFS=<tab> read`:
#
#   SLICE<TAB><number><TAB>open|done<TAB><blocked-by csv or ->|<TAB><title>
#   CRIT<TAB><number><TAB>open|done<TAB><criterion text>
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

MODE="${1:-}"
FILE="${2:-}"

die() { printf 'plan-lint: %s\n' "$1" >&2; exit 1; }

case "$MODE" in check|slices) ;; *) die "usage: plan-lint.sh check|slices <file>" ;; esac
[ -n "$FILE" ] || die "usage: plan-lint.sh check|slices <file>"
[ -f "$FILE" ] || die "no such plan file: $FILE"

# One awk pass produces both the diagnostics and the records; `check` prints the first, `slices` the
# second. Splitting them into two programs is how the two would drift.
awk -v mode="$MODE" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# reaches(from, target, ...) -- does `from` transitively block back to `target`?
function reaches(from, target, blk, ex, path, depth,   m, parts, j, p) {
  if (depth > 0 && from == target) return 1
  if (from in path) return 0
  path[from] = 1
  if (!(from in blk) || blk[from] == "" || blk[from] ~ /^([Nn]one|-)$/) return 0
  m = split(blk[from], parts, /[ \t]*,[ \t]*/)
  for (j = 1; j <= m; j++) {
    p = parts[j]; gsub(/[^0-9]/, "", p)
    if (p == "" || !(p in ex)) continue
    if (reaches(p, target, blk, ex, path, depth + 1)) return 1
  }
  return 0
}

/^##[ \t]+[Ss]lice[ \t]+[0-9]+/ {
  n = $0; sub(/^##[ \t]+[Ss]lice[ \t]+/, "", n); sub(/[^0-9].*$/, "", n) + 0
  title = $0; sub(/^##[ \t]+[Ss]lice[ \t]+[0-9]+[ \t]*/, "", title)
  sub(/^[-—–:][ \t]*/, "", title)

  if (n in seen) { err[++e] = "slice " n " is declared twice" }
  seen[n] = 1
  order[++count] = n
  titles[n] = trim(title)
  cur = n
  next
}

/^[ \t]*(Owned paths|Deciding check|Delivers)[ \t]*:/ {
  if (cur == "") next
  k = $0; sub(/[ \t]*:.*$/, "", k); sub(/^[ \t]+/, "", k)
  v = $0; sub(/^[^:]*:[ \t]*/, "", v)
  if (trim(v) != "") has[cur, k] = 1
  next
}

/^[ \t]*[Bb]locked[ \t]+by[ \t]*:/ {
  if (cur == "") { err[++e] = "\"Blocked by\" before the first slice heading"; next }
  v = $0; sub(/^[ \t]*[Bb]locked[ \t]+by[ \t]*:[ \t]*/, "", v)
  blocked[cur] = trim(v)
  next
}

/^[ \t]*-[ \t]*\[[ xX]\]/ {
  # A checkbox outside a slice is the mistake that loses the graph: acceptance criteria read as
  # slices, and the restore comes back with no titles and no edges.
  if (cur == "") { err[++e] = "checkbox outside any slice: " trim($0); next }
  ticked = ($0 ~ /\[[xX]\]/) ? 1 : 0
  t = $0; sub(/^[ \t]*-[ \t]*\[[ xX]\][ \t]*/, "", t)
  ci[cur, ++cn[cur]] = trim(t)
  ct[cur, cn[cur]]   = ticked
  total[cur]++
  if (ticked) done[cur]++
  next
}

END {
  if (count == 0) err[++e] = "no slices found (expected headings like \"## Slice 1 — Title\")"

  for (i = 1; i <= count; i++) {
    n = order[i]
    # A fourth check, beyond the three the plan names. Progress is derived from the checkboxes, so a
    # slice with none can never be done: it stays open forever and the restore hook resurrects it in
    # every session. A plan that cannot finish is worth catching where it is written.
    if (total[n] + 0 == 0) err[++e] = "slice " n " has no acceptance criteria, so it can never be done"
    # Owned paths is load-bearing: /cc-tuner:run decides which slices may run in parallel by whether
    # theirs overlap. Deciding check and Delivers are what make a slice checkable and demoable.
    split("Owned paths|Deciding check|Delivers", req, "|")
    for (r = 1; r <= 3; r++)
      if (!((n SUBSEP req[r]) in has)) err[++e] = "slice " n " has no \"" req[r] "\" line"
    if (!(n in blocked)) {
      err[++e] = "slice " n " has no \"Blocked by\" line (use \"Blocked by: none\" when it has none)"
      continue
    }
    b = blocked[n]
    if (b ~ /^([Nn]one|-)$/ || b == "") continue
    m = split(b, parts, /[ \t]*,[ \t]*/)
    for (j = 1; j <= m; j++) {
      p = parts[j]; gsub(/[^0-9]/, "", p)
      if (p == "")        { err[++e] = "slice " n " blocked by \"" parts[j] "\", which is not a slice number"; continue }
      if (p == n)         { err[++e] = "slice " n " is blocked by itself"; continue }
      if (!(p in seen))   { err[++e] = "slice " n " is blocked by slice " p ", which does not exist" }
    }
  }

  # Cycles. A plan whose slices block each other has no frontier at all: nothing can ever start, and
  # the restore hook would resurrect the whole graph every session. Only self-blocking was caught
  # before, which is the one-hop case of this.
  for (i = 1; i <= count; i++) {
    n = order[i]
    delete seenpath
    if (reaches(n, n, blocked, seen, seenpath, 0))
      err[++e] = "slice " n " is part of a blocking cycle, so no slice in it can ever start"
  }

  if (mode == "check") {
    for (i = 1; i <= e; i++) print "plan-lint: " err[i] > "/dev/stderr"
    exit (e > 0) ? 1 : 0
  }

  # `slices` refuses to emit from a plan that does not parse. Restoring half a graph is worse than
  # restoring none: the second is visible, the first is not.
  if (e > 0) {
    print "plan-lint: refusing to parse an invalid plan; run check" > "/dev/stderr"
    exit 1
  }

  for (i = 1; i <= count; i++) {
    n = order[i]
    state = (total[n] > 0 && done[n] == total[n]) ? "done" : "open"
    b = (n in blocked) ? blocked[n] : ""
    if (b ~ /^([Nn]one)$/ || b == "") b = "-"
    printf "SLICE\t%s\t%s\t%s\t%s\n", n, state, b, titles[n]
    for (k = 1; k <= cn[n]; k++) {
      printf "CRIT\t%s\t%s\t%s\n", n, (ct[n, k] ? "done" : "open"), ci[n, k]
    }
  }
}
' "$FILE"
