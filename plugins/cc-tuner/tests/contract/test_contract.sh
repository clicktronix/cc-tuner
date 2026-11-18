#!/usr/bin/env bash
# Static wiring checks for shipped instructions, templates and release configuration.
# Only what a machine reads or runs is pinned here: helper commands, record and status-line formats,
# frontmatter, file layout, and text that must not come back. Wording is not: a sentence may be
# rewritten or moved without touching this file, and behaviour is judged by review and the model eval.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SPEC="$ROOT/plugins/cc-tuner/skills/spec/SKILL.md"
SPEC_TEMPLATE="$ROOT/plugins/cc-tuner/skills/spec/spec-template.md"
RUN="$ROOT/plugins/cc-tuner/skills/run/SKILL.md"
DEEP_REVIEW="$ROOT/plugins/cc-tuner/skills/deep-review/SKILL.md"
PLACEMENT="$ROOT/plugins/cc-tuner/skills/run/references/placement.md"
SETUP="$ROOT/plugins/cc-tuner/skills/setup/SKILL.md"
TASK_FLOW="$ROOT/plugins/cc-tuner/skills/task-flow/SKILL.md"
CLAUDE_MD_WRITER="$ROOT/plugins/cc-tuner/skills/claude-md-writer/SKILL.md"
CLAUDE_MD_AUDIT="$ROOT/plugins/cc-tuner/skills/claude-md-writer/audit.md"
RULE_TEMPLATE="$ROOT/plugins/cc-tuner/assets/task-flow/rule.template.md"
ROUTE_GITLAB="$ROOT/plugins/cc-tuner/skills/run/references/route-gitlab.md"
ROUTE_LOCAL="$ROOT/plugins/cc-tuner/skills/run/references/route-local.md"
HOSTS="$ROOT/plugins/cc-tuner/skills/run/references/hosts.md"
DELIVERY="$ROOT/plugins/cc-tuner/skills/run/references/delivery.md"
GROOM="$ROOT/plugins/cc-tuner/skills/spec/references/groom.md"
DELIVERY_REF="$ROOT/plugins/cc-tuner/skills/setup/references/delivery-route.md"
COMPANIONS_REF="$ROOT/plugins/cc-tuner/skills/setup/references/companions.md"
SETUP_MANUAL="$ROOT/plugins/cc-tuner/tests/setup/setup-manual-checks.md"
TASK_FLOW_REF="$ROOT/plugins/cc-tuner/skills/setup/references/task-flow-rule.md"
UNIT="$ROOT/plugins/cc-tuner/agents/slice-unit.md"
VERIFY="$ROOT/plugins/cc-tuner/skills/verify-feature/SKILL.md"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release-please.yml"
BRANCH_PLAN="$ROOT/docs/superpowers/plans/2026-08-13-native-first-lifecycle.md"
fails=0

need() {
  name="$1"; pattern="$2"; file="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "PASS $name"
  else
    echo "FAIL $name (missing '$pattern' in ${file#$ROOT/})"
    fails=1
  fi
}

need "spec-prereq" 'prereq-check.sh' "$SPEC"
need "spec-prereq-does-not-block-spec" '/spec continues' "$SPEC"
need "setup-has-a-remove-for-statusline" '/cc-tuner:setup remove statusline' "$SETUP"
need "setup-reports-the-testing-runbook" 'Testing runbook' "$SETUP"
# Units ran about 70% of all heavy checks while the text allowed "anything heavy" from them. The split
# of who runs what lives in placement; the unit definition carries its own share because it never
# reads placement. full_test_cadence is a Run config field: spec writes it, plan-lint checks it, /run reads it.
# A copied .env reached a unit's output. The mod refuses the dumps it can see (hooks/register.test.ts);
# the unit's own line covers the reads it cannot.
need "spec-template-cadence-field"        'full_test_cadence: per-candidate|per-batch' "$SPEC_TEMPLATE"
need "run-reads-the-cadence"              '`full_test_cadence`' "$RUN"
# Containers, dev servers and browser sessions outlived /run. The report line makes what is left over
# a stated fact instead of a silence.
need "run-reports-its-resources"          'resources: closed | retained <what, and why> | none' "$RUN"
# merge.sh reads these tags (tests/flow/test_merge.sh); the producer has to keep writing them, and the
# publisher has to post what the producer wrote rather than a record of its own.
need "verify-record-tags-the-instrument"  '[browser|api|test|cli] <what was run>' "$VERIFY"
need "verify-record-keeps-not-proved"     'NOT PROVED: <what is missing' "$VERIFY"
# Opus ran in about half of all units on "genuinely hard from the start", which any slice can claim.
# The ladder names closed cases instead; an open criterion must not come back.
# Both admitted reasons leave a line a reader can check.
need "placement-opus-reason-line"         'Opus-reason: <the failed check and its output | the plan' "$PLACEMENT"
need "plan-template-marks-opus-slices"    'Model: opus — <why' "$ROOT/plugins/cc-tuner/skills/spec/plan-template.md"
if grep -qF 'genuinely hard' "$PLACEMENT"; then
  echo "FAIL placement-opus-has-an-open-criterion"; fails=1
else
  echo "PASS placement-opus-needs-evidence"
fi
# A second provider's research is optional and decided before discovery, so it overlaps the reading;
# asking in the section 3 batch would leave it nothing to overlap with. Its answer is evidence.
need "spec-routes-optional-opinions"      'references/optional-opinions.md' "$SPEC"
OPINIONS="$ROOT/plugins/cc-tuner/skills/spec/references/optional-opinions.md"
need "spec-loads-template" 'spec-template.md' "$SPEC"
need "spec-eyes-schema" 'checked by: <human step>; machine replacement: <exact check|none>; waiver: <user/date|none>' "$SPEC_TEMPLATE"
need "spec-dor" '## Definition of Ready' "$SPEC_TEMPLATE"
need "spec-first-failing-check" 'First failing check: <exact command>; expected failure:' "$SPEC_TEMPLATE"
need "spec-targeted-checks" 'Targeted checks: <exact commands>' "$SPEC_TEMPLATE"
need "spec-full-regression" 'Full regression: <exact command>' "$SPEC_TEMPLATE"
need "spec-dod" '## Definition of Done' "$SPEC_TEMPLATE"
need "spec-github-tracker" 'tracker: gh' "$SPEC_TEMPLATE"
if grep -Eq 'passed deep review|exact SHA/tree|<tree SHA>' "$SPEC_TEMPLATE"; then
  echo "FAIL spec-template-requires-obsolete-review-policy"
  fails=1
else
  echo "PASS spec-template-uses-current-review-policy"
fi

# The branch must exist before grilling, because grilling invokes domain-modeling and that writes
# GLOSSARY.md and ADRs -- committed artifacts, which must not land on the integration branch. Ordering
# is the whole rule, so the test is an ordering test, not a phrase test.
branch_line="$(grep -n '^## [0-9]*\. Create the task branch' "$SPEC" | head -1 | cut -d: -f1)"
grill_line="$(grep -n '^## [0-9]*\. Grill the problem' "$SPEC" | head -1 | cut -d: -f1)"
if [ -n "$branch_line" ] && [ -n "$grill_line" ] && [ "$branch_line" -lt "$grill_line" ]; then
  echo "PASS spec-branch-before-grilling"
