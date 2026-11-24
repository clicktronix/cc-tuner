#!/usr/bin/env bash
# spec-lint.py design: the spec's "Domain model and design" section names a real artifact for each
# design step, or says why the step had none.
#
# /spec used to state these steps as conditions the agent weighed. Over six real runs the glossary and
# ADRs were never touched and domain-modeling never ran, because a skipped step cost nothing. The
# section makes each step answer, and this check makes a missing or invented answer fail.
#
# Every refusal asserts the exit status as well as the message: the first version printed the error
# for a missing field and still exited 0, and a message-only test passed it.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LINT="$FLOW_PLUGIN/scripts/spec-lint.py"
W="$(flow_workdir)"
R="$W/repo"

git init -q -b main "$R"
git -C "$R" config user.name test
git -C "$R" config user.email test@example.com
git -C "$R" config core.quotePath true
mkdir -p "$R/docs/adr" "$R/docs/PLANS" "$R/docs/research"
printf '# Glossary\n\n**Order**: a request to buy.\n' > "$R/GLOSSARY.md"
printf '# 0001 Postgres\n' > "$R/docs/adr/0001-postgres.md"
printf 'old notes\n' > "$R/docs/research/old.md"
git -C "$R" add -A && git -C "$R" commit -qm base
git -C "$R" switch -q -c feat/refunds
git -C "$R" branch -q prototype/refund-states
git -C "$R" branch -q not-a-prototype

# The branch's own design work: one glossary term, two ADRs, research notes (one with a non-ASCII name).
printf '\n**Refund**: money returned for a cancelled Order.\n' >> "$R/GLOSSARY.md"
printf '# 0002 Refunds are events\n' > "$R/docs/adr/0002-refund-events.md"
printf '# 0003 Refunds are per unit\n' > "$R/docs/adr/0003-refund-units.md"
printf '# Refund providers\n' > "$R/docs/research/refund-providers.md"
printf '# Провайдеры\n' > "$R/docs/research/провайдер.md"
printf '# Draft\n' > "$R/docs/research/[draft].md"
printf '# d\n' > "$R/docs/research/d.md"
ln -s /etc/hosts "$R/docs/research/linked.md"

# spec <name> <section body> -> repo-relative path of a spec with that section
spec() {
  printf '# Refunds\n\n**Goal:** refunds\n\n## Domain model and design\n%s\n## Acceptance criteria\n- [ ] x\n\n## Run config\nbranch: feat/refunds\ntarget: main\n' "$2" \
    > "$R/docs/PLANS/$1.md"
  printf 'docs/PLANS/%s.md' "$1"
}
lint() { out="$(cd "$R" && python3 "$LINT" design "$1" --base "${2:-main}" 2>&1)"; printf '%s\nrc=%s\n' "$out" "$?"; }
# refused <name> <message> <lint output>: the message is printed AND the exit status is 1
refused() { check "$1" "$2" "$3"; check "$1-exits-1" "rc=1" "$3"; }
with() { printf '%s' "$2" | sed "s|^$1: .*|$1: $3|"; }

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
check "several-adrs-pass" "rc=0" "$(lint "$(spec two "$(with ADR "$FULL" 'docs/adr/0002-refund-events.md, docs/adr/0003-refund-units.md')")")"
check "non-ascii-path-passes" "rc=0" "$(lint "$(spec cyr "$(with Research "$FULL" 'docs/research/провайдер.md')")")"
check "bracketed-path-is-literal" "rc=0" "$(lint "$(spec brk "$(with Research "$FULL" 'docs/research/[draft].md')")")"
printf 'x\n' > "$R/nonequilibrium.md"
check "keyword-prefix-of-a-name-is-a-name" "rc=0" "$(lint "$(spec noneq "$(with Research "$FULL" 'nonequilibrium.md')")")"
check "angle-brackets-in-a-design-pass" "rc=0" "$(lint "$(spec gen "$(with Modules "$NONE" 'RefundService<Refund> behind refund(order)')")")"

refused "missing-section-refused" "needs one \"## Domain model and design\" section" \
  "$(printf '# x\n\n## Run config\ntarget: main\n' > "$R/docs/PLANS/bare.md"; lint docs/PLANS/bare.md)"
refused "fenced-heading-is-not-a-section" "needs one \"## Domain model and design\" section" \
  "$(printf '# x\n\n```\n## Domain model and design\n```\n' > "$R/docs/PLANS/fenced.md"; lint docs/PLANS/fenced.md)"
