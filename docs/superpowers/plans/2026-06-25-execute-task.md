# /cc-tuner:execute-task Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/cc-tuner:execute-task` — a slash-command playbook that the main agent walks to run a task end-to-end (brainstorm → plan → implement → review → CI/CD → merge) with start-time autonomy levels and honest hard-stops.

**Architecture:** A `disable-model-invocation` markdown command (the agent follows it step-by-step) plus five small, independently-tested bash scripts for the deterministic git/fs work (prereq-check, config-init, preflight, journal, guard-artifacts). The agent reads the per-project `.claude/execute-task.md` config itself; scripts take explicit args. Design source: `docs/superpowers/specs/2026-06-21-execute-task-design.md`.

**Tech Stack:** Bash (target macOS bash 3.2.57 + Linux), git, Claude Code plugin layout (`${CLAUDE_PLUGIN_ROOT}`). No external deps beyond git. Tests are self-contained bash assertion scripts run with `bash <test>`.

---

## Conventions for every script

- Shebang `#!/usr/bin/env bash`, `set -u` (NOT `set -e` — we handle exits explicitly so a paid step is never lost).
- **Anchor to repo root and FAIL LOUD** (a bad `CLAUDE_PROJECT_DIR` must never let a git-mutating script run in the wrong tree). Every script that touches git/fs starts with:
  ```bash
  ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
  git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }
  ```
- **run-id is sanitized** wherever it forms a path (`preflight.sh`, `journal.sh`): `RUN_ID="$(printf '%s' "$RAW" | tr -c 'A-Za-z0-9_.-' '-')"` then reject empty. Stripping `/` keeps every artifact inside the ignored runs dir (no `../` escape).
- **All local-only operational artifacts live UNDER `.claude/execute-task-runs/<run-id>/`** — the journal is `.claude/execute-task-runs/<run-id>.md`, and screenshots / raw test+CI logs go in `.claude/execute-task-runs/<run-id>/`. One ignore rule (`.claude/execute-task-runs/`) and one guard pattern therefore cover ALL of them.
- Forward-slash paths only. No `git add -A`. `date -u +%FT%TZ` is allowed (plain shell).
- Exit codes: `0` ok, `1` usage/missing/bad-root, `2` dirty tree, `3` refused (staged artifacts).

Tests create a throwaway git repo under `mktemp -d`, run the script with `CLAUDE_PROJECT_DIR` pointed at it, assert, and clean up. Each test prints `PASS`/`FAIL` lines and exits non-zero on any failure.

---

### Task 1: `prereq-check.sh` — verify required plugins are installed

**Files:**
- Create: `plugins/cc-tuner/scripts/execute-task/prereq-check.sh`
- Test: `plugins/cc-tuner/tests/execute-task/test_prereq.sh`

- [ ] **Step 1: Write the failing test**

```bash
# plugins/cc-tuner/tests/execute-task/test_prereq.sh
#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/prereq-check.sh"
fails=0
mkroot() { ROOT="$(mktemp -d)"; }  # fake plugin cache root

# both present -> exit 0
mkroot
mkdir -p "$ROOT/cache/superpowers-marketplace/superpowers/5.1.0/skills/brainstorming"
touch    "$ROOT/cache/superpowers-marketplace/superpowers/5.1.0/skills/brainstorming/SKILL.md"
mkdir -p "$ROOT/cache/cc-codex-triage/cc-codex-triage/0.6.0/commands"
touch    "$ROOT/cache/cc-codex-triage/cc-codex-triage/0.6.0/commands/review.md"
CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" >/dev/null 2>&1 \
  && echo "PASS both-present" || { echo "FAIL both-present"; fails=1; }
rm -rf "$ROOT"

# superpowers missing -> exit exactly 1
mkroot
mkdir -p "$ROOT/cache/cc-codex-triage/cc-codex-triage/0.6.0/commands"
touch    "$ROOT/cache/cc-codex-triage/cc-codex-triage/0.6.0/commands/review.md"
CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS sp-missing" || { echo "FAIL sp-missing (rc=$rc, want 1)"; fails=1; }
rm -rf "$ROOT"

# cc-codex-triage missing -> exit exactly 1
mkroot
mkdir -p "$ROOT/cache/superpowers-marketplace/superpowers/5.1.0/skills/brainstorming"
touch    "$ROOT/cache/superpowers-marketplace/superpowers/5.1.0/skills/brainstorming/SKILL.md"
CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS cct-missing" || { echo "FAIL cct-missing (rc=$rc, want 1)"; fails=1; }
rm -rf "$ROOT"

exit $fails
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugins/cc-tuner/tests/execute-task/test_prereq.sh`
Expected: FAIL — script does not exist yet (`bash: .../prereq-check.sh: No such file`).