else
  echo "FAIL spec-branch-before-grilling (branch=$branch_line grill=$grill_line)"
  fails=1
fi
# These are static producer/consumer seams: scripts own executable decisions; the checks below only
# keep the skills and their output templates wired to those scripts. They do not prove model behaviour.
need "run-resolves-the-plan"        'plan-path.sh" resolve' "$RUN"
need "run-validates-the-plan"       'plan-lint.sh" check' "$RUN"
# The frontier is a program, not arithmetic the model does from the graph. Doing it by hand is how a
# blocked slice gets started under --auto, and it is also what made the Markdown-only fallback a
# promise with no implementation: /run defined its whole loop through TaskList.
need "run-asks-for-safe-batches"    'plan-lint.sh" ready-batches' "$RUN"
# Finding 3: both commands commit, and neither used to say anything about attribution trailers, so
# each fell through to the harness default in every repository cc-tuner is enabled in. The
# preference belongs to the repository, so the skills point at where it is written down.
need "template-has-a-trailer-line"     '**Attribution trailers:**' "$RULE_TEMPLATE"
# The template loads in every session. Its trailer paragraph described a failure and gave no action;
# CI-mode detail is local-ci.md's. Both are pinned out, and the size is held near what it now is.
if grep -qF 'none:<reason>' "$RULE_TEMPLATE"; then
  echo "FAIL template-restates-ci-modes"; fails=1
else
  echo "PASS template-leaves-ci-modes-to-local-ci"
fi
# Work done outside /spec and /run left cards where they were (stokli, marqa); the always-on rule is
# what such work reads.
if tr -s ' \n' ' ' < "$RULE_TEMPLATE" | grep -qF "which move the card themselves, move it by \`cc-tuner:task-flow\`'s Card lifecycle"; then
  echo "PASS rule-template-moves-cards-outside-commands"
else
  echo "FAIL rule-template-moves-cards-outside-commands"
  fails=1
fi
template_words="$(wc -w < "$RULE_TEMPLATE" | tr -d ' ')"
[ "$template_words" -le 650 ] && echo "PASS template-stays-small ($template_words words)" \
  || { echo "FAIL template-stays-small ($template_words words; keep it <= 650)"; fails=1; }
# One general instruction was replayed as `renew --by` six times on one thread.
need "run-verdict-marker"           'cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <judged-sha>' "$DELIVERY"
need "run-merges-through-the-script" 'scripts/merge.sh' "$DELIVERY"
need "run-codex-required-review"    '--required' "$DELIVERY"
# Sentence matching used to grade task recovery, review routing, deferral and publication order.
# Rephrasing those instructions broke the tests without changing those decisions; retaining the
# expected sentence in a contradictory paragraph would pass. Do not repair that by pinning the new
# wording. Semantic review covers instruction changes; model-eval provenance is tracked separately
# in EVALUATED_SHA. tests/flow exercises the helpers, not the model's choice to invoke them.
# The classes belong to /spec, which assigns the proof; /run only executes what is already committed.
# Pinned there, not here — an earlier revision pinned them in /run, which is advice arriving after the
# decision it is about.
need "spec-assigns-mutation-classes"     'fail-closed guards'  "$SPEC"
need "spec-writes-the-plan"         'plan-path.sh" create' "$SPEC"
need "spec-validates-the-plan"      'plan-lint.sh" check' "$SPEC"
need "spec-hands-off-to-run"        '/cc-tuner:run docs/PLANS' "$SPEC"

# This checks the published instruction's order, not whether a model followed it. A lone
# `addBlockedBy` phrase used to report the whole two-pass contract as PASS.
task_create_line="$(grep -nF '`TaskCreate` once per slice' "$SPEC" | head -1 | cut -d: -f1)"
task_edges_line="$(grep -nF '`TaskUpdate` with `addBlockedBy`' "$SPEC" | head -1 | cut -d: -f1)"
task_list_line="$(grep -nF '`TaskList` and verify' "$SPEC" | head -1 | cut -d: -f1)"
if [ -n "$task_create_line" ] && [ -n "$task_edges_line" ] && [ -n "$task_list_line" ] \
   && [ "$task_create_line" -lt "$task_edges_line" ] && [ "$task_edges_line" -lt "$task_list_line" ]; then
  echo "PASS spec-instructs-two-pass-publication"
else
  echo "FAIL spec-instructs-two-pass-publication (create=$task_create_line edges=$task_edges_line list=$task_list_line)"
  fails=1
fi
# The task tools are opt-in from Claude Code 2.1.233 on current models, and nothing the plugin ships
# can turn them on. Three eval sessions published no visible plan while their operator watched for
# one, so the skill has to name what is lost rather than mention it in passing.
need "spec-names-the-optin"        'CLAUDE_CODE_ENABLE_TODO_TOOLS' "$SPEC"
[ ! -e "$ROOT/plugins/cc-tuner/skills/plan/SKILL.md" ] \
  && echo "PASS standalone-plan-skill-removed" \
  || { echo "FAIL standalone-plan-skill-removed"; fails=1; }

# Historical sections keep the old command name as evidence. The only still-executable migration
# checkpoint is Task 8 Step 7, and it must describe the current two-command lifecycle.
step7="$(sed -n '/^- \[[ x]\] \*\*Step 7:/,/^\*\*Acceptance:/p' "$BRANCH_PLAN")"
if [ -n "$step7" ] && ! printf '%s\n' "$step7" | grep -Eq '/cc-tuner:plan|/plan --auto'; then
  echo "PASS active-step7-omits-removed-plan"
else
  echo "FAIL active-step7-omits-removed-plan"
  fails=1
fi
need "deep-review-architecture" '**Architecture and systemic effects**' "$DEEP_REVIEW"
need "deep-review-exact-verdict" 'APPROVE <candidate SHA>' "$DEEP_REVIEW"
# 26 to 43 lenses ran against a stated 18, and the cost line asked for "current rates" the agent does
# not have. The limit and the printed line are what a user sees before paying.
need "deep-review-lens-limit"         '**The limit is 19 lenses**' "$DEEP_REVIEW"
need "deep-review-prints-the-fan-out" 'deep-review: <n> lenses (<k> opus, <m> sonnet) × effort high' "$DEEP_REVIEW"
# Past the limit the user decides, with the count and models in front of them; one agent ran 36
# lenses after asking, which the old wording only allowed when the user had already raised the limit.
# No lens asked what the user did not think of; reasoning-heavy lenses ran on the cheapest model.
if grep -qF 'current rates' "$DEEP_REVIEW" "$PLACEMENT"; then
  echo "FAIL deep-review-asks-for-unknown-prices"; fails=1
