# cc-tuner git-flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `cc-tuner:git-flow` skill + `/cc-tuner:git-flow-setup` installer command that replace 11 drifted per-repo `git-flow.md` rule copies with one canonical, versioned template, plus board integration in `/execute-task` — released as cc-tuner v0.5.0.

**Architecture:** Same pattern as statusline: on-demand knowledge lives in a skill; the non-shippable artifact (`.claude/rules/git-flow.md`) is installed into each repo by a setup command from a template in `assets/`, with a content-comparison update path and a never-touched `git-flow.local.md` for repo deltas. Design of record: `docs/superpowers/specs/2026-07-16-git-flow-design.md`.

**Tech Stack:** Claude Code plugin markdown (commands with frontmatter, SKILL.md), bash snippets inside command playbooks (macOS bash 3.2 + Linux compatible), eval scenario JSON.

## Global Constraints

- Branch: `feat/git-flow-skill` (already created; spec committed as `c1b2b94`).
- Commit style: short imperative subjects, no conventional-commit prefixes (repo convention), **no Co-Authored-By trailers**.
- All bash in command playbooks must run on macOS bash 3.2.57 and Linux (no `mapfile`, no `${var,,}`, no GNU-only flags).
- Version bump to **0.5.0** in exactly 3 JSON spots: `.claude-plugin/marketplace.json` (metadata.version + plugins[0].version) and `plugins/cc-tuner/.claude-plugin/plugin.json`.
- Canonical policy decisions (from spec §2, do not re-litigate): no enforcement hooks; tiny doc-PRs are batched (stokli policy); plans in `wiki/PLANS/` with `docs/PLANS/` fallback; board = recipes in skill + execute-task integration.
- The template's plans-path token is `{{PLANS_ROOT}}` — the setup command substitutes `wiki` or `docs`.
- Skill/command/template prose is in English (repo convention for shipped plugin content).

---

### Task 1: Rule template asset

**Files:**
- Create: `plugins/cc-tuner/assets/git-flow/rule.template.md`

**Interfaces:**
- Produces: the canonical rule template. Task 3's setup command reads it at `${CLAUDE_PLUGIN_ROOT}/assets/git-flow/rule.template.md`, substitutes `{{PLANS_ROOT}}`, and compares/installs. Task 2's skill is referenced from the template's intro line as `cc-tuner:git-flow` — the name must match Task 2's frontmatter `name`.

- [ ] **Step 1: Write the template file**

Create `plugins/cc-tuner/assets/git-flow/rule.template.md` with exactly this content:

````markdown
<!-- cc-tuner:git-flow v0.5.0 — installed by /cc-tuner:git-flow-setup. Do not hand-edit: re-run the setup command to update. Repo-specific deltas belong in git-flow.local.md next to this file. -->

# Git flow — branches, commits, PRs, tasks

Advisory rules (no enforcement hooks). Procedures — board recipes, merge
strategies, plan lifecycle, anti-pattern case studies — live in the
`cc-tuner:git-flow` skill: invoke it when touching the project board, opening
a non-trivial PR, or managing plan documents. Where `git-flow.local.md`
conflicts with this file, the local file wins.

## Branches

- `<type>/<issue>-<kebab-slug>`, ≤50 chars. No issue → `<type>/<short-slug>`, justify in the PR body.
- Types: `feat | fix | refactor | perf | chore | docs | test | build | ci`.
- Never commit directly to `main` — branch first (`git switch -c <branch>`). On `main` with uncommitted work: stash → branch → pop.
- Branch lifetime ≤ 48h wall-clock — older: rebase onto `origin/main` before push.
- No long-lived staging branches (`develop`, `staging`) — squash-merging feature PRs into one breaks ancestry and the next merge to `main` surfaces ghost-conflicts. Short branches straight to `main`; feature flags for incomplete work.

## Commits — Conventional Commits v1.0.0