- [ ] **Step 3: Write the script**

```bash
#!/usr/bin/env bash
# cc-tuner execute-task: verify the required plugins are installed.
# One anchor file per plugin is enough — a plugin's skills/commands ship as a unit.
# Exit 0 if both present; else 1 with install hints. Override cache root via
# CLAUDE_PLUGIN_CACHE (used by tests).
set -u
CACHE="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins}"
missing=0

have() { compgen -G "$1" >/dev/null 2>&1; }  # quoted glob check — safe with spaces in the path

if ! have "$CACHE/cache/*/superpowers/*/skills/brainstorming/SKILL.md"; then
  echo "MISSING: superpowers (skills: brainstorming, writing-plans, subagent-driven-development, requesting-code-review)" >&2
  echo "  install: /plugin install superpowers@superpowers-marketplace" >&2
  missing=1
fi
if ! have "$CACHE/cache/*/cc-codex-triage/*/commands/review.md"; then
  echo "MISSING: cc-codex-triage (commands: /plan, /review)" >&2
  echo "  install: /plugin marketplace add clicktronix/cc-codex-triage && /plugin install cc-codex-triage@cc-codex-triage" >&2
  missing=1
fi

if [ "$missing" -eq 0 ]; then echo "prereqs OK"; else exit 1; fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x plugins/cc-tuner/scripts/execute-task/prereq-check.sh && bash plugins/cc-tuner/tests/execute-task/test_prereq.sh`
Expected: three `PASS` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/cc-tuner/scripts/execute-task/prereq-check.sh plugins/cc-tuner/tests/execute-task/test_prereq.sh
git commit -m "feat(execute-task): prereq-check.sh + test"
```

---

### Task 2: `config.template.md` + `config-init.sh` — scaffold per-project config

**Files:**
- Create: `plugins/cc-tuner/assets/execute-task/config.template.md`
- Create: `plugins/cc-tuner/scripts/execute-task/config-init.sh`
- Test: `plugins/cc-tuner/tests/execute-task/test_config.sh`

- [ ] **Step 1: Write the template** (the agent reads this; no parser needed)

```markdown
# execute-task config

Per-project settings for `/cc-tuner:execute-task`. The agent reads this file
directly. Fill in the commands for THIS repo; leave a field blank if N/A.

- **test**: how to run the full test/smoke suite (incl. UI, e.g. `manual: open http://localhost:3000`)
- **cheap_gate**: fast gate for step 3.5 — types/lint/unit only (e.g. `npm run typecheck && npm run lint`)
- **ci**: CI/checks command; whether manual and how to trigger (e.g. `gh workflow run ci.yml`)
- **cd**: deploy/publish/migrate command (outward-facing, step 9b). Blank = none.
- **branch**: branch policy — create a feature branch? name pattern? require a clean tree? (default: create `task/<id>`, require clean)
- **merge**: squash|merge, target branch, and `auto` (zero-touch) or confirm (default: squash into the default branch, confirm)
- **tracker**: how to fetch the issue — `gh` | `glab` | `none`
- **dor_dod**: DoR/DoD template + acceptance criteria. Mark each criterion `[machine]` (chrome-devtools-checkable) or `[eyes]` (human hard-stop).
- **allow_unverified_manual**: `true` to finish with an unmet `[eyes]` criterion (default `false`; `merge: auto` does NOT override this)
- **review_passes**: which review layers run. Default: code-review + Codex always; requesting-code-review when the diff touches auth / migrations / public API, or > 20 files.
- **autonomy**: default mode — `brainstorm-only` | `checkpoints` | `supervised`
```

- [ ] **Step 2: Write the failing test**

```bash
# plugins/cc-tuner/tests/execute-task/test_config.sh
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
S="$HERE/config-init.sh"
TPL="$(cd "$(dirname "$0")/../../assets/execute-task" && pwd)/config.template.md"
fails=0