else
  echo "PASS deep-review-cost-needs-a-source"
fi
if grep -q '<tree SHA>' "$DEEP_REVIEW"; then
  echo "FAIL deep-review-still-requires-derived-tree-sha"
  fails=1
else
  echo "PASS deep-review-uses-one-candidate-identity"
fi
# /run owns routing; placement explains where selected lenses run, but copying thresholds there would
# make a future policy change a multi-file edit.
if grep -Eq '[0-9]+ (changed |production )?lines|[0-9]+ (production )?files' "$PLACEMENT"; then
  echo "FAIL review-thresholds-have-two-homes"
  fails=1
else
  echo "PASS review-thresholds-have-one-home"
fi
# The audit is conditional detail: ordinary authoring should not load its long procedure. The budget
# sentence is pinned because an earlier revision subtracted the global AGENTS.md even though Codex
# accounts user instructions outside project_doc_max_bytes.
need "claude-md-writer-links-audit" '[audit.md](audit.md)' "$CLAUDE_MD_WRITER"
need "claude-md-writer-uses-real-prompt" 'codex debug prompt-input' "$CLAUDE_MD_WRITER"
need "claude-md-audit-checks-old-pointers" "rg -nF -- '<old heading or path>'" "$CLAUDE_MD_AUDIT"
if grep -qF 'The `How to fix` section is mandatory' "$CLAUDE_MD_WRITER" \
  || grep -qF 'head -c 32768' "$CLAUDE_MD_WRITER" "$CLAUDE_MD_AUDIT"; then
  echo "FAIL claude-md-writer-restored-removed-universal-oracle"
  fails=1
else
  echo "PASS claude-md-writer-omits-universal-how-to-fix-and-hard-coded-budget"
fi

# `board: none` has to be decided before project scope is mentioned. Doctor deliberately reports the
# scope as WARN because it cannot know whether a board applies; reverting setup to the old unconditional
# refusal must make this ordering check fail.
board_skip_line="$(grep -nF 'skip the step' "$SETUP" | head -1 | cut -d: -f1)"
project_scope_line="$(grep -nF 'the `project` scope is required' "$SETUP" | head -1 | cut -d: -f1)"
if [ -n "$board_skip_line" ] && [ -n "$project_scope_line" ] \
   && [ "$board_skip_line" -lt "$project_scope_line" ]; then
  echo "PASS setup-board-none-precedes-project-scope"
else
  echo "FAIL setup-board-none-precedes-project-scope (skip=$board_skip_line scope=$project_scope_line)"
  fails=1
fi
# One setup, run as nodes; the old per-installer forwarders were removed after 0.15.0.
need "setup-routes-task-flow-node"   'references/task-flow-rule.md' "$SETUP"
need "setup-routes-statusline-node"  'references/statusline.md' "$SETUP"
# setup writes user-global settings, so it stays a user command. spec and run are how the agent
# enters the flow: when they were user-only, the agent rebuilt the lifecycle by hand without their text.
need "setup-is-user-invoked" 'disable-model-invocation: true' "$SETUP"
for lifecycle in "$SPEC" "$RUN"; do
  if grep -q '^disable-model-invocation: true' "$lifecycle"; then
    echo "FAIL $(basename "$(dirname "$lifecycle")")-is-model-invocable"; fails=1
  else
    echo "PASS $(basename "$(dirname "$lifecycle")")-is-model-invocable"
  fi
done
need "release-pr-status" 'context=release-pr/validate' "$RELEASE_WORKFLOW"
need "release-pr-exact-sha" 'ref: ${{ steps.release-pr.outputs.sha }}' "$RELEASE_WORKFLOW"
need "release-pr-runs-suite" 'run: bash tests/run.sh' "$RELEASE_WORKFLOW"
need "release-pr-fails-workflow" '[ "$state" = success ]' "$RELEASE_WORKFLOW"

# Every named step after the one that resolves the release PR works on it, so each is gated on the
# SHA that step found, not on prs_created: a re-run leaves prs_created false (release PR #64's
# validation failed on a flaky test and its re-run skipped every step).
release_pr_gate_count="$(grep -cF "steps.release-pr.outputs.sha != ''" "$RELEASE_WORKFLOW")"
release_pr_step_count="$(grep -cE '^ +- name:' "$RELEASE_WORKFLOW")"
[ "$release_pr_gate_count" -eq $((release_pr_step_count - 1)) ] && echo "PASS release-pr-gate-count" \
  || { echo "FAIL release-pr-gate-count (got $release_pr_gate_count gates for $release_pr_step_count steps)"; fails=1; }
need "release-pr-rechecks-on-rerun"   "github.run_attempt != '1' || github.event_name == 'workflow_dispatch'" "$RELEASE_WORKFLOW"
need "release-pr-found-on-rerun"      '--head release-please--branches--main' "$RELEASE_WORKFLOW"
need "release-pr-rerun-ignores-forks"  'select(.isCrossRepository == false)' "$RELEASE_WORKFLOW"
need "release-pr-rerun-targets-main"   '--state open --base main' "$RELEASE_WORKFLOW"
if grep -qF "steps.release.outputs.prs_created == 'true'" "$RELEASE_WORKFLOW"; then
  echo "FAIL release-pr-steps-gated-on-prs-created"; fails=1
else
  echo "PASS release-pr-steps-gated-on-the-found-sha"
fi

# Instruction surfaces, the installed template, both READMEs, the scenarios and the eval notes are
# what a stranger reads and what the model loads. A private repository name or a home-directory path
# there is a citation nobody else can check. History (CHANGELOG.md, docs/adr, archived plans) is not
# in this set on purpose: rewriting it to look public would be falsification, not portability.
if grep -RnE 'stokli|marqa|smartcat|/Users/[a-z]+/' \
     "$ROOT/plugins/cc-tuner/skills" "$ROOT/plugins/cc-tuner/assets" "$ROOT/plugins/cc-tuner/agents" \
     "$ROOT/plugins/cc-tuner/README.md" "$ROOT/README.md" \
     "$ROOT/tests/scenarios" "$ROOT/plugins/cc-tuner/tests/eval/README.md" 2>/dev/null; then
  echo "FAIL private-provenance-on-an-instruction-surface"; fails=1
else
  echo "PASS no-private-provenance-on-instruction-surfaces"
fi

if grep -En 'effort_tiering|small_diff_budget|assets/tiering|cheap_gate|≤50 changed lines|≤5 files' "$SPEC" "$RUN" >/dev/null; then
  echo "FAIL ignored-or-duplicated-policy"
  fails=1
else
  echo "PASS no-ignored-or-duplicated-policy"
fi