check "fenced-example-beside-the-section-passes" "rc=0" \
  "$(f="$(spec fence "$NONE")"; printf '\n```md\n## Domain model and design\nADR: none\n```\n' >> "$R/$f"; lint "$f")"

refused "info-string-inside-a-fence-does-not-close-it" "needs one \"## Domain model and design\" section" \
  "$(printf '# x\n\n```md\n```python\n## Domain model and design\n```\n' > "$R/docs/PLANS/fence2.md"; lint docs/PLANS/fence2.md)"
refused "indented-heading-ends-the-section" 'needs one "Modules:" line (found 0)' \
  "$(lint "$(spec indent "$(printf '%s' "$NONE" | grep -v '^Modules:'; printf '\n  ## Later\nModules: unchanged — smuggled')")")"
check "hyphenated-name-is-a-path" "rc=0" \
  "$(printf 'n\n' > "$R/none-notes.md"; lint "$(spec hyph "$(with Research "$FULL" 'none-notes.md')")")"
refused "glossary-under-adr-is-no-adr" "an ADR lives under an adr/ directory" \
  "$(printf '# g\n' > "$R/docs/adr/GLOSSARY.md"; lint "$(spec gadr "$(with ADR "$FULL" 'docs/adr/GLOSSARY.md')")")"
refused "deleted-from-git-left-on-disk-refused" "is not changed on this branch: docs/research/old.md" \
  "$(git -C "$R" rm -q --cached docs/research/old.md; printf 'docs/research/old.md\n' >> "$R/.git/info/exclude"; lint "$(spec gone "$(with Research "$FULL" 'docs/research/old.md')")")"
git -C "$R" remote add team/upstream https://example.invalid/x.git
git -C "$R" update-ref refs/remotes/team/upstream/prototype/remote-states "$(git -C "$R" rev-parse HEAD)"
check "remote-with-a-slash-holds-a-prototype" "rc=0" "$(lint "$(spec rproto "$(with Prototype "$FULL" 'prototype/remote-states')")")"

refused "commented-section-is-hidden" "needs one \"## Domain model and design\" section" \
  "$(printf '# x\n\n<!--\n## Domain model and design\n%s\n-->\n' "$NONE" > "$R/docs/PLANS/comment.md"; lint docs/PLANS/comment.md)"
refused "fence-closed-by-a-nonbreaking-space-stays-open" "needs one \"## Domain model and design\" section" \
  "$(printf '# x\n\n```\n```\xc2\xa0\n## Domain model and design\n%s\n```\n' "$NONE" > "$R/docs/PLANS/nbsp.md"; lint docs/PLANS/nbsp.md)"
refused "setext-heading-inside-the-section-refused" "holds only its field lines" \
  "$(lint "$(spec setext "$(printf '%s' "$NONE" | grep -v '^Modules:'; printf '\nAcceptance criteria\n---\nModules: unchanged — smuggled')")")"
refused "em-dash-without-space-is-a-skip" 'give the reason after "—"' \
  "$(lint "$(spec emd "$(with Modules "$NONE" 'unchanged —TBD')")")"
check "em-dash-without-space-with-a-reason-passes" "rc=0" \
  "$(lint "$(spec emd2 "$(with Modules "$NONE" 'unchanged —no interface moves')")")"

for field in Research Glossary ADR Prototype Seams Modules; do
  body="$(printf '%s' "$NONE" | grep -v "^$field:")"
  refused "missing-$field-refused" "needs one \"$field:\" line" "$(lint "$(spec "no-$field" "$body")")"
done
refused "duplicate-field-refused" 'needs one "ADR:" line (found 2)' "$(lint "$(spec dup "$NONE
ADR: none — twice")")"

refused "bare-keyword-refused" 'give the reason after "—"' "$(lint "$(spec bare "$(with ADR "$NONE" 'none')")")"
refused "empty-reason-refused" 'give the reason after "—"' "$(lint "$(spec empty "$(with ADR "$NONE" 'none — ')")")"
refused "placeholder-reason-refused" 'give the reason after "—"' "$(lint "$(spec tbdr "$(with ADR "$NONE" 'none — TBD')")")"
refused "placeholder-refused" "placeholder" "$(lint "$(spec tbd "$(with Seams "$NONE" 'TBD')")")"
refused "template-text-refused" "placeholder" "$(lint "$(spec tpl "$(with Seams "$NONE" '<the seams>')")")"
refused "keyword-of-another-field-refused" 'Glossary: <artifact> | unchanged — <reason>' \
  "$(lint "$(spec wrongkw "$(with Glossary "$NONE" 'none — nothing')")")"