T="$(mktemp -d)"; ( cd "$T" && git init -q )
# missing -> created from template, exit 0
CLAUDE_PROJECT_DIR="$T" bash "$S" "$TPL" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$T/.claude/execute-task.md" ] && grep -q "execute-task config" "$T/.claude/execute-task.md"; then
  echo "PASS scaffold-created"; else echo "FAIL scaffold-created (rc=$rc)"; fails=1; fi
# present -> left untouched (sentinel preserved)
echo "SENTINEL" > "$T/.claude/execute-task.md"
CLAUDE_PROJECT_DIR="$T" bash "$S" "$TPL" >/dev/null 2>&1
grep -qx "SENTINEL" "$T/.claude/execute-task.md" \
  && echo "PASS scaffold-idempotent" || { echo "FAIL scaffold-idempotent"; fails=1; }
rm -rf "$T"
exit $fails
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash plugins/cc-tuner/tests/execute-task/test_config.sh`
Expected: FAIL — `config-init.sh` not found.

- [ ] **Step 4: Write the script**

```bash
#!/usr/bin/env bash
# Ensure .claude/execute-task.md exists; scaffold from the template if missing.
# usage: config-init.sh <template-path>
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }
TEMPLATE="${1:?usage: config-init.sh <template-path>}"
CFG=".claude/execute-task.md"
if [ -f "$CFG" ]; then
  echo "config exists: $CFG"
  exit 0
fi
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }
mkdir -p .claude
cp "$TEMPLATE" "$CFG"
echo "config created: $CFG — edit it for this repo, then re-run /cc-tuner:execute-task"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash plugins/cc-tuner/tests/execute-task/test_config.sh`
Expected: `PASS scaffold-created`, `PASS scaffold-idempotent`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add plugins/cc-tuner/assets/execute-task/config.template.md plugins/cc-tuner/scripts/execute-task/config-init.sh plugins/cc-tuner/tests/execute-task/test_config.sh
git commit -m "feat(execute-task): config template + config-init.sh + test"
```

---

### Task 3: `preflight.sh` — clean tree, ignore coverage, base SHA, run-journal

**Files:**
- Create: `plugins/cc-tuner/scripts/execute-task/preflight.sh`
- Test: `plugins/cc-tuner/tests/execute-task/test_preflight.sh`

- [ ] **Step 1: Write the failing test**

```bash
# plugins/cc-tuner/tests/execute-task/test_preflight.sh
#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/preflight.sh"
fails=0

mkrepo() {
  T="$(mktemp -d)"; ( cd "$T" && git init -q && git config user.email a@b.c \
    && git config user.name t && echo x > f && git add f && git commit -qm init )
}

# clean tree -> journal created with base SHA, runs dir gitignored
mkrepo
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$S" run1 main 2>/dev/null)"
SHA="$(cd "$T" && git rev-parse HEAD)"
if [ -f "$T/.claude/execute-task-runs/run1.md" ] \
   && grep -qF "$SHA" "$T/.claude/execute-task-runs/run1.md" \
   && ( cd "$T" && git check-ignore -q .claude/execute-task-runs/run1.md ); then
  echo "PASS clean-preflight"; else echo "FAIL clean-preflight"; fails=1; fi
[ "$OUT" = ".claude/execute-task-runs/run1.md" ] \
  && echo "PASS prints-journal-path" || { echo "FAIL prints-journal-path ($OUT)"; fails=1; }
rm -rf "$T"

# dirty tree -> exit exactly 2
mkrepo
echo change >> "$T/f"
CLAUDE_PROJECT_DIR="$T" bash "$S" run2 main >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && echo "PASS dirty-blocks" || { echo "FAIL dirty-blocks (rc=$rc, want 2)"; fails=1; }
rm -rf "$T"

# unsafe run-id ('/', '..') -> sanitized, journal stays INSIDE the runs dir
mkrepo
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$S" "DEV-1/../escape" main 2>/dev/null)"
case "$OUT" in .claude/execute-task-runs/*) echo "PASS runid-sanitized" ;; *) echo "FAIL runid-sanitized ($OUT)"; fails=1 ;; esac
{ [ -n "$OUT" ] && [ -f "$T/$OUT" ]; } && echo "PASS runid-file-in-dir" || { echo "FAIL runid-file-in-dir"; fails=1; }
rm -rf "$T"

# linked worktree (.git is a FILE, not a dir) -> ignore-coverage still works
mkrepo
WT="$(mktemp -d)/wt"
( cd "$T" && git worktree add -q "$WT" -b wtbranch >/dev/null 2>&1 )
CLAUDE_PROJECT_DIR="$WT" bash "$S" runwt main >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && ( cd "$WT" && git check-ignore -q .claude/execute-task-runs/runwt.md ); } \
  && echo "PASS worktree-ignore" || { echo "FAIL worktree-ignore (rc=$rc)"; fails=1; }
( cd "$T" && git worktree remove --force "$WT" >/dev/null 2>&1 ); rm -rf "$WT" "$T"

# bad CLAUDE_PROJECT_DIR (not a git repo) -> exit 1, never a silent wrong-dir run
NOGIT="$(mktemp -d)"
CLAUDE_PROJECT_DIR="$NOGIT" bash "$S" run3 main >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS bad-root" || { echo "FAIL bad-root (rc=$rc, want 1)"; fails=1; }
rm -rf "$NOGIT"

exit $fails
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugins/cc-tuner/tests/execute-task/test_preflight.sh`
Expected: FAIL — `preflight.sh` not found.