# Matt Pocock skills: each one cc-tuner names has a moment to run, and the review gets its inputs
# instead of asking for them under --auto.
need "spec-codebase-design-trigger"       '`mattpocock-skills:codebase-design`' "$SPEC"
need "spec-prototype-qualified"           '`mattpocock-skills:prototype`' "$SPEC"
need "placement-diagnosing-bugs-trigger"  '`mattpocock-skills:diagnosing-bugs`' "$PLACEMENT"
need "claude-md-writer-defers-wording"    '`mattpocock-skills:writing-for-agents`' "$CLAUDE_MD_WRITER"
# Field sessions (stokli, marqa) merged 21 PRs with 2 card moves: the lifecycle lived only in task-flow,
# which /run never loads. The moments live in spec and run; the recovery from a missing card or stale
# IDs lives in the recipes they send the agent to.
# /spec grilled only what was named: nothing asked what the user had not thought of. The pass is an
# adviser on Opus that cannot change the tree; the user decides what it raises.
BLIND="$ROOT/plugins/cc-tuner/agents/spec-blind-spots.md"
need "spec-dispatches-blind-spots"        'dispatch `cc-tuner:spec-blind-spots` once' "$SPEC"
need "spec-blind-spots-prints-its-cost"    'spec-blind-spots: 1 opus × effort high; cost:' "$SPEC"
need "spec-blind-spots-says-when-empty"    '`completed: no findings`' "$BLIND"
# Without a `tools` allowlist an agent inherits every tool, so the check needs the allowlist present,
# made only of read and web tools, and the write tools disallowed by name.
blind_front="$(sed -n '2,/^---$/p' "$BLIND" 2>/dev/null)"
blind_tools="$(printf '%s\n' "$blind_front" | sed -n 's/^tools: //p')"
blind_denied="$(printf '%s\n' "$blind_front" | sed -n 's/^disallowedTools: //p')"
blind_ok=1
printf '%s\n' "$blind_front" | grep -q '^model: opus$' || blind_ok=0
blind_count=0
for t in $(printf '%s' "$blind_tools" | tr ',' ' '); do
  blind_count=$((blind_count + 1))
  case "$t" in Read|Grep|Glob|WebSearch|WebFetch) ;; *) blind_ok=0 ;; esac
done
[ "$blind_count" -gt 0 ] || blind_ok=0
for t in Bash Edit Write Agent; do
  printf '%s' "$blind_denied" | tr ',' '\n' | sed 's/^ *//' | grep -qx "$t" || blind_ok=0
done
if [ "$blind_ok" = 1 ]; then
  echo "PASS spec-blind-spots-agent-is-opus-and-read-only"
else
  echo "FAIL spec-blind-spots-agent-is-opus-and-read-only"; fails=1
fi
# Grooming needed a branch: /spec created it before the interview. --groom records the outcome in the
# issue and nothing in git; a later /spec builds on that record instead of asking again.
need "spec-groom-mode"                    '`--groom`' "$SPEC"
need "spec-builds-on-the-groom-record"    'cc-tuner-groom:' "$SPEC"
# A public issue takes comments from anyone: only a record by someone with access settles decisions.
need "spec-trusts-a-groom-by-access"       '`authorAssociation`' "$GROOM"
# Verification output (test logs, browser snapshots) filled the orchestrator's context; the record is
# all /run needs back, and the owner still decides what only a person can see.
README_PLUGIN="$ROOT/plugins/cc-tuner/README.md"
need "readme-names-groom"                 'spec --groom <issue>' "$README_PLUGIN"
need "readme-names-blind-spots"           'Blind spots' "$README_PLUGIN"
if grep -Eq '^\| (tdd|research)' "$PLACEMENT"; then
  echo "FAIL placement-row-without-a-trigger"; fails=1
else
  echo "PASS placement-rows-have-triggers"
fi

# Outside GitHub no script refuses, so a written route is the whole gate: the same order and the same
# records as merge.sh, as steps the agent performs. Every element merge.sh enforces is named here, so a
# route that quietly drops one stops passing. The route texts are /run references read from the plugin;
# the repository keeps only the key block route.sh writes, so the old copied assets must be gone.
for gone in route-gitlab.md route-local.md; do
  if [ ! -e "$ROOT/plugins/cc-tuner/assets/task-flow/$gone" ]; then echo "PASS route-asset-$gone-is-gone"; else echo "FAIL route-asset-$gone-is-gone"; fails=1; fi
done
if [ -f "$ROUTE_GITLAB" ] && [ -f "$ROUTE_LOCAL" ]; then echo "PASS route-references-exist"; else echo "FAIL route-references-exist"; fails=1; fi
if grep -qF 'delivery-route' "$RULE_TEMPLATE"; then
  echo "FAIL rule-template-does-not-carry-the-route"; fails=1
else
  echo "PASS rule-template-does-not-carry-the-route"
fi
for rf in "$ROUTE_GITLAB" "$ROUTE_LOCAL"; do
  rn="${rf##*/}"
  need "$rn-codex-review-state"        'review-state.sh check <thread>' "$rf"
  need "$rn-codex-seven-field-marker"  'CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<head> tree=… base_sha=… spec_path=…' "$rf"
  need "$rn-codex-head-is-the-worktree-head" 'the worktree'"'"'s `git rev-parse HEAD`' "$rf"
  need "$rn-codex-finds-install-by-plugin-here" 'plugin-here.sh' "$rf"
  need "$rn-verdict-record"            'cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <full sha>' "$rf"
  need "$rn-verified-record"           'cc-tuner-verified: <full sha>' "$rf"
  need "$rn-local-ci-record"           'cc-tuner-local-ci: <full sha> <command and result>' "$rf"
  need "$rn-accepted-record"           'cc-tuner-accepted: <head sha> <who>: <what>' "$rf"
  need "$rn-never-relabels"            'relabel a `REQUEST_CHANGES` as `APPROVE`' "$rf"
  need "$rn-records-from-a-quoted-heredoc" "<<'EOF'" "$rf"
  need "$rn-ci-none-needs-a-record"    'ci: none:<reason>' "$rf"
  need "$rn-cleanup-by-merged-head"    'merged head' "$rf"
  if grep -qF 'CLAUDE_PLUGIN_ROOT' "$rf"; then echo "FAIL $rn-no-plugin-root-variable (unset outside skill bodies)"; fails=1; else echo "PASS $rn-no-plugin-root-variable"; fi
  if grep -qE -- '--(message|body|m) "<record>"|append -m' "$rf"; then echo "FAIL $rn-no-inline-record"; fails=1; else echo "PASS $rn-no-inline-record"; fi