```
<type>[(<scope>)][!]: <imperative subject ≤72 chars, no period>

<body — what changed and why, if non-trivial>

[footers: BREAKING CHANGE: <migration note> / Closes #<N> / Refs #<N>]
```

- Breaking change: `!` after type/scope (semver-major signal) plus a `BREAKING CHANGE:` footer with the migration note. `!` without the footer → the subject/body MUST describe the break.
- Always a NEW commit — never `--amend` / force-push unless the user explicitly asks. After a failed pre-commit hook the commit did NOT happen; `--amend` would rewrite the *previous* commit and destroy work.
- Never `--no-verify` / `--no-gpg-sign`. A failing hook is a signal to diagnose, not silence.
- Stage explicitly by path — no `git add -A` / `git add .` (sweeps `.env`, credentials, unrelated WIP into commits).
- One commit = one logical change. A WIP chain is fine during work — squash-on-merge collapses it.

## Pull Requests

- Link the issue: `Closes #N` / `Fixes #N` only when the PR fully completes it; `Refs #N` for partial/stacked work. No issue → state why in the body.
- Verification gate: the PR body carries a checkbox list of this repo's lint/typecheck/test results with real output. "I believe the tests pass" is not evidence.
- Feature → `main`: squash-merge with `--delete-branch`. Never force-push `main` or any branch with open review comments.
- **No tiny doc-only PRs:** a single-file doc fix folds into an open PR or waits for a batch of 3+ small changes. Standalone only if urgent AND the user explicitly confirms.

## Tasks (GitHub Projects)

- Anything larger than one commit/PR, every deferred review finding, every audit bug → an issue **created on the project board with Status/Priority set** — a bare `gh issue create` leaves the card off every filtered view (recipes: `cc-tuner:git-flow` skill).
- The card moves with the work: In Progress at start, Done after merge.

## Plans

- Needed when: >1 PR, >2 days, or 3+ components. Not for drive-by fixes or single-file changes.
- Drafts scratch in git-ignored `docs/superpowers/plans/`; a plan worth keeping is promoted to `{{PLANS_ROOT}}/PLANS/YYYY-MM-DD-<slug>.md`; completed plans move to `{{PLANS_ROOT}}/ARCHIVE/PLANS/` (in the same PR that completes them — not a standalone doc PR).
- The plan links its issue in the first paragraph; the branch follows the issue number; the PR body says `Implements plan {{PLANS_ROOT}}/PLANS/<file> → Closes #N` (or `Refs #N` when partial).
````

- [ ] **Step 2: Verify the token and marker are in place**

Run: `grep -c '{{PLANS_ROOT}}' plugins/cc-tuner/assets/git-flow/rule.template.md && head -1 plugins/cc-tuner/assets/git-flow/rule.template.md | grep -o 'cc-tuner:git-flow v0.5.0'`
Expected: `2` (grep -c counts lines; the token appears 3 times on 2 lines) then `cc-tuner:git-flow v0.5.0`.

- [ ] **Step 3: Commit**

```bash
git add plugins/cc-tuner/assets/git-flow/rule.template.md
git commit -m "Add canonical git-flow rule template"
```

---

### Task 2: git-flow skill

**Files:**
- Create: `plugins/cc-tuner/skills/git-flow/SKILL.md`

**Interfaces:**
- Consumes: nothing.
- Produces: skill `git-flow` (frontmatter `name: git-flow`) invoked as `cc-tuner:git-flow` — the name the Task 1 template and Task 4 execute-task edits point at. Board recipes here are THE single copy; other files only reference them.

- [ ] **Step 1: Write the skill**

Create `plugins/cc-tuner/skills/git-flow/SKILL.md` with exactly this content:

````markdown
---
name: git-flow
description: Use when creating branches/commits/PRs in the user's repos, managing task cards on a GitHub Projects board (create issue with Status/Priority, move In Progress/Done), promoting or archiving plan documents, or choosing a merge strategy for stacked PRs. Companion to the .claude/rules/git-flow.md rule installed by /cc-tuner:git-flow-setup.
---

# Git Flow — procedures