- [ ] **Step 3: Write the script**

```bash
#!/usr/bin/env bash
# Preflight before autonomous edits. Branch CREATION is the agent's job (per the
# repo's branch policy); this script does the deterministic, low-freedom parts:
#   1) ensure local-only run artifacts are git-ignored,
#   2) assert a clean working tree (excluding the runs dir),
#   3) open a run-journal recording base SHA / branch / target.
# usage: preflight.sh <run-id> [<target-branch>]
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }

RAW="${1:?usage: preflight.sh <run-id> [target-branch]}"
RUN_ID="$(printf '%s' "$RAW" | tr -c 'A-Za-z0-9_.-' '-')"   # strip '/' etc → can't escape RUNS_DIR
[ -n "$RUN_ID" ] || { echo "invalid run-id: '$RAW'" >&2; exit 1; }
TARGET="${2:-}"
RUNS_DIR=".claude/execute-task-runs"

# 1) ignore coverage via the repo's REAL exclude file. git rev-parse --git-path
#    resolves it correctly even in a linked worktree (where .git is a file).
if ! git check-ignore -q "$RUNS_DIR/x" 2>/dev/null; then
  EX="$(git rev-parse --git-path info/exclude 2>/dev/null)"
  if [ -n "$EX" ]; then
    mkdir -p "$(dirname "$EX")"
    grep -qxF "$RUNS_DIR/" "$EX" 2>/dev/null || echo "$RUNS_DIR/" >> "$EX"
  fi
fi

# 2) clean tree (the runs dir itself is excluded from the check)
DIRTY="$(git status --porcelain -uall 2>/dev/null | grep -vF "$RUNS_DIR/" || true)"
if [ -n "$DIRTY" ]; then
  echo "DIRTY working tree — commit/stash first (or allow via branch policy):" >&2
  printf '%s\n' "$DIRTY" >&2
  exit 2
fi

# 3) open the run-journal with base state
mkdir -p "$RUNS_DIR"
JOURNAL="$RUNS_DIR/$RUN_ID.md"
BASE_SHA="$(git rev-parse HEAD 2>/dev/null || echo '(unborn)')"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(detached)')"
{
  echo "# execute-task run: $RUN_ID"
  echo
  echo "- started: $(date -u +%FT%TZ)"
  echo "- branch: $BRANCH"
  echo "- target: ${TARGET:-?}"
  echo "- base SHA: $BASE_SHA"
  echo
  echo "## log"
} > "$JOURNAL"
echo "$JOURNAL"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash plugins/cc-tuner/tests/execute-task/test_preflight.sh`
Expected: `PASS clean-preflight`, `PASS prints-journal-path`, `PASS dirty-blocks`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/cc-tuner/scripts/execute-task/preflight.sh plugins/cc-tuner/tests/execute-task/test_preflight.sh
git commit -m "feat(execute-task): preflight.sh (clean tree + ignore + base SHA + journal) + test"
```

---

### Task 4: `journal.sh` — append/read the run-journal

**Files:**
- Create: `plugins/cc-tuner/scripts/execute-task/journal.sh`
- Test: `plugins/cc-tuner/tests/execute-task/test_journal.sh`

- [ ] **Step 1: Write the failing test**

```bash
# plugins/cc-tuner/tests/execute-task/test_journal.sh
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
J="$DIR/journal.sh"; P="$DIR/preflight.sh"
fails=0

