#!/usr/bin/env bash
# Static wiring checks for shipped instructions, templates and release configuration.
# These do not prove model behaviour. /run policy changes receive semantic review; model eval is
# historical unless EVALUATED_SHA covers them. Exact helper commands and machine-consumed markers
# remain checked here. Legacy wording assertions for other skills are not behavioural evidence.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SPEC="$ROOT/plugins/cc-tuner/skills/spec/SKILL.md"
SPEC_TEMPLATE="$ROOT/plugins/cc-tuner/skills/spec/spec-template.md"
RUN="$ROOT/plugins/cc-tuner/skills/run/SKILL.md"
DEEP_REVIEW="$ROOT/plugins/cc-tuner/skills/deep-review/SKILL.md"
PLACEMENT="$ROOT/plugins/cc-tuner/skills/run/references/placement.md"
SETUP="$ROOT/plugins/cc-tuner/skills/setup/SKILL.md"
TASK_FLOW_SETUP="$ROOT/plugins/cc-tuner/skills/task-flow-setup/SKILL.md"
STATUSLINE_SETUP="$ROOT/plugins/cc-tuner/skills/statusline-setup/SKILL.md"
TASK_FLOW="$ROOT/plugins/cc-tuner/skills/task-flow/SKILL.md"
CLAUDE_MD_WRITER="$ROOT/plugins/cc-tuner/skills/claude-md-writer/SKILL.md"
CLAUDE_MD_AUDIT="$ROOT/plugins/cc-tuner/skills/claude-md-writer/audit.md"
RULE_TEMPLATE="$ROOT/plugins/cc-tuner/assets/task-flow/rule.template.md"
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
need "spec-tracker-none-skips-issue"    'with `tracker: none`, skip that' "$SPEC"
need "writer-honours-installed-agent-rules" 'do not generate a per-repository skill or a pointer table' "$CLAUDE_MD_WRITER"
need "setup-has-a-remove-for-statusline" '/cc-tuner:setup remove statusline' "$SETUP"
need "setup-detects-task-tools-now" 'is `TaskCreate` in this session' "$SETUP"
need "setup-reports-the-testing-runbook" 'Testing runbook' "$SETUP"
need "placement-caps-the-active-set" 'counts running units' "$PLACEMENT"
# A second provider's research is optional and decided before discovery, so it overlaps the reading;
# asking in the section 3 batch would leave it nothing to overlap with. Its answer is evidence.
need "spec-routes-optional-opinions"      'references/optional-opinions.md' "$SPEC"
need "spec-opinions-before-discovery"     'before the reading, so it has' "$SPEC"
need "spec-opinions-are-evidence"         'never a decision' "$SPEC"
OPINIONS="$ROOT/plugins/cc-tuner/skills/spec/references/optional-opinions.md"
need "opinions-no-mandatory-chain"        'no chain of `ask` → `research` → `debate` exists' "$OPINIONS"
need "opinions-debate-is-owner-initiated" 'without a fresh' "$OPINIONS"
need "opinions-never-approval"            'never an approval' "$OPINIONS"
need "spec-loads-template" 'spec-template.md' "$SPEC"
need "spec-eyes-schema" 'checked by: <human step>; machine replacement: <exact check|none>; waiver: <user/date|none>' "$SPEC_TEMPLATE"
need "spec-dor" '## Definition of Ready' "$SPEC_TEMPLATE"
need "spec-first-failing-check" 'First failing check: <exact command>; expected failure:' "$SPEC_TEMPLATE"
need "spec-targeted-checks" 'Targeted checks: <exact commands>' "$SPEC_TEMPLATE"
need "spec-full-regression" 'Full regression: <exact command>' "$SPEC_TEMPLATE"
need "spec-dod" '## Definition of Done' "$SPEC_TEMPLATE"
need "spec-github-tracker" 'tracker: gh' "$SPEC_TEMPLATE"
need "spec-dod-routes-applicable-reviews" 'Applicable advisory reviews ran once' "$SPEC_TEMPLATE"
if grep -Eq 'passed deep review|exact SHA/tree|<tree SHA>' "$SPEC_TEMPLATE"; then
  echo "FAIL spec-template-requires-obsolete-review-policy"
  fails=1
else
  echo "PASS spec-template-uses-current-review-policy"
fi

# The branch must exist before grilling, because grilling invokes domain-modeling and that writes
# CONTEXT.md and ADRs -- committed artifacts, which must not land on the integration branch. Ordering
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
need "spec-trailers-from-the-repo" 'attribution trailers, comes from' "$SPEC"
need "task-flow-owns-the-trailer-rule" 'Attribution trailers are the repository' "$TASK_FLOW"
need "template-has-a-trailer-line"     '**Attribution trailers:**' "$RULE_TEMPLATE"
need "run-verdict-marker"           'cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <candidate-sha>' "$RUN"
need "run-merges-through-the-script" 'scripts/merge.sh' "$RUN"
need "run-codex-required-review"    '--required' "$RUN"
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
need "spec-rejects-plan-as-argument" 'never the plan path' "$SPEC"

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
need "spec-commits-reviewed-set"   'Commit the reviewed set together' "$SPEC"
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
need "deep-review-no-cap" 'never stop at an arbitrary count' "$DEEP_REVIEW"
need "deep-review-is-not-for-small-work" 'do not use for an ordinary small task' "$DEEP_REVIEW"
need "deep-review-architecture" '**Architecture and systemic effects**' "$DEEP_REVIEW"
need "deep-review-exact-verdict" 'APPROVE <candidate SHA>' "$DEEP_REVIEW"
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
need "claude-md-writer-user-budget-is-separate" 'user-level `~/.codex/AGENTS.md` is added separately and does not reduce it' "$CLAUDE_MD_WRITER"
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
board_skip_line="$(grep -nF 'skip the whole step' "$SETUP" | head -1 | cut -d: -f1)"
project_scope_line="$(grep -nF 'Only then is the `project` scope required' "$SETUP" | head -1 | cut -d: -f1)"
if [ -n "$board_skip_line" ] && [ -n "$project_scope_line" ] \
   && [ "$board_skip_line" -lt "$project_scope_line" ]; then
  echo "PASS setup-board-none-precedes-project-scope"