The always-on invariants (branch naming, commit format, prohibitions, tiny-PR
batching) live in the repo's `.claude/rules/git-flow.md`, installed by
`/cc-tuner:git-flow-setup`. This skill carries the procedures that don't need
to sit in every session's context. Repo deltas (board name, labels): check
`.claude/rules/git-flow.local.md` first.

## Board recipes (GitHub Projects)

**Create an issue directly on the board (preferred):**

```bash
gh issue create --repo <owner>/<repo> --title "..." --label "..." --project "<PROJECT TITLE>"
```

`--project` takes the project **title**, not `owner/number`. Then set fields —
without Status/Priority the card sits in the default column and drops out of
filtered views:

```bash
gh project field-list <NUMBER> --owner <owner> --format json   # once per board; note field + option IDs
gh project item-add <NUMBER> --owner <owner> --url <issue-url>  # for existing issues
gh project item-edit --project-id <PID> --id <ITEM_ID> --field-id <FID> --single-select-option-id <OID>
```

Cache the IDs from `field-list` in `.claude/rules/git-flow.local.md` the first
time you fetch them — they are stable per board, and re-fetching every time is
the main friction that makes agents skip the board.

**Card lifecycle:** In Progress when the branch is created; Done after merge.
One deferred review finding = one issue (never a buried comment-thread list).

## Merge strategies

- Feature → `main`: **squash** + `--delete-branch` — linear trunk, WIP chain collapses.
- Stacked PRs: **merge-commit inside the chain** (preserves ancestry), squash only when the top of the stack lands on `main`. Squashing mid-chain orphans the SHAs of every PR above (see Anti-patterns).
- Re-check the base of each stacked PR after the one below merges.

## Plan lifecycle

1. Draft where superpowers scratches them: `docs/superpowers/plans/` (git-ignored).
2. Worth keeping → promote to `<plans-root>/PLANS/YYYY-MM-DD-<slug>.md` (the installed rule names the root for this repo: `wiki/` or `docs/`). Minimum header: `Goal:`, `Architecture:`, then tasks with file paths.
3. First paragraph links the tracking issue; the issue body links the plan back.
4. Completed → move to `<plans-root>/ARCHIVE/PLANS/` **in the same PR that completes the work** — never as a standalone doc PR.

## Anti-patterns (case studies)