T="$(mktemp -d)"; ( cd "$T" && git init -q && git config user.email a@b.c \
  && git config user.name t && echo x > f && git add f && git commit -qm init )
CLAUDE_PROJECT_DIR="$T" bash "$P" run1 main >/dev/null 2>&1

# path
[ "$(CLAUDE_PROJECT_DIR="$T" bash "$J" path run1)" = ".claude/execute-task-runs/run1.md" ] \
  && echo "PASS path" || { echo "FAIL path"; fails=1; }
# append adds a line
CLAUDE_PROJECT_DIR="$T" bash "$J" append run1 "step 2 APPROVE r3" >/dev/null 2>&1
grep -q "step 2 APPROVE r3" "$T/.claude/execute-task-runs/run1.md" \
  && echo "PASS append" || { echo "FAIL append"; fails=1; }
# append to missing journal -> exit exactly 1
CLAUDE_PROJECT_DIR="$T" bash "$J" append nope "x" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS append-missing" || { echo "FAIL append-missing (rc=$rc, want 1)"; fails=1; }
rm -rf "$T"
exit $fails
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugins/cc-tuner/tests/execute-task/test_journal.sh`
Expected: FAIL — `journal.sh` not found.

- [ ] **Step 3: Write the script**

```bash
#!/usr/bin/env bash
# Append a timestamped entry to a run-journal, or print its path.
# usage: journal.sh append <run-id> <text...>   |   journal.sh path <run-id>
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }
RUNS_DIR=".claude/execute-task-runs"
SUB="${1:?usage: journal.sh append|path <run-id> [text]}"
RAW="${2:?run-id required}"
RUN_ID="$(printf '%s' "$RAW" | tr -c 'A-Za-z0-9_.-' '-')"   # SAME sanitize as preflight → same file
[ -n "$RUN_ID" ] || { echo "invalid run-id: '$RAW'" >&2; exit 1; }
JOURNAL="$RUNS_DIR/$RUN_ID.md"
case "$SUB" in
  path) echo "$JOURNAL" ;;
  append)
    shift 2
    [ -f "$JOURNAL" ] || { echo "journal not found: $JOURNAL (run preflight first)" >&2; exit 1; }
    printf -- '- [%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$JOURNAL"
    ;;
  *) echo "unknown subcommand: $SUB (use append|path)" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash plugins/cc-tuner/tests/execute-task/test_journal.sh`
Expected: `PASS path`, `PASS append`, `PASS append-missing`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/cc-tuner/scripts/execute-task/journal.sh plugins/cc-tuner/tests/execute-task/test_journal.sh
git commit -m "feat(execute-task): journal.sh (append/path) + test"
```

---

### Task 5: `guard-artifacts.sh` — pre-outward-facing artifact guard

**Files:**
- Create: `plugins/cc-tuner/scripts/execute-task/guard-artifacts.sh`
- Test: `plugins/cc-tuner/tests/execute-task/test_guard.sh`

- [ ] **Step 1: Write the failing test**

```bash
# plugins/cc-tuner/tests/execute-task/test_guard.sh
#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/guard-artifacts.sh"
fails=0

mkrepo() {
  T="$(mktemp -d)"; ( cd "$T" && git init -q && git config user.email a@b.c \
    && git config user.name t && echo x > f && git add f && git commit -qm init \
    && mkdir -p .claude/execute-task-runs && echo j > .claude/execute-task-runs/run1.md )
}

# operational artifact staged -> exit exactly 3
mkrepo
( cd "$T" && git add -f .claude/execute-task-runs/run1.md )
CLAUDE_PROJECT_DIR="$T" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && echo "PASS staged-artifact" || { echo "FAIL staged-artifact (rc=$rc, want 3)"; fails=1; }
rm -rf "$T"

# clean staging (only a real source change) -> exit 0 and status shown
mkrepo
( cd "$T" && echo y >> f && git add f )
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$S" 2>/dev/null)"; rc=$?
{ [ $rc -eq 0 ] && printf '%s' "$OUT" | grep -q " f"; } \
  && echo "PASS clean-staging" || { echo "FAIL clean-staging (rc=$rc)"; fails=1; }
rm -rf "$T"
exit $fails
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugins/cc-tuner/tests/execute-task/test_guard.sh`
Expected: FAIL — `guard-artifacts.sh` not found.