done
need "route-gitlab-opens-a-draft"          'glab mr create --draft --yes --target-branch <target> --source-branch <branch>' "$ROUTE_GITLAB"
need "route-gitlab-requires-target-branch" 'require `target_branch` equal to `<target>`' "$ROUTE_GITLAB"
need "route-gitlab-requires-source-branch" '`source_branch` equal to `<branch>`' "$ROUTE_GITLAB"
need "route-gitlab-same-project"           '`source_project_id` equal to `target_project_id`' "$ROUTE_GITLAB"
need "route-gitlab-records-as-mr-notes"    'glab mr note create <iid> --resolvable=false --message "$(cat "$REC")" --repo "$GITLAB_REPO"' "$ROUTE_GITLAB"
need "route-gitlab-notes-ascending"        'notes?sort=asc&order_by=created_at" --hostname "$DELIVERY_HOST" --paginate' "$ROUTE_GITLAB"
need "route-gitlab-excludes-system-notes"  '.system == false' "$ROUTE_GITLAB"
need "route-gitlab-author-without-email"   'glab api user --hostname "$DELIVERY_HOST" | jq -r .username' "$ROUTE_GITLAB"
need "route-gitlab-latest-by-created-at"   'greatest `created_at`' "$ROUTE_GITLAB"
need "route-gitlab-verify-record-ancestry" 'git merge-base --is-ancestor <verified sha> <head>' "$ROUTE_GITLAB"
need "route-gitlab-approvals"              'merge_requests/<iid>/approvals' "$ROUTE_GITLAB"
need "route-gitlab-approvals-left"         '`approvals_left` 0' "$ROUTE_GITLAB"
need "route-gitlab-approvals-ask-a-human-under-auto" 'under `--auto` too' "$ROUTE_GITLAB"
need "route-gitlab-pipeline-project"       '`head_pipeline.project_id` equals `target_project_id`' "$ROUTE_GITLAB"
need "route-gitlab-pipeline-is-the-head"   'head_pipeline.sha' "$ROUTE_GITLAB"
need "route-gitlab-merged-results"         'merged-results pipeline' "$ROUTE_GITLAB"
need "route-gitlab-pipeline-success-only"  'status `success`' "$ROUTE_GITLAB"
need "route-gitlab-target-tip-ancestry"    'git merge-base --is-ancestor "$TIP" <head>' "$ROUTE_GITLAB"
need "route-gitlab-ready"                  'glab mr update <iid> --ready --repo "$GITLAB_REPO"' "$ROUTE_GITLAB"
need "route-gitlab-pinned-merge"           'glab mr merge <iid> --sha <head> --auto-merge=false --yes --repo "$GITLAB_REPO"' "$ROUTE_GITLAB"
need "route-gitlab-squash-by-spec"         '--squash' "$ROUTE_GITLAB"
need "route-local-notes-append-from-a-file" 'git notes --ref cc-tuner append -F "$REC" <judged sha>' "$ROUTE_LOCAL"
need "route-local-notes-show"              'git notes --ref cc-tuner show <sha>' "$ROUTE_LOCAL"
need "route-local-ancestor-lookup"         "git log --notes=cc-tuner --format='%H%n%N' <target>..<candidate>" "$ROUTE_LOCAL"
need "route-local-target-ref"              'refs/heads/<target>' "$ROUTE_LOCAL"
need "route-local-ancestry"                'git merge-base --is-ancestor <target tip> <candidate>' "$ROUTE_LOCAL"
need "route-local-verify-ancestry"         'git merge-base --is-ancestor <verified sha> <candidate>' "$ROUTE_LOCAL"
need "route-local-ff-only"                 'git merge --ff-only <candidate>' "$ROUTE_LOCAL"
need "route-local-update-ref-cas"          'git update-ref refs/heads/<target> <candidate> <old target tip>' "$ROUTE_LOCAL"
need "local-ci-record-from-a-file"         'gh pr comment <pr> --body-file "$REC"' "$ROOT/plugins/cc-tuner/skills/run/references/local-ci.md"
if grep -qF -- '--body "cc-tuner-local-ci' "$ROOT/plugins/cc-tuner/skills/run/references/local-ci.md"; then
  echo "FAIL local-ci-no-inline-record"; fails=1
else
  echo "PASS local-ci-no-inline-record"
fi

# The setup node that puts a route into the repository: argument-hint, the table row, a reference
# that is linked and exists, the ask-before-overwrite and write-from-the-user's-words behaviours, and
# the header that no longer promises setup never touches task-flow.local.md.
need "setup-hint-names-delivery-route"     'statusline|board|delivery-route]' "$SETUP"
need "setup-table-has-delivery-route"      '| 3b | delivery route |' "$SETUP"
need "setup-routes-delivery-route-node"    'references/delivery-route.md' "$SETUP"
if [ -f "$DELIVERY_REF" ]; then echo "PASS setup-delivery-route-reference-exists"; else echo "FAIL setup-delivery-route-reference-exists"; fails=1; fi
need "setup-route-host-from-host-sh"       'scripts/setup/host.sh' "$DELIVERY_REF"
need "setup-route-drives-route-sh-check"   'route.sh' "$DELIVERY_REF"
need "setup-route-check-command"           'bash "$ROUTE" check "$HOST" "$ROOT"' "$DELIVERY_REF"
need "setup-route-write-command"           'bash "$ROUTE" write "$HOST" "$LOCAL"' "$DELIVERY_REF"
need "setup-route-other-body-is-a-temp-file" 'BODY=$(mktemp)' "$DELIVERY_REF"
need "setup-route-stale-block-by-hand"     'by hand' "$DELIVERY_REF"
need "setup-route-reruns-locate"           'Re-run the **Locate** block' "$DELIVERY_REF"
if grep -qF 'sed -n "/^$OPEN' "$DELIVERY_REF" || grep -qF 'mv "$TMP" "$LOCAL"' "$DELIVERY_REF"; then
  echo "FAIL setup-route-has-no-inline-writer"; fails=1
else
  echo "PASS setup-route-has-no-inline-writer"
fi
# The plugin-root fallback is written once, in SKILL.md, and resolves the applicable installation; the old
# `find ~/.claude/plugins ... | sort | tail -1` could pick a fork or a lexically later, older version.
need "setup-plugin-root-section"           '## Plugin root' "$SETUP"
need "setup-plugin-root-asks-the-cli"      'claude plugin list --json' "$SETUP"
for ref in "$DELIVERY_REF" "$TASK_FLOW_REF" "$ROOT/plugins/cc-tuner/skills/setup/references/statusline.md"; do
  need "setup-reference-uses-the-plugin-root-block ($(basename "$ref"))" 'Plugin root' "$ref"
  if grep -qF 'sort | tail -1' "$ref"; then echo "FAIL setup-reference-no-find-fallback ($(basename "$ref"))"; fails=1; else echo "PASS setup-reference-no-find-fallback ($(basename "$ref"))"; fi
done
need "setup-node-3b-names-route-sh"        '`scripts/setup/route.sh`' "$SETUP"
need "setup-node-3b-names-the-run-reference" 'skills/run/references/route-<host>.md' "$SETUP"
need "local-header-has-one-owner" 'bash "$PLUGIN/scripts/setup/route.sh" header' "$TASK_FLOW_REF"
if grep -qF 'setup never touches this file' "$TASK_FLOW_REF"; then
  echo "FAIL local-header-no-longer-says-never-touches"; fails=1
else
  echo "PASS local-header-no-longer-says-never-touches"
fi

