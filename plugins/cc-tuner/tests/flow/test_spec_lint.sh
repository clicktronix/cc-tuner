#!/usr/bin/env bash
# spec-lint.sh design: the spec's "Domain model and design" section names a real artifact for each
# design step, or says why the step had none.
#
# /spec used to state these steps as conditions the agent weighed. Over six real runs the glossary and
# ADRs were never touched and domain-modeling never ran, because a skipped step cost nothing. The
# section makes each step answer, and this check makes a missing or invented answer fail.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LINT="$FLOW_PLUGIN/scripts/spec-lint.sh"
W="$(flow_workdir)"
R="$W/repo"

git init -q -b main "$R"
git -C "$R" config user.name test
git -C "$R" config user.email test@example.com
mkdir -p "$R/docs/adr" "$R/docs/PLANS" "$R/docs/research"
printf '# Glossary\n\n**Order**: a request to buy.\n' > "$R/GLOSSARY.md"
printf '# 0001 Postgres\n' > "$R/docs/adr/0001-postgres.md"
printf 'old notes\n' > "$R/docs/research/old.md"
git -C "$R" add -A && git -C "$R" commit -qm base
git -C "$R" switch -q -c feat/refunds
git -C "$R" branch -q prototype/refund-states

# The branch's own design work: one glossary term, one ADR, one research note.
printf '\n**Refund**: money returned for a cancelled Order.\n' >> "$R/GLOSSARY.md"
printf '# 0002 Refunds are events\n' > "$R/docs/adr/0002-refund-events.md"
printf '# Refund providers\n' > "$R/docs/research/refund-providers.md"

# spec <name> <section body> -> repo-relative path of a spec with that section and target main
spec() {
  printf '# Refunds\n\n**Goal:** refunds\n\n## Domain model and design\n%s\n## Acceptance criteria\n- [ ] x\n\n## Run config\nbranch: feat/refunds\ntarget: main\n' "$2" \
    > "$R/docs/PLANS/$1.md"
  printf 'docs/PLANS/%s.md' "$1"
}
lint() { out="$(cd "$R" && bash "$LINT" design "$@" 2>&1)"; printf '%s\nrc=%s\n' "$out" "$?"; }

FULL='Research: docs/research/refund-providers.md
Glossary: GLOSSARY.md
ADR: docs/adr/0002-refund-events.md
Prototype: prototype/refund-states
Seams: the RefundService interface is the one seam the acceptance tests drive
Modules: RefundService, a deep module behind refund(order) at the payments seam
'
NONE='Research: not needed — every fact is in the repository
Glossary: unchanged — no term is added or redefined
ADR: none — the change is easy to reverse
Prototype: not needed — every question was settled in the interview
Seams: the existing OrderService tests
Modules: unchanged — no interface moves
'

check "artifacts-of-this-branch-pass" "rc=0" "$(lint "$(spec full "$FULL")")"
check "explicit-reasons-pass" "rc=0" "$(lint "$(spec none "$NONE")")"
check "several-adrs-pass" "rc=0" \
  "$(lint "$(spec two "$(printf '%s' "$FULL" | sed 's|^ADR: .*|ADR: docs/adr/0002-refund-events.md, GLOSSARY.md|')")")"

check "missing-section-refused" 'needs one "## Domain model and design" section' \
  "$(printf '# x\n\n## Run config\ntarget: main\n' > "$R/docs/PLANS/bare.md"; lint docs/PLANS/bare.md)"

for field in Research Glossary ADR Prototype Seams Modules; do
  body="$(printf '%s' "$NONE" | grep -v "^$field:")"
  check "missing-$field-refused" "needs one \"$field:\" line" "$(lint "$(spec "no-$field" "$body")")"
done

check "bare-keyword-refused" 'give the reason after "—"' \
  "$(lint "$(spec bare "$(printf '%s' "$NONE" | sed 's|^ADR: .*|ADR: none|')")")"
check "empty-reason-refused" 'give the reason after "—"' \
  "$(lint "$(spec empty "$(printf '%s' "$NONE" | sed 's|^ADR: .*|ADR: none — |')")")"
check "placeholder-refused" "placeholder" \
  "$(lint "$(spec tbd "$(printf '%s' "$NONE" | sed 's|^Seams: .*|Seams: TBD|')")")"
check "template-text-refused" "placeholder" \
  "$(lint "$(spec tpl "$(printf '%s' "$NONE" | sed 's|^Seams: .*|Seams: <the seams>|')")")"
check "keyword-of-another-field-refused" 'Glossary: <path> | unchanged — <reason>' \
  "$(lint "$(spec wrongkw "$(printf '%s' "$NONE" | sed 's|^Glossary: .*|Glossary: none — nothing|')")")"
check "duplicate-field-refused" 'needs one "ADR:" line' \
  "$(lint "$(spec dup "$NONE
ADR: none — twice")")"

# A path names this branch's work: it exists and differs from where the branch left the target.
check "unchanged-file-refused" "is not changed on this branch: docs/research/old.md" \
  "$(lint "$(spec stale "$(printf '%s' "$FULL" | sed 's|^Research: .*|Research: docs/research/old.md|')")")"
check "missing-file-refused" "the file does not exist: docs/adr/0009-ghost.md" \
  "$(lint "$(spec ghost "$(printf '%s' "$FULL" | sed 's|^ADR: .*|ADR: docs/adr/0009-ghost.md|')")")"
check "glossary-must-be-a-glossary" "Glossary names GLOSSARY.md" \
  "$(lint "$(spec notgloss "$(printf '%s' "$FULL" | sed 's|^Glossary: .*|Glossary: docs/adr/0002-refund-events.md|')")")"
check "absolute-path-refused" "repo-relative" \
  "$(lint "$(spec abs "$(printf '%s' "$FULL" | sed "s|^ADR: .*|ADR: $R/docs/adr/0002-refund-events.md|")")")"
check "dotdot-path-refused" "repo-relative" \
  "$(lint "$(spec dotdot "$(printf '%s' "$FULL" | sed 's|^ADR: .*|ADR: docs/../docs/adr/0002-refund-events.md|')")")"
check "missing-prototype-branch-refused" "there is no branch named prototype/ghost" \
  "$(lint "$(spec noproto "$(printf '%s' "$FULL" | sed 's|^Prototype: .*|Prototype: prototype/ghost|')")")"

# Committed artifacts count as well as uncommitted ones: /spec may commit before a later lint.
( cd "$R" && git add -A && git commit -qm "design artifacts" )
check "committed-artifacts-pass" "rc=0" "$(lint "$(spec committed "$FULL")")"

NOWHERE="$(spec nowhere "$NONE")"
sed 's|^target: main|target: no-such-branch|' "$R/$NOWHERE" > "$W/nowhere" && mv "$W/nowhere" "$R/$NOWHERE"
check "unknown-target-refused" "cannot find the target" "$(lint "$NOWHERE")"
check "missing-spec-refused" "no such spec" "$(lint docs/PLANS/absent.md)"
check "usage-names-design" "spec-lint.sh design <spec>" "$(bash "$LINT" 2>&1)"

exit "$fails"