- [ ] **Step 3: Write the script**

```bash
#!/usr/bin/env bash
# Pre-outward-facing guard (before CD / merge). Refuse if local-only operational
# artifacts are staged, then print the full change set INCLUDING untracked so
# nothing slips past the review. No git add -A anywhere upstream.
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }

# One pattern covers ALL local-only operational artifacts: journal, screenshots,
# and raw logs all live under .claude/execute-task-runs/<run-id>/ (see Conventions).
LOCAL_ONLY=".claude/execute-task-runs/"

STAGED="$(git diff --cached --name-only 2>/dev/null || true)"
BAD="$(printf '%s\n' "$STAGED" | grep -F "$LOCAL_ONLY" || true)"
if [ -n "$BAD" ]; then
  echo "REFUSE: operational artifacts are staged — unstage them (no git add -A):" >&2
  printf '%s\n' "$BAD" >&2
  exit 3
fi

echo "== change set to review before the outward-facing op (staged + unstaged + untracked) =="
git status --porcelain -uall
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash plugins/cc-tuner/tests/execute-task/test_guard.sh`
Expected: `PASS staged-artifact`, `PASS clean-staging`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/cc-tuner/scripts/execute-task/guard-artifacts.sh plugins/cc-tuner/tests/execute-task/test_guard.sh
git commit -m "feat(execute-task): guard-artifacts.sh + test"
```

---

### Task 6: `execute-task.md` — the command playbook

**Files:**
- Create: `plugins/cc-tuner/commands/execute-task.md`

Not unit-tested (it is agent-facing instructions, not code). Verified by a structural checklist + a live wiring smoke of the scripts it calls.

- [ ] **Step 1: Write the command file**

````markdown
---
description: Drives a coding task from intake through merge as a guided, gated playbook with a chosen autonomy level. Use when the user wants a whole task or issue taken start-to-finish for them, says "execute this task", "run this ticket end to end", or asks to automate the task lifecycle. Requires the superpowers and cc-codex-triage plugins.
argument-hint: '<issue-ref> [--autonomy brainstorm-only|checkpoints|supervised]'
disable-model-invocation: true
---

# /cc-tuner:execute-task

<!-- No `allowed-tools` restriction on purpose: the playbook needs broad access
     (Bash, Read/Edit/Write, Task, TodoWrite, AskUserQuestion, the Skill tool,
     and chrome-devtools MCP for [machine] acceptance checks). Restricting it
     would silently break gates/autonomy prompts. -->

Walk a task from intake to merge, stopping for the human only at the gates the
chosen autonomy level keeps. You (the main agent) drive every step; you only
fan out to a Workflow on genuine fan-out phases. Validate every review/plan
objection against the code before acting on it — an objection can be wrong.

Design of record: `docs/superpowers/specs/2026-06-21-execute-task-design.md`.

## Step 0 — prereqs + config + autonomy

1. Prereqs:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/prereq-check.sh"
   ```
   Non-zero exit → show its message and STOP (the playbook needs superpowers + cc-codex-triage).