need "setup-hint-names-companions"          '[companions|agent-rules|' "$SETUP"
need "setup-table-has-companions"           '| 0c | companions |' "$SETUP"
need "setup-routes-companions-node"         'references/companions.md' "$SETUP"
if [ -f "$COMPANIONS_REF" ]; then echo "PASS setup-companions-reference-exists"; else echo "FAIL setup-companions-reference-exists"; fails=1; fi
need "setup-companions-drives-companion-sh" 'companion.sh' "$COMPANIONS_REF"
need "setup-companions-asks-per-plugin"     'multiSelect' "$COMPANIONS_REF"
need "setup-companions-records-optout"      'cc-tuner-review: none:' "$COMPANIONS_REF"
need "setup-declares-the-settings-write"    'enabledPlugins' "$SETUP"
need "setup-codex-audit-gated-on-codex"     'companion.sh codex' "$SETUP"
# install-hint.sh is gone: one owner of the hint, and no prose or script points at the old one.
if [ ! -e "$ROOT/plugins/cc-tuner/scripts/setup/install-hint.sh" ]; then echo "PASS install-hint-script-is-gone"; else echo "FAIL install-hint-script-is-gone"; fails=1; fi
if grep -rqF 'install-hint' "$ROOT/plugins/cc-tuner/scripts" "$ROOT/plugins/cc-tuner/skills" "$ROOT/plugins/cc-tuner/commands" 2>/dev/null; then
  echo "FAIL nothing-names-install-hint"; fails=1
else
  echo "PASS nothing-names-install-hint"
fi
# The companion table and the codex test live in companion.sh alone.
if grep -rnE 'codex login status|codex-not-logged-in|clicktronix/cc-codex-triage' "$ROOT/plugins/cc-tuner/scripts" | grep -v '/scripts/setup/companion.sh:' | grep -q .; then
  echo "FAIL companion-facts-live-in-companion-sh"; fails=1
else
  echo "PASS companion-facts-live-in-companion-sh"
fi
# The companions node runs after the testing runbook (0b) and before session env (4), in table order.
l0b="$(grep -nF '| 0b | testing runbook |' "$SETUP" | head -n 1 | cut -d: -f1)"
l0c="$(grep -nF '| 0c | companions |' "$SETUP" | head -n 1 | cut -d: -f1)"
l4="$(grep -nF '| 4 | session env |' "$SETUP" | head -n 1 | cut -d: -f1)"
if [ -n "$l0b" ] && [ -n "$l0c" ] && [ -n "$l4" ] && [ "$l0b" -lt "$l0c" ] && [ "$l0c" -lt "$l4" ]; then
  echo "PASS setup-companions-node-after-0b-before-4"
else
  echo "FAIL setup-companions-node-after-0b-before-4 (0b=$l0b 0c=$l0c 4=$l4)"; fails=1
fi
need "setup-companions-marketplace-add"     'claude plugin marketplace add' "$COMPANIONS_REF"
need "setup-companions-install"             'claude plugin install' "$COMPANIONS_REF"
need "setup-companions-enable-disabled"     'claude plugin enable' "$COMPANIONS_REF"
need "setup-companions-codex-gate"          'companion.sh codex' "$COMPANIONS_REF"
need "setup-companions-names-reload"        '/reload-plugins' "$COMPANIONS_REF"
need "setup-companions-verifies-with-list"  'claude plugin list --json' "$COMPANIONS_REF"
need "setup-manual-fresh-config-dir"        'CLAUDE_CONFIG_DIR' "$SETUP_MANUAL"

# /spec and /run follow the tracker file and the route. The tracker comes from the file mattpocock's
# setup writes, the host from the CLI that reaches the remote, and a non-github host delivers by the
# block /cc-tuner:setup wrote. Each phrase below is what a reader acts on; github keeps merge.sh.
need "spec-template-tracker-field"         'tracker: gh|glab|local|other|none — from docs/agents/issue-tracker.md' "$SPEC_TEMPLATE"
need "spec-offers-matt-pocock-setup"       '`/setup-matt-pocock-skills` now (a user-only command' "$SPEC"
need "spec-tracker-comes-from-the-file"    '`tracker:` from `docs/agents/issue-tracker.md`' "$SPEC"
need "spec-glab-issue-create"              '`glab issue create` / `glab issue note`' "$SPEC"
need "spec-local-issue-file" '[local-issues.md](../task-flow/references/local-issues.md)' "$SPEC"
need "spec-groom-glab-member-check"        'glab api projects/:id/members/all/<user id>' "$GROOM"
tracker_ask_line="$(grep -nF 'is absent, ask once with `AskUserQuestion`' "$SPEC" | head -1 | cut -d: -f1)"
host_detect_line="$(grep -nF 'Detect the host once the tracker is settled' "$SPEC" | head -1 | cut -d: -f1)"
if [ -n "$tracker_ask_line" ] && [ -n "$host_detect_line" ] && [ "$tracker_ask_line" -lt "$host_detect_line" ]; then
  echo "PASS spec-detects-host-after-the-tracker-ask"
else
  echo "FAIL spec-detects-host-after-the-tracker-ask (ask=$tracker_ask_line detect=$host_detect_line)"; fails=1
fi
need "run-redetects-the-host"              'Re-detect the host' "$RUN"
need "run-names-the-route-setup-command"   '`/cc-tuner:setup install delivery-route`' "$HOSTS"
# The host, the route check and the companion state are programs; /spec and /run call them and pin the
# command, not a restatement of what it knows (the prose ladder these replaced had drifted from doctor).
need "spec-asks-host-sh"                   'scripts/setup/host.sh' "$SPEC"
need "run-asks-host-sh"                    'scripts/setup/host.sh' "$RUN"
need "spec-template-host-from-host-sh"     'scripts/setup/host.sh' "$SPEC_TEMPLATE"
need "run-checks-delivery-for-every-host"  'For every delivery host' "$RUN"
need "delivery-executes-route-preflight"   'scripts/setup/route.sh" preflight' "$HOSTS"
need "run-checks-working-copy-explicitly"  '--local-only' "$RUN"
need "verify-labels-worktree-evidence"     'worktree verification (base <sha>)' "$VERIFY"
need "delivery-posts-the-saved-record"     'gh pr comment <pr> --body-file "$VERIFY_FILE"' "$DELIVERY"
# First delivery has no PR during verification. The saved record is posted in the open/reuse step.
if sed -n '/^## Verifying the feature$/,/^## Delivery$/p' "$RUN" | grep -q 'gh pr comment'; then
  echo "FAIL verification-posts-before-first-pr"; fails=1
elif sed -n '/^1\. \*\*Push and open or locate the PR/,/^2\. /p' "$DELIVERY" | grep -qF 'gh pr comment <pr> --body-file'; then
  echo "PASS verification-record-published-after-first-pr"
else
  echo "FAIL delivery-missing-record-in-open-pr-step"; fails=1
