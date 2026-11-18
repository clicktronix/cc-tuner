#!/usr/bin/env bash
# The plan file's format, in one place: a validator and the parser that reads it back.
#
#   plan-lint.sh check         <file>   exit 0 if the plan parses, otherwise print what is wrong
#   plan-lint.sh slices        <file>   emit the parsed slices for the SessionStart hook
#   plan-lint.sh ready-batches <file>   emit the first proven-safe ready batch
#   plan-lint.sh owned         <file>   emit each slice's Owned paths for shard-diff.sh
#
# Four modes, one parser, on purpose. If a caller grew its own reader, a plan the linter accepted
# could still restore or run wrongly, and nothing would say so. `ready-batches` exists because the
# rule "open slices whose blockers are all done" was prose in two skills and arithmetic the model did
# by hand, which is how a blocked slice gets started; it emits only slices whose literal Owned path
# prefixes are proven pairwise disjoint.
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
# The grammar is exact: `Slice` and the field names are capitalised as written and start their line,
# without a bullet or emphasis, and a slice with no blockers writes `none` in lower case. A near miss
# (`### Slice 1`, `- **Owned paths:** x`) is an error that names the expected form, never a line the
# parser quietly skips. `Blocked by: Slice 1` is read as `1`.
# A slice ends at the next `#` or `##` heading: checkboxes under `## Deliver` or `## Follow-ups` are
# that section's, not the last slice's, and `slices` reports the open ones as OPEN records. Fenced
# code blocks are not parsed.
# There is no status field: a slice is done when every one of its criteria is ticked. A second record
# of the same fact is one that goes stale.
#
# `slices` output is tab-separated, one record per line, stable for `while IFS=<tab> read`:
#
#   SLICE<TAB><number><TAB>open|done<TAB><blocked-by csv or ->|<TAB><title>
#   CRIT<TAB><number><TAB>open|done<TAB><criterion text>
#   OPEN<TAB><section title><TAB><text>      an unticked checkbox under a `##` section that is not a
#                                            slice, after every slice record
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

MODE="${1:-}"
FILE="${2:-}"
EXPECTED_SPEC=""
EXPECTED_BRANCH=""
ACTIVE=""
LOCAL_ONLY=0

die() { printf 'plan-lint: %s\n' "$1" >&2; exit 1; }
usage() { die "usage: plan-lint.sh check|slices|ready-batches|owned <file> [--spec <path> --branch <name> [--local-only]] [--active <n,n,...>]"; }
help() {
  printf '%s\n' \
    'usage: plan-lint.sh check|slices|ready-batches|owned <file> [--spec <path> --branch <name> [--local-only]] [--active <n,n,...>]' \
    '' \
    'check: exit 0 when the plan parses, otherwise one line per error and exit 1.' \
    'slices: SLICE and CRIT records for every slice, then one OPEN record per unticked checkbox' \
    'under a "##" section that is not a slice. ready-batches: one BATCH line and the SLICE records' \
    'that may start now; nothing when no slice is ready.' \
    '' \
    'A slice is "## Slice <n> — <title>" followed by its field lines, each at the start of a line:' \
    '  Blocked by: none | <n>[, <n>...]     Owned paths: <path>[, <path>...]' \
    '  Deciding check: <command>            Delivers: <behaviour>' \
    'and one "- [ ]" line per acceptance criterion. The slice ends at the next "#" or "##" heading;' \
    'checkboxes under another "##" section (Verify, Deliver) are tracked apart from the slices.' \
    'Fenced code blocks are skipped.' \
    '' \
    'Owned paths: comma-separated repo-relative literal paths or directory prefixes.' \
    'Brackets, parentheses, @, + and = are literal characters (Next.js `[locale]`, `(shell)`).' \
    'Spaces within names and Unicode are allowed. Commas separate entries; surrounding spaces' \
    'are ignored. No glob operators (*, ?, braces), absolute paths, control characters, dot' \
    'components, or empty path components.' \
    'Use Owned paths: . by itself for whole-repository ownership, e.g. for a top-level name' \
    'containing a comma or edge whitespace. The slice runs alone in this repository.' \
    '' \
    'owned: one OWNED<TAB><slice><TAB><path,...> line per slice in plan order, paths as the plan' \
    'wrote them, so a consumer (shard-diff.sh) never re-parses the grammar. Refuses an invalid plan.' \
    '' \
    '--spec: the plan must name this spec; a full_test_cadence line in it must read per-candidate' \
    'or per-batch. The plan and spec must match their files in HEAD. --local-only checks only' \
    'the working files for pre-commit authoring or work with manual commit approval.' \
    '' \
    '--active: slice numbers already running (ready-batches only). They are excluded from the' \
    'result, and so is any slice whose Owned paths overlap theirs.' \
    'An empty result with --active does not mean the plan is done: open slices may all be active' \
    'or path-blocked, and the caller must read the plan, not the batch, to tell.'
}