2. Config:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/config-init.sh" "${CLAUDE_PLUGIN_ROOT}/assets/execute-task/config.template.md"
   ```
   If it reports "config created", STOP and ask the user to fill `.claude/execute-task.md`, then re-run. Otherwise **Read** `.claude/execute-task.md` — those values drive every step below.
3. Autonomy: take `--autonomy` if passed, else the config's `autonomy:`, else ask once (AskUserQuestion): `brainstorm-only` / `checkpoints` / `supervised`. Which `🚦` gates stay in the human loop:
   - `supervised` — every `🚦`.
   - `checkpoints` — step 1 (brainstorm / DoR-DoD), step 4 (UI acceptance), step 10 (merge).
   - `brainstorm-only` — step 1 only.
   In every mode the **Hard-stops** below still apply — autonomy can't waive those.

## Step 0.7 — preflight

1. Pick a `run-id` (e.g. `<issue>-<short-sha>`). Create the feature branch per the config's `branch` policy (you do this — `git checkout -b <name>`).
2. ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/preflight.sh" <run-id> <target-branch>
   ```
   Exit 2 (dirty tree) → STOP, surface the files, let the user commit/stash. On success it prints the journal path; append to it after each step:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" append <run-id> "<what happened>"
   ```

## Steps 1–10 (the spine)

Record each step's outcome to the journal. `🚦` = a human gate in `supervised`; see Hard-stops for `brainstorm-only`/`checkpoints`.

1. **Intake + DoR/DoD.** Fetch the issue per `tracker`. If anything is unclear, invoke `superpowers:brainstorming`. Write DoR/DoD with acceptance criteria, each tagged `[machine]` or `[eyes]`. `🚦` always (this is the point of `brainstorm-only`).
2. **Plan.** `superpowers:writing-plans`, then stress-test via cc-codex-triage `/plan` to APPROVE. Validate each objection; refute wrong ones with file:line. `🚦` in supervised; autonomous otherwise.
3. **Implement.** `superpowers:subagent-driven-development`. If units are independent, fan out with a Workflow (worktree isolation for parallel file edits).
4. **3.5 — cheap gate.** Run the config's `cheap_gate` (types/lint/unit). Red → fix before going further (hard-stop in every mode).
5. **4 — smoke / acceptance.** Run `test` per the acceptance criteria. `[machine]` criteria you verify with chrome-devtools / `verify`; `[eyes]` criteria are a hard-stop (see below). **`🚦` in supervised AND checkpoints** (UI acceptance is a checkpoints stop).
6. **5 — code-review.** Run `/code-review` (xhigh), validate findings, fix the neighborhood.
7. **6 — peer review (conditional).** Run `superpowers:requesting-code-review` only when the config's `review_passes` risk rules fire (diff touches auth / migrations / public API, or > 20 files — use the threshold set in `review_passes`). Else skip and journal why.
8. **7 — Codex review.** cc-codex-triage `/review` to APPROVE; validate objections. `🚦` in supervised.
9. **7.5 — re-verify.** If the fixes in 5–7 touched FE/behaviour, re-run the relevant smoke from step 4.
10. **8 — reconcile.** Tick off plan + DoD items; journal what shipped vs deferred.
11. **9a — CI.** Run `ci` (trigger if manual). Red → hard-stop.
12. **9b — CD (if `cd` set).** Before running `cd`, do the **full outward-facing preflight** (same bar as merge): run the guard, show the exact commit/diff, **classify the side effect** (deploy / publish / data migration), state the **rollback path**, and journal all of it.
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/guard-artifacts.sh"
    ```
    Exit 3 → unstage the operational artifacts. CD is an outward-facing **hard-stop** in every mode — autonomy never runs it unattended.
13. **10 — merge.** Run the guard again, show the exact commit/diff + rollback path, then merge per `merge`. Default: stop for confirmation even in `brainstorm-only`; only `merge: auto` waives that.

## Hard-stops (what autonomy can NEVER waive)

Whatever the mode, STOP and involve the human for: a failed prereq (0); a dirty tree at preflight (0.7); a red cheap-gate (3.5) or CI (9a); an unmet `[eyes]` acceptance criterion (4/7.5) — `merge: auto` does NOT override it, only an explicit `allow_unverified_manual: true` does; any outward-facing side effect — CD (9b) and merge (10); and any fork you cannot resolve from the code yourself (ask — autonomy ≠ guess). `merge: auto` is the single exception, and it only waives the routine merge confirm.

## Artifact hygiene

All local-only operational artifacts live under `.claude/execute-task-runs/<run-id>/` — the journal **and** any screenshots / raw test+CI logs (write them there, e.g. `.claude/execute-task-runs/<run-id>/smoke.png`). Preflight git-ignores that single directory, so every class is covered at once. Never `git add -A`; the guard refuses to proceed if any are staged and shows untracked files in the final diff. The project config and any plan/spec files ARE committable. The config's optional `artifacts` field may redirect/extend this — honor it if set.
````

- [ ] **Step 2: Structural self-check** (no code change — verify against the spec)