fi
need "run-reads-the-gitlab-route-from-the-plugin" '[route-gitlab.md](route-gitlab.md)' "$HOSTS"
need "run-reads-the-tracker-file"          'docs/agents/issue-tracker.md' "$DELIVERY"
need "spec-review-from-companion-sh"       'scripts/setup/companion.sh" review' "$SPEC"
need "spec-research-gated-on-codex-state"  'companion.sh" codex' "$ROOT/plugins/cc-tuner/skills/spec/references/optional-opinions.md"
need "spec-research-gated-on-install"      'cc-codex-triage@cc-codex-triage' "$ROOT/plugins/cc-tuner/skills/spec/references/optional-opinions.md"
need "spec-local-host-merges-ff"           'merge: ff' "$HOSTS"
need "spec-template-allows-ff"             'merge: squash|merge|ff' "$SPEC_TEMPLATE"
need "spec-local-tracker-link-file"        '.scratch/<slug>/spec.md' "$SPEC"
need "spec-groom-glab-access-level"        'access_level' "$GROOM"
need "shared-task-uses-host-preflight" '[hosts.md](hosts.md)' "$ROOT/plugins/cc-tuner/skills/run/references/shared-task.md"
need "task-flow-local-target-ref"          'refs/heads/<target>' "$TASK_FLOW"
need "task-flow-keeps-the-pull-for-remotes" 'git pull --ff-only' "$TASK_FLOW"
# The issue tracker is read before the issue: the issue lives where that file says.
tracker_read_line="$(grep -nF -- '- `docs/agents/issue-tracker.md`' "$SPEC" | head -1 | cut -d: -f1)"
issue_read_line="$(grep -nF -- '- the issue, when `$ARGUMENTS` names one' "$SPEC" | head -1 | cut -d: -f1)"
if [ -n "$tracker_read_line" ] && [ -n "$issue_read_line" ] && [ "$tracker_read_line" -lt "$issue_read_line" ]; then
  echo "PASS spec-reads-the-tracker-file-before-the-issue"
else
  echo "FAIL spec-reads-the-tracker-file-before-the-issue (tracker=$tracker_read_line issue=$issue_read_line)"; fails=1
fi
# Reach the common route preflight both before local work and at delivery entry.
run_host_line="$(grep -nF 'scripts/setup/host.sh' "$RUN" | head -1 | cut -d: -f1)"
run_first_ref="$(grep -nF '(references/hosts.md)' "$RUN" | head -1 | cut -d: -f1)"
run_loop_line="$(grep -n '^## The loop' "$RUN" | head -1 | cut -d: -f1)"
run_delivery_line="$(grep -n '^## Delivery' "$RUN" | head -1 | cut -d: -f1)"
run_delivery_ref="$(grep -nF '(references/delivery.md)' "$RUN" | head -1 | cut -d: -f1)"
delivery_host_ref="$(grep -nF '(hosts.md)' "$DELIVERY" | head -1 | cut -d: -f1)"
delivery_first_step="$(grep -n '^1\. ' "$DELIVERY" | head -1 | cut -d: -f1)"
if [ -n "$run_host_line" ] && [ -n "$run_first_ref" ] && [ -n "$run_loop_line" ] && [ -n "$run_delivery_line" ] \
   && [ -n "$run_delivery_ref" ] && [ -n "$delivery_host_ref" ] && [ -n "$delivery_first_step" ] \
   && [ "$run_host_line" -lt "$run_first_ref" ] && [ "$run_first_ref" -lt "$run_loop_line" ] \
   && [ "$run_delivery_line" -lt "$run_delivery_ref" ] && [ "$delivery_host_ref" -lt "$delivery_first_step" ]; then
  echo "PASS run-sends-all-hosts-to-hosts-md-before-the-loop-and-at-delivery"
else
  echo "FAIL run-sends-all-hosts-to-hosts-md-before-the-loop-and-at-delivery (host=$run_host_line first=$run_first_ref loop=$run_loop_line delivery=$run_delivery_line ref=$run_delivery_ref entry=$delivery_host_ref step1=$delivery_first_step)"; fails=1
fi
LOCAL_ISSUES="$ROOT/plugins/cc-tuner/skills/task-flow/references/local-issues.md"
need "local-issues-resolve-persistent-checkout" "git worktree list --porcelain | sed -n '1s/^worktree //p'" "$LOCAL_ISSUES"
need "task-flow-local-writes-use-shared-location" '[Local issue files](#local-issue-files)' "$TASK_FLOW"
if grep -qF '[local-issues.md](../task-flow/references/local-issues.md)' "$SPEC" \
   && grep -qF '[local-issues.md](../../task-flow/references/local-issues.md)' "$GROOM"; then
  echo "PASS spec-and-groom-share-local-issue-location"
else
  echo "FAIL spec-and-groom-share-local-issue-location"; fails=1
fi
LOCAL_CI="$ROOT/plugins/cc-tuner/skills/run/references/local-ci.md"
SHARED_TASK="$ROOT/plugins/cc-tuner/skills/run/references/shared-task.md"
need "task-flow-gitlab-merged-check"       'glab mr view <iid> --repo' "$TASK_FLOW"
need "task-flow-local-merged-check"        '`git rev-parse refs/heads/<target>`' "$TASK_FLOW"
need "task-flow-boards-are-github-only"    'Boards are GitHub-only' "$TASK_FLOW"
README_ROOT="$ROOT/README.md"
for readme in "$README_ROOT" "$README_PLUGIN"; do
  rn="${readme#$ROOT/}"
  need "readme-names-the-tracker-file ($rn)"  'docs/agents/issue-tracker.md' "$readme"
  need "readme-names-the-delivery-route ($rn)" 'delivery route' "$readme"
  if grep -qiF 'standalone without' "$readme"; then
    echo "FAIL readme-no-standalone-claim ($rn)"; fails=1
  else
    echo "PASS readme-no-standalone-claim ($rn)"
  fi
done
# Both Install sections end at the commands a fresh machine needs next, and the root README lists the nodes
# a fresh machine meets (companions, then the delivery route).
for readme in "$README_ROOT" "$README_PLUGIN"; do
  rn="${readme#$ROOT/}"
  install_section="$(sed -n '/^## Install/,/^## [^I]/p' "$readme")"
  if printf '%s\n' "$install_section" | grep -qF '`/reload-plugins`' \
     && printf '%s\n' "$install_section" | grep -qF '`/cc-tuner:setup install`'; then
    echo "PASS readme-install-ends-with-reload-and-setup ($rn)"
  else
    echo "FAIL readme-install-ends-with-reload-and-setup ($rn)"; fails=1
  fi
done
need "readme-root-lists-the-companions-node" 'environment, companions,' "$README_ROOT"
need "readme-plugin-names-route-sh"          'scripts/setup/route.sh' "$README_PLUGIN"
need "readme-plugin-names-host-sh"           'scripts/setup/host.sh' "$README_PLUGIN"
need "readme-plugin-names-companion-sh"      'scripts/setup/companion.sh' "$README_PLUGIN"
need "readme-codex-triage-is-optional"     '**cc-codex-triage** is optional' "$README_PLUGIN"
need "readme-codex-needs-login"            'logged-in Codex CLI' "$README_PLUGIN"

