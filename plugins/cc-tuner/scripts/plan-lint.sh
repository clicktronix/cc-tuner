#!/usr/bin/env bash
# The plan file's format, in one place: a validator and the parser that reads it back.
#
#   plan-lint.sh check    <file>   exit 0 if the plan parses, otherwise print what is wrong
#   plan-lint.sh slices   <file>   emit the parsed slices for the SessionStart hook
#   plan-lint.sh frontier <file>   emit every slice that may start now, lowest number first
#
# Three modes, one parser, on purpose. If a caller grew its own reader, a plan the linter accepted
# could still restore or run wrongly, and nothing would say so. `frontier` exists because the rule
# "lowest-numbered open slice whose blockers are all done" was prose in two skills and arithmetic the
# model did by hand -- and doing it by hand is how a blocked slice gets started.
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
# The grammar is exact: `Slice` and `Blocked by` are capitalised as written, and a slice with no
# blockers writes `none` in lower case. Nothing else is a synonym.
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

case "$MODE" in check|slices|frontier) ;; *) die "usage: plan-lint.sh check|slices|frontier <file>" ;; esac
[ -n "$FILE" ] || die "usage: plan-lint.sh check|slices|frontier <file>"
[ -f "$FILE" ] || die "no such plan file: $FILE"

# One awk pass produces both the diagnostics and the records; `check` prints the first, `slices` the
# second. Splitting them into two programs is how the two would drift.
awk -v mode="$MODE" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# reaches(from, target, ...) -- does `from` transitively block back to `target`? Self-blocking is its
# one-hop case; a separate check for it reported the same plan twice.
function reaches(from, target, blk, ex, path, depth,   m, parts, j, p) {
  if (depth > 0 && from == target) return 1
  if (from in path) return 0
  path[from] = 1
  if (!(from in blk) || blk[from] == "" || blk[from] == "none") return 0
  m = split(blk[from], parts, /[ \t]*,[ \t]*/)
  for (j = 1; j <= m; j++) {
    p = trim(parts[j])
    if (p == "" || !(p in ex)) continue
    if (reaches(p, target, blk, ex, path, depth + 1)) return 1
  }
  return 0
}