# A path names this branch's work: a regular file that exists and differs from the base.
refused "unchanged-file-refused" "is not changed on this branch: docs/research/old.md" \
  "$(lint "$(spec stale "$(with Research "$FULL" 'docs/research/old.md')")")"
refused "missing-file-refused" "the file does not exist: docs/adr/0009-ghost.md" \
  "$(lint "$(spec ghost "$(with ADR "$FULL" 'docs/adr/0009-ghost.md')")")"
refused "glob-is-not-expanded" "the file does not exist: docs/research/r*.md" \
  "$(lint "$(spec glob "$(with Research "$FULL" 'docs/research/r*.md')")")"
refused "symlink-refused" "not a link or a directory: docs/research/linked.md" \
  "$(lint "$(spec link "$(with Research "$FULL" 'docs/research/linked.md')")")"
refused "empty-entry-refused" "an entry of the list is empty" \
  "$(lint "$(spec comma "$(with ADR "$FULL" 'docs/adr/0002-refund-events.md,')")")"
refused "glossary-must-be-a-glossary" "Glossary names GLOSSARY.md" \
  "$(lint "$(spec notgloss "$(with Glossary "$FULL" 'docs/adr/0002-refund-events.md')")")"
refused "adr-must-be-an-adr" "an ADR lives under an adr/ directory" \
  "$(lint "$(spec glossadr "$(with ADR "$FULL" 'GLOSSARY.md')")")"
refused "absolute-path-refused" "repo-relative" "$(lint "$(spec abs "$(with ADR "$FULL" "$R/docs/adr/0002-refund-events.md")")")"
refused "dotdot-path-refused" "repo-relative" "$(lint "$(spec dotdot "$(with ADR "$FULL" 'docs/../docs/adr/0002-refund-events.md')")")"
refused "missing-prototype-branch-refused" "there is no branch named prototype/ghost" \
  "$(lint "$(spec noproto "$(with Prototype "$FULL" 'prototype/ghost')")")"
refused "revision-expression-is-not-a-branch" "name the prototype's branch" \
  "$(lint "$(spec rev "$(with Prototype "$FULL" 'prototype/refund-states~0')")")"
refused "branch-outside-prototype-refused" "name the prototype's branch" \
  "$(lint "$(spec mainproto "$(with Prototype "$FULL" 'not-a-prototype')")")"

# The base is the ref the branch was cut from, not whatever a local branch of that name holds now.
# origin/main moves on with an upstream file; the task branch is cut from it, local main is stale.
git -C "$R" worktree add -q "$W/up" main
printf 'upstream\n' > "$W/up/docs/research/upstream.md"
git -C "$W/up" add docs/research/upstream.md && git -C "$W/up" commit -qm upstream
git -C "$R" update-ref refs/remotes/origin/main "$(git -C "$W/up" rev-parse HEAD)"
git -C "$W/up" reset -q --hard HEAD~1 && git -C "$R" worktree remove "$W/up"
git -C "$R" stash -q -u && git -C "$R" rebase -q origin/main && git -C "$R" stash pop -q
refused "work-of-the-target-is-not-the-branch-s" "is not changed on this branch: docs/research/upstream.md" \
  "$(lint "$(spec up "$(with Research "$FULL" 'docs/research/upstream.md')")" origin/main)"

# Committed artifacts count as well as uncommitted ones: /spec may commit before a later lint.
( cd "$R" && git add -A && git commit -qm "design artifacts" )
check "committed-artifacts-pass" "rc=0" "$(lint "$(spec committed "$FULL")" origin/main)"

refused "unknown-base-refused" "cannot find a merge base" "$(lint "$(spec nb "$NONE")" no-such-ref)"
refused "missing-spec-refused" "no such spec" "$(lint docs/PLANS/absent.md)"
refused "usage-names-design" "spec-lint.py design <spec> --base <ref>" \
  "$(out="$(python3 "$LINT" 2>&1)"; printf '%s\nrc=%s\n' "$out" "$?")"

exit "$fails"