case "$MODE" in --help|-h) help; exit 0 ;; check|slices|ready-batches|owned) ;; *) usage ;; esac
[ -n "$FILE" ] || usage
shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) [ $# -ge 2 ] && [ -n "$2" ] || die "--spec requires a non-empty path"; EXPECTED_SPEC="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] && [ -n "$2" ] || die "--branch requires a non-empty name"; EXPECTED_BRANCH="$2"; shift 2 ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    --active)
      [ $# -ge 2 ] && [ -n "$2" ] || die "--active requires a comma-separated list of slice numbers"
      case "$2" in *[!0-9,]*|,*|*,|*,,*) die "--active must be slice numbers separated by commas, got '$2'" ;; esac
      ACTIVE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ "$MODE" = check ] || { [ -z "$EXPECTED_SPEC$EXPECTED_BRANCH" ] || usage; }
# The active set only means something to the readiness mode. Accepting it elsewhere would let a
# caller believe `check` or `slices` had honoured it.
[ "$MODE" = ready-batches ] || [ -z "$ACTIVE" ] || die "--active applies to ready-batches only"
[ "$LOCAL_ONLY" -eq 0 ] || [ -n "$EXPECTED_SPEC" ] || die "--local-only requires --spec"
if [ "$MODE:$FILE" != "slices:-" ]; then
  [ -f "$FILE" ] || die "no such plan file: $FILE"
  case "$FILE" in /*|./*|../*) ;; *) FILE="./$FILE" ;; esac
fi

require_committed_file() {
  local path="$1" kind="$2" entry blob actual
  [ ! -L "$ROOT/$path" ] || die "$kind is a symbolic link: $path"
  entry="$(git -C "$ROOT" --literal-pathspecs ls-tree --full-tree "$REV" -- "$path")" ||
    die "cannot inspect $kind in HEAD: $path"
  case "$entry" in
    '100644 blob '*|'100755 blob '*) ;;
    *) die "$kind is not a regular file in HEAD: $path" ;;
  esac
  blob="$(git -C "$ROOT" rev-parse --verify "$REV:$path")" || die "cannot read $kind in HEAD: $path"
  actual="$(git -C "$ROOT" hash-object --no-filters -- "$ROOT/$path")" || die "cannot hash $kind: $path"
  if [ "$actual" != "$blob" ]; then
    # Markdown reads LF and CRLF equivalently. Git clean filters can rewrite more than that
    # and can run commands, so compare normalised bytes without calling the filters.
    actual="$(markdown_hash < "$ROOT/$path")" || die "cannot hash $kind: $path"
    blob="$(committed_markdown_hash "$blob")" || die "cannot read $kind in HEAD: $path"
  fi
  [ "$actual" = "$blob" ] || die "$kind differs from HEAD: $path"
}

markdown_hash() {
  set -o pipefail
  LC_ALL=C sed $'s/\r$//' | git -C "$ROOT" hash-object --stdin
}

committed_markdown_hash() {
  set -o pipefail
  git -C "$ROOT" cat-file blob "$1" | markdown_hash
}

if [ -n "$EXPECTED_SPEC" ]; then
  # `./docs/x.md` and `docs/x.md` are one path; the plan header is normalised the same way below.
  while [ "${EXPECTED_SPEC#./}" != "$EXPECTED_SPEC" ]; do EXPECTED_SPEC="${EXPECTED_SPEC#./}"; done
  [ -n "$EXPECTED_SPEC" ] || die "--spec requires a non-empty path"
  case "/$EXPECTED_SPEC/" in //*|*/../*|*/./*|*//*) die "--spec must be a repo-relative path" ;; esac
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$ROOT" ] || die "--spec requires a git repository"
  [ -f "$ROOT/$EXPECTED_SPEC" ] || die "the expected spec does not exist: $EXPECTED_SPEC"
  if [ "$LOCAL_ONLY" -eq 0 ]; then
    ROOT="$(cd "$ROOT" && pwd -P)" || die "cannot read repository root"
    REV="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null)" || die "cannot read HEAD"
    plan_dir="$(cd "$(dirname "$FILE")" && pwd -P)" || die "cannot read plan directory"
    case "$plan_dir/" in "$ROOT/"*) ;; *) die "plan is outside the repository: $FILE" ;; esac
    plan_path="$plan_dir/${FILE##*/}"
    require_committed_file "${plan_path#"$ROOT/"}" "plan"
    require_committed_file "$EXPECTED_SPEC" "spec"
  fi
  # The one Run config field /run reads as a closed set. A misspelt value would silently fall back to
  # the default cadence, so it is refused here, where the run starts.
  CADENCE_COUNT="$(grep -c '^full_test_cadence:' "$ROOT/$EXPECTED_SPEC")"
  CADENCE="$(sed -n 's/^full_test_cadence:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$ROOT/$EXPECTED_SPEC" | head -n 1)"