/^##[ \t]+Slice[ \t]+[0-9]+/ {
  n = $0; sub(/^##[ \t]+Slice[ \t]+/, "", n); sub(/[^0-9].*$/, "", n)
  heading_tail = $0; sub(/^##[ \t]+Slice[ \t]+[0-9]+/, "", heading_tail)
  if (heading_tail !~ /^[ \t]+[-—–:][ \t]*[^ \t]/)
    err[++e] = "slice " n " heading needs a separator and title (use \"## Slice " n " — Title\")"
  title = heading_tail; sub(/^[ \t]*[-—–:][ \t]*/, "", title)

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

/^[ \t]*Blocked[ \t]+by[ \t]*:/ {
  if (cur == "") { err[++e] = "\"Blocked by\" before the first slice heading"; next }
  if (cur in blocked) { err[++e] = "slice " cur " has more than one \"Blocked by\" line"; next }
  v = $0; sub(/^[ \t]*Blocked[ \t]+by[ \t]*:[ \t]*/, "", v)
  blocked[cur] = trim(v)
  next
}

/^[ \t]*-[ \t]*\[[ xX]\]/ {
  # A checkbox outside a slice is the mistake that loses the graph: acceptance criteria read as
  # slices, and the restore comes back with no titles and no edges.
  if (cur == "") { err[++e] = "checkbox outside any slice: " trim($0); next }
  # The box decides, not the text beside it. Scanning the whole line marked `- [ ] handle the [x]
  # flag` as done, and a slice is done when all its criteria are, so the plan finished itself.
  ticked = ($0 ~ /^[ \t]*-[ \t]*\[[xX]\]/) ? 1 : 0
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
    # One spelling, exactly: `none`. `None` and an empty value used to pass, so the file could say
    # three different things and mean one -- and the reader that has to agree with this parser is a
    # model writing the plan, which will reproduce whatever it sees accepted.
    if (b == "none") continue
    if (b == "") {
      err[++e] = "slice " n " has an empty \"Blocked by\" line (write \"Blocked by: none\")"
      continue
    }
    if (tolower(b) == "none") {
      err[++e] = "slice " n " writes no blockers as \"" b "\"; the only accepted spelling is \"none\""
      continue
    }
    m = split(b, parts, /[ \t]*,[ \t]*/)
    for (j = 1; j <= m; j++) {
      p = trim(parts[j])
      if (p !~ /^[0-9]+$/) { err[++e] = "slice " n " blocked by \"" parts[j] "\", which is not a slice number"; continue }
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

  # `frontier` answers one question: which slices may start now. A slice is ready when it is open and
  # every slice it names is done. At least one exists while anything is open -- if every open slice
  # had an open blocker the graph would descend forever, which is the cycle `check` already refuses
  # -- so "open but nothing ready" is not a case, and nothing here pretends it is.
  #
  # ALL of them, not the first: `references/placement.md` fans work out across independent slices, and
  # a frontier that returned one made that unreachable -- the second slice could not be had without
  # finishing the first. Which of these may run together is a question about their Owned paths, and
  # belongs to the caller; which may start at all is what this mode answers.
  if (mode == "frontier") {
    fc = 0
    for (i = 1; i <= count; i++) {
      n = order[i]
      if (total[n] > 0 && done[n] == total[n]) continue
      ready = 1
      if (blocked[n] != "none") {
        m = split(blocked[n], parts, /[ \t]*,[ \t]*/)
        for (j = 1; j <= m; j++) {
          p = trim(parts[j])
          if (!(total[p] > 0 && done[p] == total[p])) { ready = 0; break }
        }
      }
      if (ready) rdy[++fc] = n
    }

    # By number, not by the order the file happens to declare them in. Nothing stops a plan writing
    # Slice 3 above Slice 1, and every caller was promised the lowest number first.
    for (fi = 1; fi <= fc; fi++)
      for (fj = fi + 1; fj <= fc; fj++)
        if (rdy[fj] + 0 < rdy[fi] + 0) { ft = rdy[fi]; rdy[fi] = rdy[fj]; rdy[fj] = ft }

    for (fi = 1; fi <= fc; fi++) {
      n = rdy[fi]
      # The same normalised field `slices` emits, so one reader parses both modes.
      b = blocked[n]
      if (b == "none") { b = "-" } else {
        m = split(b, parts, /[ \t]*,[ \t]*/); b = ""
        for (j = 1; j <= m; j++) b = (b == "") ? trim(parts[j]) : b "," trim(parts[j])
      }
      printf "SLICE\t%s\topen\t%s\t%s\n", n, b, titles[n]
    }
    exit 0
  }

  for (i = 1; i <= count; i++) {
    n = order[i]
    state = (total[n] > 0 && done[n] == total[n]) ? "done" : "open"
    # Normalised, not raw. The restore hook reads this field and does not re-parse it: emitting the
    # text as written meant Blocked by: #1 validated here, because the check strips non-digits, and
    # then arrived at the hook as #1, which matched no slice, so the edge vanished silently.
    b = blocked[n]
    if (b == "none") { b = "-" } else {
      m = split(b, parts, /[ \t]*,[ \t]*/); b = ""
      for (j = 1; j <= m; j++) b = (b == "") ? trim(parts[j]) : b "," trim(parts[j])
    }
    printf "SLICE\t%s\t%s\t%s\t%s\n", n, state, b, titles[n]
    for (k = 1; k <= cn[n]; k++) {
      printf "CRIT\t%s\t%s\t%s\n", n, (ct[n, k] ? "done" : "open"), ci[n, k]
    }
  }
}
' "$FILE"
