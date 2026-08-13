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

# flow_workdir -> prints a fresh directory, removed when the suite exits.
#
# mktemp, not a counter. A counter incremented here is lost: callers say `d="$(flow_workdir)"`, the
# function runs in that subshell, and the new value dies with it -- so every call returned the same
# path, and the second flow_repo tried to git init over the first. Same subshell trap that ate the
# EXIT handler, wearing different clothes. Nothing in this file may depend on state surviving a call.
flow_workdir() {
  mktemp -d "$FLOW_ROOT/w.XXXXXX" || { printf 'FATAL: mktemp under %s failed\n' "$FLOW_ROOT"; exit 1; }
}

# flow_repo -> initialises a git repo with one commit and prints its path.
# A repo with no commits has no HEAD, and plan-path.sh asks git for the current branch.
flow_repo() {
  local d; d="$(flow_workdir)/repo"
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