fi

# One awk pass produces the diagnostics and every record mode. Splitting them into separate programs
# is how validation, recovery and execution would drift.
PLAN_EXPECTED_SPEC="$EXPECTED_SPEC" awk -v mode="$MODE" -v expected_branch="$EXPECTED_BRANCH" -v active_csv="$ACTIVE" \
    -v cadence_count="${CADENCE_COUNT:-0}" -v cadence="${CADENCE:-}" '
BEGIN { expected_spec = ENVIRON["PLAN_EXPECTED_SPEC"] }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function literal_path(p) {
  if (p == "" || p == "<REPLACE_ME>" || p ~ /^\// || p ~ /\/\//) return 0
  if (p ~ /[[:cntrl:]*?{}]/) return 0
  if (p ~ /(^|\/)\.\.?(\/|$)/) return 0
  return 1
}
function normal_path(p) { sub(/\/+$/, "", p); return p "/" }
function owned_overlap(a, b,   an, bn, av, bv, ai, bi, ap, bp) {
  if (owned[a] == "." || owned[b] == ".") return 1
  an = split(owned[a], av, /[ \t]*,[ \t]*/)
  bn = split(owned[b], bv, /[ \t]*,[ \t]*/)
  for (ai = 1; ai <= an; ai++) {
    ap = normal_path(trim(av[ai]))
    for (bi = 1; bi <= bn; bi++) {
      bp = normal_path(trim(bv[bi]))
      if (index(ap, bp) == 1 || index(bp, ap) == 1) return 1
    }
  }
  return 0
}
# missing(slice, field, hint): the error for a slice without a field, naming the near miss when the
# slice has one.
function missing(n, key, hint) {
  if ((n, key) in near)
    return "slice " n ": \"" near[n, key] "\" is not read as a field; write \"" key ": <value>\" at the start of the line, without a bullet or emphasis"
  return "slice " n " has no \"" key "\" line" hint
}
function emit_open_slice(n,   b, m, parts, j) {
  b = blocked[n]
  if (b == "none") b = "-"
  else {
    m = split(b, parts, /[ \t]*,[ \t]*/); b = ""
    for (j = 1; j <= m; j++) b = (b == "") ? trim(parts[j]) : b "," trim(parts[j])
  }
  printf "SLICE\t%s\topen\t%s\t%s\n", n, b, titles[n]
}

# A fenced block is an example, not the plan: a `## Slice 2` or a `- [ ]` inside one used to become
# a phantom slice or an extra criterion.
{ sub(/\r$/, "") }
/^[ \t]*(```|~~~)/ {
  marker = $0
  sub(/^[ \t]*/, "", marker)
  match(marker, /^(`+|~+)/)
  kind = substr(marker, 1, 1)
  width = RLENGTH
  tail = substr(marker, width + 1)
  if (fence_width) {
    if (kind == fence_kind && width >= fence_width && tail ~ /^[ \t]*$/) fence_width = 0
    next
  }
  if (kind == "~" || tail !~ /`/) {
    fence_kind = kind
    fence_width = width
    next
  }
}
fence_width { next }

/^\*\*Spec:\*\*/ {
  if (++spec_lines > 1) err[++e] = "plan has more than one Spec header"
  plan_spec = $0; sub(/^\*\*Spec:\*\*[ \t]*/, "", plan_spec); plan_spec = trim(plan_spec)
  while (plan_spec ~ /^\.\//) sub(/^\.\//, "", plan_spec)
  if (count > 0) err[++e] = "Spec header must appear before the first slice"
  next
}
/^\*\*Branch:\*\*/ {
  if (++branch_lines > 1) err[++e] = "plan has more than one Branch header"
  plan_branch = $0; sub(/^\*\*Branch:\*\*[ \t]*/, "", plan_branch); plan_branch = trim(plan_branch)
  if (count > 0) err[++e] = "Branch header must appear before the first slice"
  next
}

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

# A numbered slice heading that is not written as one (`### Slice 1`, `## slice 1`). Skipping it
# left its criteria to be reported as "checkbox outside any slice", which names the symptom and hides
# the cause. A heading that merely starts with the word (`# Slice unit cap`) is an ordinary heading.
/^#+[ \t]*[Ss][Ll][Ii][Cc][Ee][ \t]*#?[0-9]/ && !/^##[ \t]+Slice[ \t]+[0-9]+/ {
  err[++e] = "line " NR ": \"" trim($0) "\" is not a slice heading; write \"## Slice <n> — <title>\" (two #, capital S, a number)"
  cur = ""; other = "-"
  next
}

