#!/usr/bin/env bash
# The delivery-route key block: one owner of its text, its writer and its check.
#
#   route.sh canonical <gitlab|local>
#   route.sh write <gitlab|local|other> <task-flow.local.md> [body-file]
#   route.sh check <github|gitlab|local|other> [repo-root]
#
# Outside GitHub no script refuses a bad merge, so /cc-tuner:run follows a route text. That text lives
# in the plugin (skills/run/references/route-<host>.md) and is read from there at Delivery, never from a
# copy the candidate can edit. The repository keeps only a short key block in
# .claude/rules/task-flow.local.md between two markers:
#
#   <!-- cc-tuner:delivery-route <host> -->
#   Deliver only by /cc-tuner:run's <host> route (...); never by a web merge or a bare CLI merge.
#   <!-- /cc-tuner:delivery-route -->
#
# For `other` the body is the user's own description of how a candidate is opened, recorded, checked and
# merged, and it IS the route. The block is committed with task-flow.local.md, so task worktrees have it.
# Markers carry no version: nothing is copied from the plugin, so there is nothing to date.
#
# canonical   prints the gitlab/local block, the only place its text is written.
# write       gitlab/local: the canonical block. other: the block around a non-empty body file (exit 2
#             otherwise, nothing written). Replaces an existing block in place or appends one, and
#             changes nothing outside the markers except the legacy two-line header comment older setup
#             wrote ("setup never touches this file"), which becomes the current wording. The file is
#             rebuilt in a same-directory temp and moved over the original (mode kept), and the result is
#             run through `check` before success is claimed. Prints one word: written | replaced |
#             unchanged. A malformed existing block (marker counts differ, more than one block, closing
#             before opening) is refused with exit 3 and nothing is touched. Exit 1 on an operational
#             failure, 2 on a usage error.
# check       reads <repo-root>/.claude/rules/task-flow.local.md (CRLF tolerated) and prints ONE line,
#             stable for callers, with the exit code beside it:
#               current                      0   gitlab/local block equals canonical
#               present-other                0   other: a block is there, the user's words are not compared
#               none-needed                  0   github with no block: merge.sh is the route
#               missing                     10   no block (gitlab, local, other)
#               mismatch <block-host>       11   the block is for another host
#               drift                       12   gitlab/local block differs from canonical
#               malformed <opens> <closes>  13   marker counts differ, more than one block, or closing first
#               stale-on-github <host>      14   host github but a block exists: setup cannot remove it
#
# One program because the writer was prose bash in the setup reference and doctor kept its own sed
# extraction: the tests fed doctor a hand-built block, so the real producer never met the real checker,
# and doctor advised an install that the writer refused for a malformed block.
#
# Only sed, grep, tr, head, tail and cat for `check`: doctor runs it on a minimal PATH, which has no awk.
# bash 3.2 compatible: macOS ships 3.2.57. Seam: TMPDIR for scratch files.
set -u

OPEN_RE='^<!-- cc-tuner:delivery-route '
CLOSE_LINE='<!-- /cc-tuner:delivery-route -->'
CLOSE_RE='^<!-- /cc-tuner:delivery-route -->$'
LEGACY_RE='^<!-- Overrides and additions to [a-z-]*\.md live here; .*never touches this file\.$'
LEGACY_NEXT='     Typical content: board name/number + cached field IDs, label taxonomy, merge-policy exceptions. -->'

usage() {
  printf 'usage: route.sh canonical <gitlab|local>\n       route.sh write <gitlab|local|other> <task-flow.local.md> [body-file]\n       route.sh check <github|gitlab|local|other> [repo-root]\n' >&2
  exit 2
}
fail() { printf 'route: %s\n' "$1" >&2; exit "${2:-1}"; }

canonical() { # canonical <gitlab|local>
  printf '<!-- cc-tuner:delivery-route %s -->\n' "$1"
  printf "Deliver only by /cc-tuner:run's %s route (skills/run/references/route-%s.md in the cc-tuner plugin); never by a web merge or a bare CLI merge.\n" "$1" "$1"
  printf '%s\n' "$CLOSE_LINE"
}

