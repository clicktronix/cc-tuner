#!/usr/bin/env bash
# plan-path.sh: the single branch -> plan path resolver.
#
# Every assertion here runs against a real repository with real commits, because the questions are
# "what does git ls-files return" and "what happens on a detached HEAD" -- neither is answerable by
# reading the script.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PLAN_PATH="$FLOW_PLUGIN/scripts/plan-path.sh"

# run <repo> <mode> -> stdout+stderr, then a final line rc=<code>
run() { ( cd "$1" && bash "$PLAN_PATH" "$2" 2>&1; printf 'rc=%s\n' "$?" ); }

commit_plan() { # commit_plan <repo> <path>
  ( cd "$1" && mkdir -p "$(dirname "$2")" && printf '# plan\n' > "$2" \
    && git add "$2" && git commit -q -m "add $2" )
}

# --- create: canonical path, and the slug rules --------------------------------------------------
R="$(flow_repo)"
TODAY="$(date -u +%Y-%m-%d)"
OUT="$(run "$R" create)"
check "create-prints-canonical" "docs/task-plans/$TODAY-main.md" "$OUT"
check "create-rc0"              "rc=0"                      "$OUT"

# A slash is the common case -- every task branch has one -- and an unslugged path would sit in a
# directory nobody created.
( cd "$R" && git checkout -q -b Feature/Retry_Budget )
OUT="$(run "$R" create)"
check  "slug-lowercases-and-separates" "docs/task-plans/$TODAY-feature-retry-budget.md" "$OUT"
absent "slug-has-no-slash"             "Feature/"                                  "$OUT"

# Runs collapse and ends are trimmed, or the filename carries doubled and trailing separators.
( cd "$R" && git checkout -q -b 'wip/_odd__name_' )
OUT="$(run "$R" create)"
check "slug-collapses-and-trims" "docs/task-plans/$TODAY-wip-odd-name.md" "$OUT"

# --- create refuses to make the ambiguity resolve would have to reject ----------------------------
R2="$(flow_repo)"
( cd "$R2" && git checkout -q -b retry )
commit_plan "$R2" "docs/task-plans/2026-01-01-retry.md"
OUT="$(run "$R2" create)"
check "create-refuses-second-plan" "already exists" "$OUT"
check "create-names-the-existing"  "2026-01-01-retry.md" "$OUT"
check "create-refusal-rc1"         "rc=1"            "$OUT"

# An untracked file on the canonical path counts. git ls-files sees only what is committed, so an
# earlier revision returned a path that already had a file on it and the caller's Write overwrote a
# plan that was merely not committed yet.
R2b="$(flow_repo)"
( cd "$R2b" && git checkout -q -b untracked && mkdir -p docs/task-plans \
  && printf '# draft\n' > "docs/task-plans/$TODAY-untracked.md" )
OUT="$(run "$R2b" create)"
check "create-refuses-untracked-collision" "already exists" "$OUT"
check "create-untracked-rc1"               "rc=1"           "$OUT"

# --- resolve ------------------------------------------------------------------------------------
OUT="$(run "$R2" resolve)"
check "resolve-finds-the-one" "docs/task-plans/2026-01-01-retry.md" "$OUT"
check "resolve-rc0"           "rc=0"                           "$OUT"

# Zero is not guessable: it may be no plan, or a branch that was renamed away from its plan.
R3="$(flow_repo)"
( cd "$R3" && git checkout -q -b lonely )
OUT="$(run "$R3" resolve)"
check "resolve-zero-fails"     "no committed plan" "$OUT"
check "resolve-zero-rc1"       "rc=1"              "$OUT"

# Two is not guessable either, and picking one is the silent-wrong-answer this script exists to avoid.
commit_plan "$R3" "docs/task-plans/2026-01-01-lonely.md"
commit_plan "$R3" "docs/task-plans/2026-02-02-lonely.md"
OUT="$(run "$R3" resolve)"
check "resolve-two-fails"      "2 plans claim branch" "$OUT"
check "resolve-two-lists-both" "2026-02-02-lonely.md" "$OUT"
check "resolve-two-rc1"        "rc=1"                 "$OUT"

# --- the date prefix is matched by shape, not by wildcard ----------------------------------------
# `docs/task-plans/*-main.md` would also match `2026-08-13-rewrite-main.md`, so a plan for another branch
# whose slug happens to end in this one's would be picked up as this branch's plan.
R4="$(flow_repo)"
( cd "$R4" && git checkout -q -b api )
commit_plan "$R4" "docs/task-plans/2026-01-01-rewrite-api.md"
OUT="$(run "$R4" resolve)"
check "suffix-collision-not-matched" "no committed plan" "$OUT"

# --- an uncommitted plan is not a plan -----------------------------------------------------------
# It does not survive the session it was written in, which is the one job the file has.
R5="$(flow_repo)"
( cd "$R5" && git checkout -q -b draft && mkdir -p docs/task-plans && printf '# plan\n' > docs/task-plans/2026-01-01-draft.md )
OUT="$(run "$R5" resolve)"
check "untracked-plan-ignored" "no committed plan" "$OUT"

# --- refusals that are not about plans at all ----------------------------------------------------
R6="$(flow_repo)"
( cd "$R6" && git checkout -q --detach )
OUT="$(run "$R6" resolve)"
check "detached-head-fails" "detached HEAD" "$OUT"
check "detached-head-rc1"   "rc=1"          "$OUT"

W="$(flow_workdir)"
OUT="$(run "$W" resolve)"
check "outside-a-repo-fails" "not a git repository" "$OUT"

OUT="$(run "$R" bogus)"
check "unknown-mode-fails" "usage:" "$OUT"

exit $fails
