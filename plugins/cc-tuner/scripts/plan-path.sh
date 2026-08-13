#!/usr/bin/env bash
# The one place a branch turns into a plan path.
#
# `/cc-tuner:plan` writes the plan, `/cc-tuner:run` reads it, and the SessionStart hook restores from
# it. Three callers deriving the same slug independently is a second parser for one question, and they
# would part company on the first branch name carrying a slash or a capital.
#
#   plan-path.sh create    prints the canonical path for a plan that does not exist yet
#   plan-path.sh resolve   prints the one existing plan for this branch; fails on none and on several
#
# Fail-closed on both ends. `resolve` refusing zero matches and refusing two is the whole point: no
# match may mean no plan or a renamed branch, two matches mean two plans with equal claim, and a
# resolver that picks one is a resolver that is quietly wrong some of the time.
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

MODE="${1:-}"

# NOT docs/plans. `/cc-tuner:spec` writes specs to <root>/PLANS/, and on macOS's case-insensitive
# APFS `docs/PLANS` and `docs/plans` are the same directory -- so specs and plans would share one
# folder and, with matching dates and slugs, could collide as files. git stores literal paths, so the
# two spellings also disagree about what exists. A distinct directory removes the whole class.
# The root follows the spec's own convention: wiki/ when the repo uses it, docs/ otherwise.
DIR="docs/task-plans"

die() { printf 'plan-path: %s\n' "$1" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not a git repository"
cd "$ROOT" || die "cannot enter $ROOT"
[ -d wiki ] && DIR="wiki/task-plans"

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || die "cannot read the current branch"
[ "$BRANCH" != "HEAD" ] || die "detached HEAD has no branch to key a plan to"

# lowercase, anything outside [a-z0-9] becomes a separator, runs collapse, ends trimmed.
SLUG="$(printf '%s' "$BRANCH" \
  | tr 'A-Z' 'a-z' \
  | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
[ -n "$SLUG" ] || die "branch '$BRANCH' has no usable slug"

# The date prefix is matched by shape, not by wildcard. `<dir>/*-main.md` would also match
# `2026-08-13-rewrite-main.md`; anchoring `????-??-??-` to the front cannot.
PATTERN="$DIR/????-??-??-$SLUG.md"

case "$MODE" in
  create)
    # A second plan for one branch is the ambiguity `resolve` refuses. Failing here, where the fix is
    # obvious, beats writing the file and failing later in a hook with no context.
    existing="$(git ls-files -- "$PATTERN" 2>/dev/null)"
    # Untracked files count too. `git ls-files` sees only what is committed, so an earlier revision
    # happily returned a path that already had a file on it, and the caller's Write overwrote a plan
    # that was merely not committed yet.
    for f in $PATTERN; do
      [ -e "$f" ] || continue
      case "$existing" in *"$f"*) ;; *) existing="${existing:+$existing
}$f (untracked)" ;; esac
    done
    if [ -n "$existing" ]; then
      printf 'plan-path: a plan for %s already exists:\n' "$BRANCH" >&2
      printf '%s\n' "$existing" | sed 's/^/  /' >&2
      printf 'edit it, or remove it first.\n' >&2
      exit 1
    fi
    CANDIDATE="$DIR/$(date -u +%Y-%m-%d)-$SLUG.md"
    [ ! -e "$CANDIDATE" ] || {
      printf 'plan-path: %s already exists on disk\n' "$CANDIDATE" >&2
      exit 1
    }
    printf '%s\n' "$CANDIDATE"
    ;;
  resolve)
    # Tracked files only. An uncommitted plan does not survive the session it was written in, which
    # is the one thing the plan file exists to do.
    found="$(git ls-files -- "$PATTERN" 2>/dev/null)"
    n="$(printf '%s' "$found" | grep -c . )"
    case "$n" in
      1) printf '%s\n' "$found" ;;
      0) die "no committed plan for branch '$BRANCH' (looked for $PATTERN)" ;;
      *)
        printf 'plan-path: %s plans claim branch %s:\n' "$n" "$BRANCH" >&2
        printf '%s\n' "$found" | sed 's/^/  /' >&2
        exit 1
        ;;
    esac
    ;;
  *)
    die "usage: plan-path.sh create|resolve"
    ;;
esac