/^##[ \t]+Slice[ \t]+[0-9]+/ {
  n = $0; sub(/^##[ \t]+Slice[ \t]+/, "", n); sub(/[^0-9].*$/, "", n)
  if (n ~ /^0[0-9]+$/)
    err[++e] = "slice " n " has a leading zero; use the canonical number " (n + 0)
  heading_tail = $0; sub(/^##[ \t]+Slice[ \t]+[0-9]+/, "", heading_tail)
  # Alternation, not a bracket expression: awk in the C locale (and mawk in any) reads a bracket
  # bytewise, matched one byte of the dash and left the other two at the front of the title.
  if (heading_tail !~ /^[ \t]+(-|—|–|:)[ \t]*[^ \t]/)
    err[++e] = "slice " n " heading needs a separator and title (use \"## Slice " n " — Title\")"
  title = heading_tail; sub(/^[ \t]*(-|—|–|:)[ \t]*/, "", title)

  if (n in seen) { err[++e] = "slice " n " is declared twice" }
  seen[n] = 1
  order[++count] = n
  titles[n] = trim(title)
  cur = n
  next
}

# Any other `#` or `##` heading ends the slice. A section of its own (Verify, Deliver,
# Follow-ups) keeps its checkboxes: open ones are reported as OPEN records, so work the plan tracks
# outside its slices is still restored, without holding the last slice open. `###` and deeper stay
# inside the slice.
/^##?([ \t]|$)/ {
  cur = ""; other = $0; sub(/^##?[ \t]*/, "", other); other = trim(other)
  next
}

# A field line with a bullet, emphasis or other capitals is remembered, and reported when the slice
# turns out to have no such field: "has no Owned paths line" beside a line that plainly had it sent
# the reader looking for something else. With the plain field present it is prose and stays unread.
cur != "" && $0 !~ /^[ \t]*(Owned paths|Deciding check|Delivers|Blocked[ \t]+by)[ \t]*:/ {
  bare = $0; sub(/^[ \t]*([-*+][ \t]+)?[*_`]*/, "", bare); low = tolower(bare)
  if (low ~ /^(owned paths|deciding check|delivers|blocked[ \t]+by)[*_`]*[ \t]*:/) {
    key = low; sub(/[*_`]*[ \t]*:.*$/, "", key)
    key = (key ~ /^owned/) ? "Owned paths" : (key ~ /^deciding/) ? "Deciding check" : (key ~ /^delivers/) ? "Delivers" : "Blocked by"
    if (!((cur, key) in near)) near[cur, key] = trim($0)
    next
  }
}

/^[ \t]*(Owned paths|Deciding check|Delivers)[ \t]*:/ {
  if (cur == "") next
  k = $0; sub(/[ \t]*:.*$/, "", k); sub(/^[ \t]+/, "", k)
  v = $0; sub(/^[^:]*:[ \t]*/, "", v)
  if (trim(v) != "") has[cur, k] = 1
  if (k == "Owned paths") {
    if (cur in owned) err[++e] = "slice " cur " has more than one \"Owned paths\" line"
    else owned[cur] = trim(v)
  }
  next
}

/^[ \t]*Blocked[ \t]+by[ \t]*:/ {
  if (cur == "") { if (other == "") err[++e] = "\"Blocked by\" before the first slice heading"; next }
  if (cur in blocked) { err[++e] = "slice " cur " has more than one \"Blocked by\" line"; next }
  v = $0; sub(/^[ \t]*Blocked[ \t]+by[ \t]*:[ \t]*/, "", v); v = trim(v)
  # `Slice 1` is the number 1, normalised here so every mode and the restore hook read one spelling.
  # Only that exact shape: `slice-1` stays an error rather than prose a number is salvaged from.
  if (v != "" && v != "none") {
    m = split(v, parts, /[ \t]*,[ \t]*/); v = ""
    for (j = 1; j <= m; j++) {
      p = trim(parts[j]); if (p ~ /^[Ss]lice[ \t]+[0-9]+$/) sub(/^[Ss]lice[ \t]+/, "", p)
      v = (j == 1) ? p : v ", " p
    }
  }
  blocked[cur] = v
  next
}

/^[ \t]*-[ \t]*\[[ xX]\]/ {
  # A checkbox outside a slice is the mistake that loses the graph: acceptance criteria read as
  # slices, and the restore comes back with no titles and no edges.
  if (cur == "") {
    if (other == "") err[++e] = "checkbox outside any slice: " trim($0)
    else if (other != "-" && $0 !~ /^[ \t]*-[ \t]*\[[xX]\]/) {
      t = $0; sub(/^[ \t]*-[ \t]*\[ \][ \t]*/, "", t)
      osec[++oc] = other; otext[oc] = trim(t)
    }
    next
  }
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
  # Header ownership is a delivery check. Read-only recovery must still understand plans written by
  # versions before these headers existed; `/run` always calls `check` before an executable mode.
  # `owned` feeds a delivery-time consumer (shard-diff.sh), so it holds the plan to the same bar.
  if ((mode == "check" || mode == "owned") && (spec_lines != 1 || plan_spec == ""))
    err[++e] = "plan needs one non-empty **Spec:** header before its slices"
  if ((mode == "check" || mode == "owned") && (branch_lines != 1 || plan_branch == ""))
    err[++e] = "plan needs one non-empty **Branch:** header before its slices"
  if (expected_spec != "" && plan_spec != expected_spec)
    err[++e] = "plan names spec \"" plan_spec "\", expected \"" expected_spec "\""
  if (expected_branch != "" && plan_branch != expected_branch)
    err[++e] = "plan names branch \"" plan_branch "\", expected \"" expected_branch "\""
  if (cadence_count > 1)
    err[++e] = "spec " expected_spec " has more than one full_test_cadence line"
  else if (cadence_count == 1 && cadence !~ /^(per-candidate|per-batch)$/)
    err[++e] = "spec " expected_spec " sets full_test_cadence to \"" cadence "\"; expected per-candidate or per-batch"

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
      if (!((n SUBSEP req[r]) in has)) err[++e] = missing(n, req[r], "")
    if (owned[n] != "" && owned[n] != ".") {
      opn = split(owned[n], oparts, /[ \t]*,[ \t]*/)
      for (oi = 1; oi <= opn; oi++) {
        op = trim(oparts[oi])
        if (!literal_path(op))
          err[++e] = "slice " n " has non-literal Owned path \"" op "\"; use repo-relative paths without globs, dot components, control characters or empty components"
      }
    }
    if (!(n in blocked)) {
      err[++e] = missing(n, "Blocked by", " (use \"Blocked by: none\" when it has none)")
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

  # `ready-batches` answers one question: which slices may start now. A slice is ready when it is
  # open and every slice it names is done. At least one exists while anything is open (if every open
  # slice had an open blocker the graph would descend forever, which is the cycle `check` refuses),
  # so without --active "open but nothing ready" is not a case.
  if (mode == "ready-batches") {
    # The plan knows open and done. It does not know RUNNING: a slice a unit is working on is still
    # open, so without help the ready set would hand it out again. The caller is the only party that
    # knows which slices it dispatched, so it names them; everything else about safety stays here,
    # where the arithmetic lives. A named slice that does not exist, or is already done, is a stale
    # active set, and a stale active set is exactly the state that launches a duplicate writer.
    ac = 0
    if (active_csv != "") {
      ac = split(active_csv, aparts, ",")
      for (ai = 1; ai <= ac; ai++) {
        a = aparts[ai] + 0
        if (!(a in seen)) { print "plan-lint: active slice " a " does not exist in this plan" > "/dev/stderr"; exit 1 }
        if (total[a] > 0 && done[a] == total[a]) { print "plan-lint: active slice " a " is already done; refresh the active set" > "/dev/stderr"; exit 1 }
        active[a] = 1
        aset[ai] = a
      }
    }

    fc = 0
    open_left = 0
    for (i = 1; i <= count; i++) {
      n = order[i]
      if (total[n] > 0 && done[n] == total[n]) continue
      open_left++
      if (n in active) continue
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

    if (fc > 0) {
      # A batch must be disjoint from what is already being written, not only within itself: a ready
      # slice sharing a path prefix with a running one is the same collision one turn later.
      batch_count = 0
      for (fi = 1; fi <= fc; fi++) {
        n = rdy[fi]
        safe = 1
        for (ai = 1; ai <= ac; ai++)
          if (owned_overlap(n, aset[ai])) { safe = 0; break }
        for (bj = 1; safe && bj <= batch_count; bj++)
          if (owned_overlap(n, batch[bj])) { safe = 0; break }
        if (safe) batch[++batch_count] = n
      }
      if (batch_count == 0) {
        print "plan-lint: no ready slice outside the active set (" open_left " open, " ac " active); this is not completion" > "/dev/stderr"
        exit 0
      }
      ids = batch[1]
      for (bi = 2; bi <= batch_count; bi++) ids = ids "," batch[bi]
      if (batch_count > 1)
        printf "BATCH\t%s\tparallel\towned paths proven disjoint\n", ids
      else
        printf "BATCH\t%s\tserial\tno second ready slice has proven-disjoint owned paths\n", ids
      for (bi = 1; bi <= batch_count; bi++) emit_open_slice(batch[bi])
      exit 0
    }

    if (ac > 0 && open_left > 0)
      print "plan-lint: no ready slice outside the active set (" open_left " open, " ac " active); this is not completion" > "/dev/stderr"
    exit 0
  }

  # `owned` hands the Owned paths to another script. shard-diff.sh groups a diff by them, and a
  # second reader of the grammar is how a plan the linter accepted would shard differently from how
  # it is scheduled. Trimmed per path, otherwise verbatim: the consumer applies the same prefix rule.
  if (mode == "owned") {
    for (i = 1; i <= count; i++) {
      n = order[i]
      opn = split(owned[n], oparts, /[ \t]*,[ \t]*/); ol = ""
      for (oi = 1; oi <= opn; oi++) ol = (ol == "") ? trim(oparts[oi]) : ol "," trim(oparts[oi])
      printf "OWNED\t%s\t%s\n", n, ol
    }
    exit 0
  }

  for (i = 1; i <= count; i++) {
    n = order[i]
    state = (total[n] > 0 && done[n] == total[n]) ? "done" : "open"
    # Normalised, not raw: the restore hook reads this field and does not re-parse it.
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
  for (i = 1; i <= oc; i++) printf "OPEN\t%s\t%s\n", osec[i], otext[i]
}
' "$FILE"