Confirm, by reading the file: every spec step 0–10 (incl. 0.7, 3.5, 7.5, 9a/9b) is present; the Hard-stops list matches spec §5; script paths use `${CLAUDE_PLUGIN_ROOT}`; the `description` is third-person, states what+when, names the deps, and does NOT summarize the step list; no time-sensitive notes are in the body.

- [ ] **Step 3: Live wiring smoke** (the deterministic scripts actually run)

Run, from a scratch git repo, the exact invocations the command lists:
```bash
T="$(mktemp -d)"; cd "$T" && git init -q && git config user.email a@b.c && git config user.name t && echo x>f && git add f && git commit -qm init
bash "$OLDPWD/plugins/cc-tuner/scripts/execute-task/config-init.sh" "$OLDPWD/plugins/cc-tuner/assets/execute-task/config.template.md"
git add .claude/execute-task.md && git commit -qm "add execute-task config"   # config is committable — clean the tree before preflight
bash "$OLDPWD/plugins/cc-tuner/scripts/execute-task/preflight.sh" smoke main
bash "$OLDPWD/plugins/cc-tuner/scripts/execute-task/journal.sh" append smoke "wiring ok"
bash "$OLDPWD/plugins/cc-tuner/scripts/execute-task/guard-artifacts.sh"; cd "$OLDPWD"; rm -rf "$T"
```
Expected: config created, then committed; preflight prints the journal path (clean tree); append succeeds; guard prints the change set with exit 0.

- [ ] **Step 4: Commit**

```bash
git add plugins/cc-tuner/commands/execute-task.md
git commit -m "feat(execute-task): the command playbook"
```

---

### Task 7: Package — version bump, marketplace, CHANGELOG, README

**Files:**
- Modify: `plugins/cc-tuner/.claude-plugin/plugin.json` (version `0.2.1` → `0.3.0`, add keywords)
- Modify: `.claude-plugin/marketplace.json` (version `0.3.0`)
- Modify: `CHANGELOG.md` (create if absent)
- Modify: `plugins/cc-tuner/README.md` (add an `/execute-task` section if the README exists)

- [ ] **Step 1: Bump plugin.json**

In `plugins/cc-tuner/.claude-plugin/plugin.json`: set `"version": "0.3.0"`, extend `description` to mention the task playbook, and add keywords `"execute-task"`, `"workflow"`, `"playbook"`.

- [ ] **Step 2: Bump marketplace.json**

In `.claude-plugin/marketplace.json`: set the cc-tuner entry version to `0.3.0` (match both the metadata and any nested version field).

- [ ] **Step 3: CHANGELOG entry**

Add a `## [0.3.0]` section: "Added `/execute-task` — a task-lifecycle playbook command (brainstorm → plan → implement → review → CI/CD → merge) with start-time autonomy levels and hard-stops. Requires superpowers + cc-codex-triage (prereq-checked at runtime; cc-tuner still installs standalone)."

- [ ] **Step 4: README section** (only if `plugins/cc-tuner/README.md` exists)

Add a short `## /execute-task` section: one-paragraph what/when, the dependency note, and the `.claude/execute-task.md` config pointer.

- [ ] **Step 5: Run the full test suite once more**

```bash
rc=0
for t in plugins/cc-tuner/tests/execute-task/test_*.sh; do
  echo "== $t =="; bash "$t" || { echo "FAILED: $t"; rc=1; }
done
[ "$rc" -eq 0 ] && echo "ALL TESTS PASS" || { echo "SOME TESTS FAILED"; exit 1; }
```
Expected: all `PASS`, final line `ALL TESTS PASS`, exit 0. (The loop tracks failures and exits non-zero — it does not mask them.)

- [ ] **Step 6: Commit**

```bash
git add plugins/cc-tuner/.claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md plugins/cc-tuner/README.md
git commit -m "chore(cc-tuner): release 0.3.0 — /execute-task"
```

---

## Final manual verification (not automated)

Per the spec's eval-first note, the command's real value is exercised by driving a real task. After merge, on a throwaway branch in a small repo: run `/cc-tuner:execute-task <toy-issue> --autonomy supervised` and confirm it stops at each `🚦`, the journal accumulates entries, and the merge gate shows the diff. This is the RED→GREEN baseline for the playbook itself; capture observations to refine the command body.