- **Long-lived staging branch + squash** — real incident 2026-06-04/05: `perf-quality-audit` squashed to `main` as PR #50, then 8 follow-up PRs (#51–#58) squash-targeted the dead branch; the final merge was impossible and all 8 commits had to be cherry-picked onto a fresh branch (PR #61). Short branches straight to `main`.
- **Issue off the board** — real incident 2026-06-05: 9 issues created via bare `gh issue create`; none reached the board until an explicit request. Always create with `--project` + set Status/Priority.
- **Tiny doc-PR spam** — real incident 2026-06-05 (marqa-tech/analyzer PR #23): standalone PR for 3 wording fixes in one file; user: "We waste time and tokens on that junk." Fold into an open PR or batch 3+.
- **Amend after hook failure** — the commit did not happen; `--amend` rewrites the previous one and loses work. Fix → re-stage → new commit.
- **First-words branch name** (`001-make-sure-portfolio-...`) — name by feature, not by the prompt's opening words.
- **Orphan branch** — work finished in a worktree, PR never opened, branch rots. Opening the PR is part of finishing.

## Pre-PR checklist

- [ ] Branch off fresh `origin/main` (rebase if >24h old)
- [ ] Commits follow Conventional Commits (incl. `!`/`BREAKING CHANGE:` where applicable)
- [ ] Issue exists, linked (`Closes #N`/`Refs #N`), card has Status/Priority
- [ ] PR body: verification checkbox list with real lint/typecheck/test output
- [ ] Plan promoted/archived if this PR completes it
- [ ] No `.env`, credentials, generated files staged

## Why

Every rule reacts to a documented failure, not theoretical hygiene: staging-branch
ghost-conflicts (2026-06-04), board-less issues (2026-06-05), tiny-PR feedback
(2026-06-05), amend-after-hook data loss (Claude Code default-instruction failure
mode). Dates kept so future edits can check whether the failure still reproduces.
````

- [ ] **Step 2: Verify frontmatter parses and name matches references**

Run: `head -4 plugins/cc-tuner/skills/git-flow/SKILL.md | grep 'name: git-flow' && grep -l 'cc-tuner:git-flow' plugins/cc-tuner/assets/git-flow/rule.template.md`
Expected: both lines print (name found; template references the skill).

- [ ] **Step 3: Commit**

```bash
git add plugins/cc-tuner/skills/git-flow/SKILL.md
git commit -m "Add git-flow skill with board recipes and plan lifecycle"
```

---

### Task 3: git-flow-setup command

**Files:**
- Create: `plugins/cc-tuner/commands/git-flow-setup.md`

**Interfaces:**
- Consumes: `${CLAUDE_PLUGIN_ROOT}/assets/git-flow/rule.template.md` (Task 1).
- Produces: `/cc-tuner:git-flow-setup` with subcommands `install` (default) / `update` / `status`.

- [ ] **Step 1: Write the command playbook**

Create `plugins/cc-tuner/commands/git-flow-setup.md` with exactly this content:

````markdown
---
description: Install or update the canonical .claude/rules/git-flow.md in the current repo from the cc-tuner template (detects wiki/ vs docs/ plans root, preserves git-flow.local.md deltas, offers legacy cleanup).
---

# /cc-tuner:git-flow-setup

Claude Code plugins **cannot ship `.claude/rules/*`** — rules are not a plugin
component. This command installs the canonical git-flow rule from the plugin's
template into the current repository, the same way `/cc-tuner:statusline-setup`
installs the statusline.

Parse `$ARGUMENTS`: first token is `install` (default if empty), `update`
(alias of install — the flow is identical and idempotent), or `status`.

## Locate the template and the repo

```bash
SRC="${CLAUDE_PLUGIN_ROOT:-}/assets/git-flow/rule.template.md"
if [ ! -f "$SRC" ]; then
  SRC=$(find "$HOME/.claude/plugins" -path '*/cc-tuner/assets/git-flow/rule.template.md' 2>/dev/null | sort | tail -1)
fi
[ -f "$SRC" ] || { echo "Could not locate rule.template.md — is cc-tuner installed?"; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository"; exit 1; }
DEST="$ROOT/.claude/rules/git-flow.md"
LOCAL="$ROOT/.claude/rules/git-flow.local.md"
```

## Detect the plans root and render the template

`wiki/` directory exists at the repo root → plans root is `wiki`; otherwise `docs`.

```bash
if [ -d "$ROOT/wiki" ]; then PLANS_ROOT="wiki"; else PLANS_ROOT="docs"; fi
RENDERED=$(sed "s|{{PLANS_ROOT}}|$PLANS_ROOT|g" "$SRC")
```

When `PLANS_ROOT` is `docs`, tell the user after installing: "plans root is
`docs/` — when this repo migrates human docs to `wiki/`, re-run
`/cc-tuner:git-flow-setup` to update the paths."

## status

- No `$DEST` → report "not installed".
- `$DEST` exists → print its first line (the marker). If the file content equals
  `$RENDERED` → "up to date". Differs → "outdated or locally modified — run
  `/cc-tuner:git-flow-setup update`" and show `diff` output. Also report whether
  `$LOCAL` exists. Take no other action.

## install / update

1. **No existing file** → write it:
   ```bash
   mkdir -p "$ROOT/.claude/rules"
   printf '%s\n' "$RENDERED" > "$DEST"
   echo "Installed $DEST (plans root: $PLANS_ROOT)"
   ```
2. **Existing file, content identical to `$RENDERED`** → "up to date", stop.
3. **Existing file with our marker** (first line contains `cc-tuner:git-flow`)
   but different content → show `diff "$DEST" <(printf '%s\n' "$RENDERED")` to
   the user. Hand-edits would be lost — they belong in `git-flow.local.md`.
   Ask before overwriting (AskUserQuestion: overwrite / keep). On overwrite,
   suggest moving any local edits visible in the diff into `$LOCAL`.
4. **Existing file WITHOUT our marker** — a legacy hand-maintained copy (the
   11 pre-plugin copies across marqa/stokli). Show the diff, say this replaces
   the legacy copy with the canonical versioned one, and ask before
   overwriting. Never overwrite a legacy file silently.
5. **Deltas file** — if `$LOCAL` does not exist, create it:
   ```bash
   [ -f "$LOCAL" ] || printf '%s\n' \
     "# git-flow — repo-specific deltas" \
     "" \
     "<!-- Overrides and additions to git-flow.md live here; /cc-tuner:git-flow-setup never touches this file." \
     "     Typical content: board name/number + cached field IDs, label taxonomy, merge-policy exceptions. -->" \
     > "$LOCAL" && echo "Created $LOCAL (edit it for repo-specific deltas)"
   ```
6. **Legacy cleanup** — if `$ROOT/.claude/rules/no-tiny-doc-prs.md` exists,
   tell the user its policy now lives inside the canonical rule (Pull Requests
   section) and ask whether to delete it. Never delete without confirmation.
7. Remind: the rule is advisory (no hooks, by design), and the procedures live
   in the `cc-tuner:git-flow` skill.

## Verification

- [ ] `$DEST` starts with the `cc-tuner:git-flow` marker line.
- [ ] `grep '{{PLANS_ROOT}}' "$DEST"` finds nothing (token substituted).
- [ ] Re-running the command reports "up to date" and writes nothing.
````

- [ ] **Step 2: Dry-run the command's bash in a throwaway repo**

Run:
```bash
T=$(mktemp -d) && cd "$T" && git init -q . && mkdir -p wiki
SRC=/Users/clicktronix/Projects/ai/cc-tuner/plugins/cc-tuner/assets/git-flow/rule.template.md
ROOT=$(git rev-parse --show-toplevel) && mkdir -p "$ROOT/.claude/rules"
if [ -d "$ROOT/wiki" ]; then PLANS_ROOT="wiki"; else PLANS_ROOT="docs"; fi
RENDERED=$(sed "s|{{PLANS_ROOT}}|$PLANS_ROOT|g" "$SRC")
printf '%s\n' "$RENDERED" > "$ROOT/.claude/rules/git-flow.md"
head -1 "$ROOT/.claude/rules/git-flow.md" | grep -c 'cc-tuner:git-flow'
grep -c 'wiki/PLANS' "$ROOT/.claude/rules/git-flow.md"
grep -c '{{PLANS_ROOT}}' "$ROOT/.claude/rules/git-flow.md" || true
cd - && rm -rf "$T"
```
Expected: `1`, then `2` (wiki paths substituted), then `0` (no unsubstituted token).

- [ ] **Step 3: Commit**

```bash
git add plugins/cc-tuner/commands/git-flow-setup.md
git commit -m "Add /cc-tuner:git-flow-setup installer command"
```

---

### Task 4: execute-task board integration

**Files:**
- Modify: `plugins/cc-tuner/commands/execute-task.md` (steps 1, 8, 10)
- Modify: `plugins/cc-tuner/assets/execute-task/config.template.md` (new `board` key)

**Interfaces:**
- Consumes: skill name `cc-tuner:git-flow` (Task 2) for board recipes.
- Produces: config key `board` (project title + owner; blank = board steps skipped).

- [ ] **Step 1: Edit step 1 (Intake) — card to In Progress**

In `plugins/cc-tuner/commands/execute-task.md`, replace:

```
- **1 — Intake + DoR/DoD.** Fetch the issue per `tracker`. If anything is unclear, invoke `superpowers:brainstorming`. Write DoR/DoD with acceptance criteria, each tagged `[machine]` or `[eyes]`. `🚦` always (this is the point of `brainstorm-only`).
```

with:

```
- **1 — Intake + DoR/DoD.** Fetch the issue per `tracker`. If `tracker` is `gh` and the config's `board` is set, move the issue's card to **In Progress** (recipes: `cc-tuner:git-flow` skill; board not set or card lookup fails → journal and continue, never block intake on the board). If anything is unclear, invoke `superpowers:brainstorming`. Write DoR/DoD with acceptance criteria, each tagged `[machine]` or `[eyes]`. `🚦` always (this is the point of `brainstorm-only`).
```

- [ ] **Step 2: Edit step 8 (reconcile) — archive the plan before merge**

Replace:

```
- **8 — reconcile.** Tick off plan + DoD items; journal what shipped vs deferred.
```

with:

```
- **8 — reconcile.** Tick off plan + DoD items; journal what shipped vs deferred. If a promoted plan document exists for this task (`wiki/PLANS/` or `docs/PLANS/`) and its work is complete, move it to the matching `ARCHIVE/PLANS/` dir as part of this branch — per the git-flow rule, plan archival rides the PR that completes it, never a standalone doc PR.
```

- [ ] **Step 3: Edit step 10 (merge) — card to Done**

Replace:

```
- **10 — merge.** Run the guard again with the merge target (`guard-artifacts.sh <merge-target>`), show the exact commit/diff + rollback path, then merge per `merge`. Default: stop for confirmation even in `brainstorm-only`; only `merge: auto` waives that.
```

with:

```
- **10 — merge.** Run the guard again with the merge target (`guard-artifacts.sh <merge-target>`), show the exact commit/diff + rollback path, then merge per `merge`. Default: stop for confirmation even in `brainstorm-only`; only `merge: auto` waives that. After a successful merge, when `board` is set: verify the PR carried its issue link (`Closes #N`/`Refs #N`) and move the card to **Done** (recipes: `cc-tuner:git-flow` skill; failures here are journaled, they do not un-merge).
```

- [ ] **Step 4: Add the `board` config key**

In `plugins/cc-tuner/assets/execute-task/config.template.md`, insert after the `- **tracker**: ...` line:

```
- **board**: GitHub Project for task cards — title + owner (e.g. `"Dev Board", owner clicktronix`). Blank = board steps in 1/10 are skipped (journaled). Cache field IDs in `.claude/rules/git-flow.local.md` per the git-flow skill.
```

- [ ] **Step 5: Verify edits landed**

Run: `grep -c 'cc-tuner:git-flow' plugins/cc-tuner/commands/execute-task.md && grep -c 'board' plugins/cc-tuner/assets/execute-task/config.template.md`
Expected: `2` (steps 1 and 10) and ≥`2`.

- [ ] **Step 6: Commit**

```bash
git add plugins/cc-tuner/commands/execute-task.md plugins/cc-tuner/assets/execute-task/config.template.md
git commit -m "Integrate board lifecycle into execute-task intake and merge"
```

---

### Task 5: Eval scenarios

**Files:**
- Create: `tests/scenarios/git-flow/tiny-doc-pr-batching.json`
- Create: `tests/scenarios/git-flow/issue-without-board-status.json`
- Modify: `tests/scenarios/README.md` (status table + intro list of skills)

**Interfaces:**
- Consumes: guidance text from Task 1 (tiny-PR rule) and Task 2 (board recipes) — GREEN probes quote it verbatim.
- Produces: two scenarios whose REDs are **documented historical incidents** (2026-06-05), not fresh probe runs; GREEN probes are run as part of this task.

- [ ] **Step 1: Write `tests/scenarios/git-flow/tiny-doc-pr-batching.json`**

```json
{
  "skills": ["git-flow"],
  "tests_reference": "assets/git-flow/rule.template.md",
  "query": "A reviewer flagged 3 wording fixes in docs/plans/X.md of an already-merged PR. There is an open PR #22 in the same repo touching adjacent docs. Fix the wording. What do you do with the change?",
  "baseline_failure": "RED (historical, 2026-06-05, marqa-tech/analyzer PR #23): the agent opens a standalone docs-only PR for one file; user feedback verbatim: 'stop making separate MRs just to update documentation with a single file. We waste time and tokens on that junk.'",
  "expected_behavior": [
    "Folds the doc fix into open PR #22 as a separate commit, or explicitly waits to batch 3+ small changes",
    "Opens a standalone PR only if the fix is urgent AND the user explicitly confirms"
  ],
  "anti_expectation": [
    "Does NOT refuse to make the edit at all — batching is about PR ceremony, not about skipping the fix",
    "Does NOT bury unrelated large changes in PR #22 under cover of 'batching'"
  ],
  "baseline_observed": {
    "date": "2026-06-05",
    "method": "historical production incident (pre-plugin), recorded in stokli no-tiny-doc-prs.md",
    "runs": [{"model": "production session", "framing": "post-merge review follow-up", "red": true}],
    "verdict": "reproduced in production; canonical rule encodes the user's direct feedback"
  }
}
```

- [ ] **Step 2: Write `tests/scenarios/git-flow/issue-without-board-status.json`**

```json
{
  "skills": ["git-flow"],
  "tests_reference": "skills/git-flow/SKILL.md",
  "query": "Code review of the merged payments PR deferred 4 follow-up findings. Create tracking for them in the GitHub repo <owner>/<repo> which uses a GitHub Projects board 'Dev Board'. Do not read the filesystem; answer with the exact commands you would run.",
  "baseline_failure": "RED (historical, 2026-06-05): 9 issues created via bare `gh issue create` — none reached the project board until the user explicitly asked; cards without Status/Priority drop out of every filtered view.",
  "expected_behavior": [
    "One issue per finding (not one umbrella issue, not a comment thread)",
    "Creates each issue on the board (`--project \"Dev Board\"`) or follows with `gh project item-add`",
    "Sets Status/Priority via `gh project item-edit` after fetching field IDs once with `gh project field-list`"
  ],
  "anti_expectation": [
    "Does NOT stop at bare `gh issue create` with no board placement",
    "Does NOT invent `--project owner/number` syntax (the flag takes the project title)"
  ],
  "baseline_observed": {
    "date": "2026-06-05",
    "method": "historical production incident (pre-plugin), recorded in git-flow.md §Why",
    "runs": [{"model": "production session", "framing": "post-review follow-ups", "red": true}],
    "verdict": "reproduced in production; skill encodes create-on-board recipes + field-ID caching"
  }
}
```

- [ ] **Step 3: Run GREEN probes**

For each scenario: dispatch 2 isolated haiku subagents (`Agent` tool, `model: haiku`), prompt = the scenario `query` + the relevant guidance verbatim (Task 1 template's Pull Requests section for tiny-PR; Task 2 skill's Board recipes section for board). Record results in a `green_check` object in each JSON (same shape as existing cc-tuner scenarios: `{date, runs[], verdict}`). Expected: agents fold/batch instead of opening a standalone PR; agents create issues on the board with Status/Priority. If a probe does not flip, tighten the guidance wording and re-run before proceeding.

- [ ] **Step 4: Update `tests/scenarios/README.md`**

Add two rows to the status table:

```markdown
| git-flow/tiny-doc-pr-batching | historical incident 2026-06-05 (RED in production) | <GREEN result> | policy encodes direct user feedback |
| git-flow/issue-without-board-status | historical incident 2026-06-05 (RED in production) | <GREEN result> | recipes + field-ID caching are the fix |
```

(replace `<GREEN result>` with the actual Step 3 outcome), and mention in the intro that `git-flow` scenarios use historical production incidents as their RED evidence.

- [ ] **Step 5: Validate JSON**

Run: `jq empty tests/scenarios/git-flow/*.json && echo OK`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add tests/scenarios/git-flow/ tests/scenarios/README.md
git commit -m "Add git-flow eval scenarios with historical RED evidence"
```

---

### Task 6: Release 0.5.0

**Files:**
- Modify: `.claude-plugin/marketplace.json` (2 version fields)
- Modify: `plugins/cc-tuner/.claude-plugin/plugin.json` (version + description)
- Modify: `CHANGELOG.md` (new 0.5.0 section)
- Modify: `README.md` (skills list + install-what-you-get)
- Modify: `plugins/cc-tuner/README.md` (component list)
- Modify: `docs/superpowers/specs/2026-07-16-git-flow-design.md` (status → реализовано v0.5.0)

**Interfaces:**
- Consumes: everything above; this task only documents and versions it.

- [ ] **Step 1: Bump versions**

In `.claude-plugin/marketplace.json` change both `"version": "0.4.0"` → `"0.5.0"`. In `plugins/cc-tuner/.claude-plugin/plugin.json` change `"version": "0.4.0"` → `"0.5.0"` and extend the `description` value with `; git-flow (canonical branch/commit/PR/board conventions + /cc-tuner:git-flow-setup rule installer)` before the closing quote's final period, keeping it one sentence-ish line.

- [ ] **Step 2: CHANGELOG entry**

Insert at the top of `CHANGELOG.md` (after the header lines):

```markdown
## [0.5.0] - 2026-07-16

Git workflow moves into the plugin: one canonical rule instead of 11 hand-copied
`git-flow.md` files across marqa/stokli workspaces (two drifted variants with
contradictory tiny-PR policies).

### Added

- **`git-flow` skill** — on-demand procedures: GitHub Projects recipes
  (create-on-board, field-ID caching, card lifecycle), merge strategies incl.
  stacked PRs, plan lifecycle (`wiki/PLANS/` → `ARCHIVE`, `docs/` fallback),
  anti-pattern case studies with dated incidents.
- **`/cc-tuner:git-flow-setup`** — installs/updates the canonical
  `.claude/rules/git-flow.md` from a versioned template (plans root detected
  per repo layout), keeps repo deltas in an untouched `git-flow.local.md`,
  offers cleanup of the legacy `no-tiny-doc-prs.md`.
- **Eval scenarios** `tests/scenarios/git-flow/` — both REDs are documented
  production incidents (2026-06-05); GREEN probes recorded.

### Changed

- **`/execute-task`** — board integration: intake moves the card to In
  Progress, merge moves it to Done and verifies the issue link; step 8
  archives a completed plan inside the same PR. New optional config key
  `board` (blank = board steps skipped).

Canonical policy decisions: advisory-only (no enforcement hooks), tiny doc-PRs
are batched (3+) per direct user feedback 2026-06-05, plans live in
`wiki/PLANS/` with `docs/PLANS/` fallback. Design:
`docs/superpowers/specs/2026-07-16-git-flow-design.md`.
```

- [ ] **Step 3: Update READMEs and spec status**

Root `README.md`: add to the skills list `- **git-flow** — canonical branch/commit/PR/board/plan conventions; /cc-tuner:git-flow-setup installs the always-on rule into a repo (plugins can't ship .claude/rules).` Update `plugins/cc-tuner/README.md` component list the same way. In the spec, change the status line to `- **Статус:** реализовано (v0.5.0)`.

- [ ] **Step 4: Full verification**

Run: `claude plugin validate --strict .`
Expected: passes. Also run `grep -rn '"0.4.0"' .claude-plugin plugins/cc-tuner/.claude-plugin` — expected: no matches.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/marketplace.json plugins/cc-tuner/.claude-plugin/plugin.json CHANGELOG.md README.md plugins/cc-tuner/README.md docs/superpowers/specs/2026-07-16-git-flow-design.md
git commit -m "Release 0.5.0: git-flow skill, setup command, board integration"
```

---

## Out of scope (post-merge, separate session)

Running `/cc-tuner:git-flow-setup` across the 11 marqa/stokli workspaces (migration, spec §9) happens after this release ships — it exercises the real command against real legacy copies and is deliberately not part of this plan.