header() { # the current wording of the task-flow.local.md header comment
  printf '%s\n' \
    '<!-- Overrides and additions to task-flow.md live here; setup writes only between cc-tuner markers' \
    '     (the delivery route) and caches board field IDs. Typical content: board name/number + cached field' \
    '     IDs, label taxonomy, merge-policy exceptions. -->'
}

count() { # count <regex> <file>: matching lines, always a number
  local n
  n="$(grep -c "$1" "$2" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# check_file <host> <file>: sets CHECK_LINE and CHECK_RC. <file> may be absent.
check_file() {
  local host="$1" file="$2" text opens closes first_open first_close block block_host
  text=""
  if [ -f "$file" ]; then text="$(tr -d '\r' < "$file")"; fi
  opens="$(printf '%s\n' "$text" | grep -c "$OPEN_RE" || true)"
  closes="$(printf '%s\n' "$text" | grep -c "$CLOSE_RE" || true)"
  opens="${opens:-0}"; closes="${closes:-0}"
  if [ "$opens" -ne "$closes" ] || [ "$opens" -gt 1 ]; then
    CHECK_LINE="malformed $opens $closes"; CHECK_RC=13; return
  fi
  if [ "$opens" -eq 1 ]; then
    first_open="$(printf '%s\n' "$text" | grep -n "$OPEN_RE" | head -n 1)"; first_open="${first_open%%:*}"
    first_close="$(printf '%s\n' "$text" | grep -n "$CLOSE_RE" | head -n 1)"; first_close="${first_close%%:*}"
    if [ "$first_close" -lt "$first_open" ]; then
      CHECK_LINE="malformed $opens $closes"; CHECK_RC=13; return
    fi
  fi
  if [ "$opens" -eq 0 ]; then
    if [ "$host" = github ]; then CHECK_LINE="none-needed"; CHECK_RC=0; else CHECK_LINE="missing"; CHECK_RC=10; fi
    return
  fi
  block="$(printf '%s\n' "$text" | sed -n "/$OPEN_RE/,\\#$CLOSE_RE#p")"
  block_host="$(printf '%s\n' "$block" | head -n 1 | sed -n 's/^<!-- cc-tuner:delivery-route \([a-z][a-z]*\).*/\1/p')"
  [ -n "$block_host" ] || block_host=unknown
  if [ "$host" = github ]; then CHECK_LINE="stale-on-github $block_host"; CHECK_RC=14; return; fi
  if [ "$block_host" != "$host" ]; then CHECK_LINE="mismatch $block_host"; CHECK_RC=11; return; fi
  if [ "$host" = other ]; then CHECK_LINE="present-other"; CHECK_RC=0; return; fi
  if [ "$block" = "$(canonical "$host")" ]; then CHECK_LINE="current"; CHECK_RC=0; else CHECK_LINE="drift"; CHECK_RC=12; fi
}

valid_host() { case "$1" in github|gitlab|local|other) return 0 ;; *) return 1 ;; esac; }

cmd_canonical() {
  case "${1:-}" in
    gitlab|local) canonical "$1" ;;
    *) usage ;;
  esac
}

cmd_check() {
  local host="${1:-}" root="${2:-}"
  valid_host "$host" || usage
  if [ -z "$root" ]; then root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository and no repo-root given" 2; fi
  check_file "$host" "$root/.claude/rules/task-flow.local.md"
  printf '%s\n' "$CHECK_LINE"
  exit "$CHECK_RC"
}

SCRATCH=""
cleanup() { if [ -n "$SCRATCH" ]; then rm -rf "$SCRATCH"; fi; if [ -n "${FINAL:-}" ]; then rm -f "$FINAL"; fi; }

