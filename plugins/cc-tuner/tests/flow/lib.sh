#!/usr/bin/env bash
# Harness for flow tests: real git repositories on disk, real hook payloads on stdin, assertions on
# what a script actually decided.
#
# The tier exists because 0.10.0 shipped with 82 green assertions that were `grep` over Markdown while
# `spec -> plan -> run` could not start. A phrase-matching test cannot observe a decision; this can.
#
# Named `flow/`, not `scenarios/`, because `$ROOT/tests/scenarios/*/*.json` already means something
# else in this repo -- recorded evidence about model behaviour. Two directories called "scenarios"
# meaning different things is how a reader ends up trusting the wrong one.
#
# Files here named `test_*.sh` are picked up automatically by tests/run.sh; this library is not.
# bash 3.2: no associative arrays, no mapfile.
set -u

FLOW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_FIXTURES="$FLOW_LIB_DIR/fixtures"
FLOW_PLUGIN="$(cd "$FLOW_LIB_DIR/../.." && pwd)"
fails=0

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=1; }

# check <name> <expected-substring> <actual>
check() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1 (want /$2/ in: $3)" ;;
  esac
}

# absent <name> <unwanted-substring> <actual>
absent() {
  case "$3" in
    *"$2"*) fail "$1 (unwanted /$2/ present)" ;;
    *) pass "$1" ;;
  esac
}

# equals <name> <expected> <actual>
equals() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi
}

# One root temp dir per suite, with the trap registered here at load time.
#
# Registering it inside flow_workdir instead does not work, and the self-test caught it on the first
# run: callers say `d="$(flow_workdir)"`, which is a subshell, so the subshell exits the instant the
# function returns, fires its own EXIT trap, and deletes the directory before the caller can use it.
FLOW_ROOT="$(mktemp -d)" || { printf 'FATAL: mktemp failed\n'; exit 1; }
trap 'rm -rf "$FLOW_ROOT"' EXIT
FLOW_SEQ=0

# flow_workdir -> prints a fresh directory, removed when the suite exits.
flow_workdir() {
  FLOW_SEQ=$((FLOW_SEQ + 1))
  local d="$FLOW_ROOT/w$FLOW_SEQ"
  mkdir -p "$d" || { printf 'FATAL: mkdir %s failed\n' "$d"; exit 1; }
  printf '%s' "$d"
}

# flow_repo [dir] -> initialises a git repo with one commit and prints its path.
# A repo with no commits has no HEAD, and half the things under test ask git about a range.
flow_repo() {
  local d="${1:-$(flow_workdir)/repo}"
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q -b main
    git config user.email flow@example.invalid
    git config user.name 'Flow Harness'
    printf 'seed\n' > .flow-seed
    git add .flow-seed
    git commit -q -m 'seed'
  ) || { printf 'FATAL: could not create repo at %s\n' "$d"; exit 1; }
  printf '%s' "$d"
}

# flow_payload <fixture-name> [jq-filter] -> prints a hook payload, optionally transformed.
# The fixtures are payloads captured from a live session, not invented ones: a test built on a guessed
# payload shape proves the guess, not the product.
flow_payload() {
  local f="$FLOW_FIXTURES/$1.json"
  [ -f "$f" ] || { printf 'FATAL: no fixture %s\n' "$1" >&2; exit 1; }
  if [ "$#" -ge 2 ]; then jq -c "$2" "$f"; else jq -c . "$f"; fi
}

# flow_hook <script> <payload> -> runs a hook script with the payload on stdin.
# Prints its stdout, then a final line `rc=<exit code>`, so a caller can assert on both without
# losing one to the other.
flow_hook() {
  local script="$1" payload="$2" out rc
  out="$(printf '%s' "$payload" | bash "$script" 2>&1)"
  rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