else
  echo "FAIL setup-board-none-precedes-project-scope (skip=$board_skip_line scope=$project_scope_line)"
  fails=1
fi
need "setup-auth-miss-is-login" '`gh auth login` — an interactive browser flow' "$SETUP"
# One setup, run as nodes. The two old installers are forwarders for one release: they must still be
# user-invoked (checked below) and must route to the node, never keep a workflow of their own.
need "setup-routes-task-flow-node"   'references/task-flow-rule.md' "$SETUP"
need "setup-routes-statusline-node"  'references/statusline.md' "$SETUP"
need "setup-audit-row-never-silent"  'audit: skipped — bridge not installed' "$SETUP"
need "setup-task-tools-not-verified-in-session" 'written; takes effect after restart' "$SETUP"
need "setup-cleanup-has-its-own-boundary" 'the install rule above does not cover it' "$SETUP"
need "task-flow-setup-forwards"      '/cc-tuner:setup install task-flow' "$TASK_FLOW_SETUP"
need "statusline-setup-forwards"     '/cc-tuner:setup install statusline' "$STATUSLINE_SETUP"
for forwarder in "$TASK_FLOW_SETUP" "$STATUSLINE_SETUP"; do
  if grep -qE 'mktemp|jq |cp "\$SRC"' "$forwarder"; then
    echo "FAIL $(basename "$(dirname "$forwarder")")-kept-its-own-procedure"; fails=1
  else
    echo "PASS $(basename "$(dirname "$forwarder")")-is-a-forwarder"
  fi
done
for setup_skill in "$SETUP" "$TASK_FLOW_SETUP" "$STATUSLINE_SETUP"; do
  need "$(basename "$(dirname "$setup_skill")")-is-user-invoked" 'disable-model-invocation: true' "$setup_skill"
done
need "release-pr-status" 'context=release-pr/validate' "$RELEASE_WORKFLOW"
need "release-pr-exact-sha" 'ref: ${{ steps.release-pr.outputs.sha }}' "$RELEASE_WORKFLOW"
need "release-pr-runs-suite" 'run: bash tests/run.sh' "$RELEASE_WORKFLOW"
need "release-pr-fails-workflow" '[ "$state" = success ]' "$RELEASE_WORKFLOW"
need "release-pr-create-update-gate" 'prs_created is true when a release PR is created or updated' "$RELEASE_WORKFLOW"

release_pr_gate_count="$(grep -cF "steps.release.outputs.prs_created == 'true'" "$RELEASE_WORKFLOW")"
[ "$release_pr_gate_count" -eq 4 ] && echo "PASS release-pr-gate-count" \
  || { echo "FAIL release-pr-gate-count (got $release_pr_gate_count, want 4)"; fails=1; }

# Three checks stood here: a nine-phase count, an index of twenty contract invariants named in
# run.md's Verification section, and a walk asserting nine phrases appeared in delivery order. All
# three measured the shape of the state machine. It is gone, and a test that counts the phases of a
# thing with no phases cannot be repaired, only deleted. What replaced their subject -- merge.sh --
# is covered by tests/flow/test_merge.sh against its actual argument boundary, which is a stronger
# check than any of them were.

# Instruction surfaces, the installed template, both READMEs, the scenarios and the eval notes are
# what a stranger reads and what the model loads. A private repository name or a home-directory path
# there is a citation nobody else can check. History (CHANGELOG.md, docs/adr, archived plans) is not
# in this set on purpose: rewriting it to look public would be falsification, not portability.
if grep -RnE 'stokli|marqa|smartcat|/Users/[a-z]+/' \
     "$ROOT/plugins/cc-tuner/skills" "$ROOT/plugins/cc-tuner/assets" \
     "$ROOT/plugins/cc-tuner/README.md" "$ROOT/README.md" \
     "$ROOT/tests/scenarios" "$ROOT/plugins/cc-tuner/tests/eval/README.md" 2>/dev/null; then
  echo "FAIL private-provenance-on-an-instruction-surface"; fails=1
else
  echo "PASS no-private-provenance-on-instruction-surfaces"
fi

if grep -En 'glab|effort_tiering|small_diff_budget|assets/tiering|cheap_gate|≤50 changed lines|≤5 files' "$SPEC" "$RUN" >/dev/null; then
  echo "FAIL ignored-or-duplicated-policy"
  fails=1
else
  echo "PASS no-ignored-or-duplicated-policy"
fi

exit "$fails"