cmd_write() {
  local host="${1:-}" file="${2:-}" body="${3:-}" dir
  case "$host" in
    gitlab|local|other) ;;
    github) fail "github has no route block: merge.sh is the route, nothing to write" 2 ;;
    *) usage ;;
  esac
  [ -n "$file" ] || usage
  [ -f "$file" ] || fail "$file does not exist: run the task-flow rule node first" 2
  if [ "$host" = other ]; then
    [ -n "$body" ] && [ -f "$body" ] && grep -q '[^[:space:]]' "$body" \
      || fail "host other needs a non-empty description file (how a candidate is opened, recorded, checked and merged); nothing was written" 2
    if grep -q 'cc-tuner:delivery-route' "$body"; then
      fail "the description contains a delivery-route marker; remove it, nothing was written" 2
    fi
  fi
  dir="$(dirname "$file")"
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/cc-tuner-route.XXXXXX")" || fail "cannot create a scratch directory"
  trap cleanup EXIT

  local S="$SCRATCH/stripped" NEW="$SCRATCH/new" B="$SCRATCH/block" C="$SCRATCH/final"
  tr -d '\r' < "$file" > "$S" || fail "cannot read $file"

  local opens closes so="" sc=""
  opens="$(count "$OPEN_RE" "$S")"; closes="$(count "$CLOSE_RE" "$S")"
  if [ "$opens" -eq 1 ] && [ "$closes" -eq 1 ]; then
    so="$(grep -n "$OPEN_RE" "$S" | head -n 1)"; so="${so%%:*}"
    sc="$(grep -n "$CLOSE_RE" "$S" | head -n 1)"; sc="${sc%%:*}"
  fi
  if [ "$opens" -ne "$closes" ] || [ "$opens" -gt 1 ] || { [ -n "$so" ] && [ "$sc" -lt "$so" ]; }; then
    fail "$file has $opens opening and $closes closing delivery-route markers (or a closing marker before the opening one); expected exactly one block or none. Fix it by hand, nothing was changed" 3
  fi

  if [ "$host" = other ]; then
    { printf '<!-- cc-tuner:delivery-route other -->\n'; tr -d '\r' < "$body"
      if [ -n "$(tail -c 1 "$body")" ]; then printf '\n'; fi
      printf '%s\n' "$CLOSE_LINE"; } > "$NEW" || fail "cannot build the route block"
  else
    canonical "$host" > "$NEW" || fail "cannot build the route block"
  fi
  [ -s "$NEW" ] || fail "the route block came out empty"

  local had_block=no
  if [ -n "$so" ]; then
    had_block=yes
    if [ "$(sed -n "${so},${sc}p" "$S")" = "$(cat "$NEW")" ]; then
      cp "$file" "$B" || fail "cannot read $file"
    else
      { head -n $((so - 1)) "$file"; cat "$NEW"; tail -n +$((sc + 1)) "$file"; } > "$B" || fail "cannot build the new $file"
    fi
  else
    { cat "$file"
      if [ -s "$file" ]; then
        if [ -n "$(tail -c 1 "$file")" ]; then printf '\n'; fi
        printf '\n'
      fi
      cat "$NEW"; } > "$B" || fail "cannot build the new $file"
  fi

  # The legacy header: two exact lines, replaced by the current wording; anything edited is left alone.
  local L next
  L="$(tr -d '\r' < "$B" | grep -n "$LEGACY_RE" | head -n 1)"; L="${L%%:*}"
  if [ -n "$L" ]; then
    next="$(tr -d '\r' < "$B" | sed -n "$((L + 1))p")"
  else
    next=""
  fi
  if [ -n "$L" ] && [ "$next" = "$LEGACY_NEXT" ]; then
    { head -n $((L - 1)) "$B"; header; tail -n +$((L + 2)) "$B"; } > "$C" || fail "cannot rewrite the header of $file"
  else
    cp "$B" "$C" || fail "cannot build the new $file"
  fi

  local status
  if cmp -s "$C" "$file"; then
    status=unchanged
  else
    FINAL="$(mktemp "$dir/.task-flow-local.XXXXXX")" || fail "mktemp failed in $dir"
    cp -p "$file" "$FINAL" || fail "cannot prepare a temp file in $dir"
    cat "$C" > "$FINAL" || fail "cannot write the temp file in $dir"
    [ -s "$FINAL" ] || fail "the new $file came out empty, nothing was changed"
    mv "$FINAL" "$file" || fail "cannot replace $file"
    FINAL=""
    if [ "$had_block" = yes ]; then status=replaced; else status=written; fi
  fi

  check_file "$host" "$file"
  case "$CHECK_LINE" in
    current|present-other) ;;
    *) fail "$file was written but does not check out ($CHECK_LINE)" ;;
  esac
  printf '%s\n' "$status"
}

case "${1:-}" in
  canonical) shift; cmd_canonical "$@" ;;
  write)     shift; cmd_write "$@" ;;
  check)     shift; cmd_check "$@" ;;
  *) usage ;;
esac