need "run-states-its-plugin-root"            '**Plugin root: `${CLAUDE_PLUGIN_ROOT}`.**' "$RUN"
need "run-accepted-from-a-file"              'gh pr comment <pr> --body-file "$REC"' "$DELIVERY"
need "companions-uses-the-plugin-root-block" 'C="$PLUGIN/scripts/setup/companion.sh"' "$ROOT/plugins/cc-tuner/skills/setup/references/companions.md"
if grep -q 'CLAUDE_PLUGIN_ROOT}/' "$ROOT/plugins/cc-tuner/skills/setup/references/companions.md"; then
  echo "FAIL companions-reference-does-not-expand-plugin-root"; fails=1
else echo "PASS companions-reference-does-not-expand-plugin-root"; fi
if grep -Eq 'marketplace update (mattpocock|cc-codex-triage) ' "$ROOT/plugins/cc-tuner/scripts/setup/prereq-check.sh"; then
  echo "FAIL prereq-update-hints-come-from-companion-table"; fails=1
else echo "PASS prereq-update-hints-come-from-companion-table"; fi

need "setup-plugin-root-uses-the-substituted-token" 'PLUGIN="${CLAUDE_PLUGIN_ROOT}"' "$SETUP"
if grep -qF 'CLAUDE_PLUGIN_ROOT:-' "$SETUP"; then echo "FAIL setup-plugin-root-no-shell-default"; fails=1; else echo "PASS setup-plugin-root-no-shell-default"; fi
need "companions-no-cli-prints-table-commands" '"$C" commands' "$ROOT/plugins/cc-tuner/skills/setup/references/companions.md"
need "route-gitlab-sets-squash-explicitly"   '-F squash=' "$ROUTE_GITLAB"
need "route-gitlab-reads-project-squash-option" 'squash_option' "$ROUTE_GITLAB"
need "run-other-route-from-the-fetched-target" 'git show FETCH_HEAD:.claude/rules/task-flow.local.md' "$HOSTS"
need "route-gitlab-explicit-api-project" 'projects/$GITLAB_PROJECT_ID/merge_requests/<iid>' "$ROUTE_GITLAB"
need "route-gitlab-reads-selected-git-target" 'git fetch "$DELIVERY_REMOTE" <target>' "$ROUTE_GITLAB"
need "route-github-explicit-repository" 'gh pr` command during delivery' "$HOSTS"
need "route-gitlab-target-tip-from-fetch-head" 'TIP=$(git rev-parse FETCH_HEAD)' "$ROUTE_GITLAB"
need "route-gitlab-strategy-before-check-only" '7. **Target and strategy.**' "$ROUTE_GITLAB"
COMPANIONS_MD="$ROOT/plugins/cc-tuner/skills/setup/references/companions.md"
if [ "$(grep -n '^1\. \*\*Fallbacks' "$COMPANIONS_MD" | cut -d: -f1)" != '' ] && [ "$(grep -n '^1\. \*\*Fallbacks' "$COMPANIONS_MD" | cut -d: -f1)" -lt "$(grep -n '^2\. \*\*Nothing to do' "$COMPANIONS_MD" | cut -d: -f1)" ]; then echo "PASS companions-fallbacks-before-nothing-to-do"; else echo "FAIL companions-fallbacks-before-nothing-to-do"; fails=1; fi

# Permission is decided once in /run; every delivery route follows that decision.
need "run-owns-merge-authorization" '**Merge authorization.**' "$RUN"
for route in "$ROUTE_GITLAB" "$ROUTE_LOCAL" "$SHARED_TASK"; do
  need "route-uses-shared-authorization ($(basename "$route"))" '**Merge authorization**' "$route"
done

# heavy.sh capacity (#72): callers pass a weight, carry a forced start into their report, and read
# capacity as derived from memory; the old "default 1" wording must not survive anywhere.
PLACEMENT="$ROOT/plugins/cc-tuner/skills/run/references/placement.md"
need "placement-heavy-call-has-weight"      'scripts/heavy.sh" --weight <w> --label' "$PLACEMENT"
need "placement-e2e-weighs-two"             'e2e suite: `--weight 2`' "$PLACEMENT"
need "placement-carries-forced-start"       'heavy.sh: started under memory pressure' "$PLACEMENT"
need "placement-carries-unmeasured-pressure" 'heavy.sh: memory pressure not measured' "$PLACEMENT"
if grep -qF 'do not exhaust memory together' "$PLACEMENT"; then echo "FAIL placement-no-memory-guarantee"; fails=1; else echo "PASS placement-no-memory-guarantee"; fi
if grep -qF 'from running them at once' "$ROOT/plugins/cc-tuner/README.md"; then echo "FAIL readme-heavy-no-exclusive-claim"; fails=1; else echo "PASS readme-heavy-no-exclusive-claim"; fi
need "readme-heavy-mem-wait"                'CC_TUNER_HEAVY_MEM_WAIT' "$ROOT/plugins/cc-tuner/README.md"
need "setup-heavy-override-user-wide"       'set it user-wide' "$SETUP"
need "setup-heavy-mem-wait"                'CC_TUNER_HEAVY_MEM_WAIT' "$SETUP"
need "readme-heavy-override-user-wide"      'set it user-wide' "$ROOT/plugins/cc-tuner/README.md"
if grep -rqF 'CC_TUNER_HEAVY_SLOTS`, default 1' "$ROOT/plugins/cc-tuner/skills" "$ROOT/plugins/cc-tuner/agents" "$ROOT/plugins/cc-tuner/README.md"; then
  echo "FAIL heavy-no-default-one-wording"; fails=1
else
  echo "PASS heavy-no-default-one-wording"
fi

# Session coordination (#73): the module owns the mechanism (hooks/peers.ts and its tests). Pinned here only
# what a machine consumes: the tool names skills call and allow, the ack prefix, the two file paths, the marker.
need "spec-calls-and-allows-peers-report"   'mcp__cc-tuner__peers_report' "$SPEC"
need "run-calls-and-allows-peers-claim"     'mcp__cc-tuner__peers_claim' "$RUN"
need "task-flow-releases-leases"            'mcp__cc-tuner__peers_release' "$TASK_FLOW"
need "setup-names-the-repository-resources-file" '.claude/cc-tuner-resources.json' "$SETUP"
need "setup-names-the-machine-resources-file"    '~/.config/cc-tuner/resources.json' "$SETUP"
need "readme-documents-the-ack"             'CC_TUNER_ACK=<key>' "$README_PLUGIN"
need "readme-documents-the-repository-resources-file" '.claude/cc-tuner-resources.json' "$README_PLUGIN"
need "readme-documents-the-machine-resources-file"    '~/.config/cc-tuner/resources.json' "$README_PLUGIN"
need "rule-template-marker-bumped"          'cc-tuner:task-flow v0.23.0' "$RULE_TEMPLATE"

exit "$fails"
