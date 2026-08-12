# PR 1 — Matt Method Integration — Implementation Plan

> **For agentic workers:** implement task-by-task, in order. Each task ends with its own test run and
> commit. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every readiness and implementation step in `/cc-tuner:spec` and `/cc-tuner:run` names the
method that produces it, each method runs where it cannot damage the wrong tree, and a command only
requires the capabilities it actually uses.

**Architecture:** `prereq-check.sh` gains a single capability registry and a `--profile` /
`--capability` selector, so `/spec` no longer fails because a `/run` skill moved and a conditional
method is verified immediately before it is used rather than at preflight. `spec.md` and `run.md`
name skill ids and state the workspace each method may write to. Nothing reads another plugin's
`SKILL.md` at runtime and nothing copies its text.

**Tech Stack:** bash 3.2 (the `/bin/bash` macOS ships), `jq`, markdown command files, the repo's own
`tests/run.sh` harness.

## Global Constraints

- bash 3.2 compatible. No `mapfile`/`readarray`, no associative arrays, no `${var^^}`.
- Every guard ships with a test that FAILS when the guard is reverted, proven by reverting.
- **Mutation proofs never use `git checkout --`.** The implementation is uncommitted at that point and
  `checkout` would restore HEAD and silently delete it. Use:
  ```bash
  cp <file> <file>.premutation
  # mutate, run the suite, expect the named FAIL
  mv <file>.premutation <file>
  ```
- **Anchor edits on quoted strings, not line numbers.** Several tasks edit the same file, so any line
  number written here is stale after the previous task. Locate with `grep -n '<anchor>' <file>`.
- No second copy of a rule and no second parser for one question.
- Short imperative commit subjects. No `Co-Authored-By` and no Claude attribution.
- Set the local identity before the first commit:
  `git config user.name "Vladislav Manakov" && git config user.email "s28.morgan@gmail.com"`.
- `bash tests/run.sh` prints `cc-tuner validate ok` at the end of every task.
- Work on a task branch off `main`. Never commit to `main`.

## Decisions this plan encodes

Settled across two review rounds with Codex; recorded so they are not relitigated mid-implementation.

- **No `skill-path.sh`, no runtime read of another plugin's `SKILL.md`, no copy of its text.** cc-tuner
  invokes model-invocable skills by id and owns its own rules. `to-spec` and `to-tickets` carry
  `disable-model-invocation: true`; their *architectural ideas* are implemented in cc-tuner's own
  planning contract (PR 2), with Matt credited in the ADR and CHANGELOG.
- **`to-spec`'s document template is not adopted.** It forbids file paths and exact commands; `spec.md`
  requires them (`## Implementation tasks` → `<owned file paths>`, `## Test plan` → `<exact
  commands>`). Adopting it would break the fields `runctl` binds to.
- **No `Blocked by` field until the runtime graph exists.** A dependency field that nothing enforces is
  decoration. It lands in PR 2 together with validation and `frontier`.
- **Methods are placed by what they write, not by topic:**
  | method | where it may run |
  |---|---|
  | `grilling` | `/spec`, read-only dialogue |
  | `domain-modeling` | `/spec`; ADR/glossary written to disk **only after** the task branch exists |
  | `diagnosing-bugs` | `/spec` readiness, **read-only reproduction**; escalate to a disposable workspace if diagnosis needs edits |
  | `research` | `/spec`, conditional, external facts only |
  | `prototype` | disposable workspace only, never the integration or task branch |
  | `tdd` | `/run` implementation, on the task branch/worktree |
  | `code-review` | `/run` Phase 6, on the immutable candidate |
- **`codebase-design` and the `plan` profile are NOT in this PR.** They arrive with `/cc-tuner:plan` in
  PR 2, so this PR ships no profile without a caller.

## File Structure

| File | Responsibility after this PR |
|---|---|
| `plugins/cc-tuner/scripts/execute-task/prereq-check.sh` | one capability registry; `--profile spec\|run`, `--capability <name>`, default = every recommended capability |
| `plugins/cc-tuner/commands/spec.md` | calls the `spec` profile; names a method per readiness bullet; states each method's permitted workspace |
| `plugins/cc-tuner/commands/run.md` | calls the `run` profile; names `tdd` inside implementation |
| `plugins/cc-tuner/workflow-contract.json` | adds the `capability-specific-prerequisites` invariant |
| `plugins/cc-tuner/README.md` | states which capabilities each command requires |
| `plugins/cc-tuner/tests/execute-task/test_prereq.sh` | per-profile cases; conditional absence must not break an unrelated command |
| `plugins/cc-tuner/tests/execute-task/test_contract.sh` | doc-contract assertions for the routing and workspace rules |
| `plugins/cc-tuner/tests/setup/test_doctor.sh` | fixture carries the full recommended set (doctor checks everything) |

---

### Task 1: Scope prerequisites to the capability a command uses

**Files:**
- Modify: `plugins/cc-tuner/scripts/execute-task/prereq-check.sh`
- Modify: `plugins/cc-tuner/commands/spec.md` — the `prereq-check.sh` call in `## 1. Anchor and read`
- Modify: `plugins/cc-tuner/commands/run.md` — the `prereq-check.sh` call in Phase 0
- Modify: `plugins/cc-tuner/README.md` — the "Requires the **mattpocock-skills** …" paragraph
- Modify: `plugins/cc-tuner/workflow-contract.json`
- Modify: `plugins/cc-tuner/tests/execute-task/test_prereq.sh`
- Modify: `plugins/cc-tuner/tests/setup/test_doctor.sh`

**Interfaces:**
- Consumes: `execute_task_manifest_roots` (`lib.sh`) and `execute_task_codex_root_qualifies`,
  unchanged — the selection rule stays in one place.
- Produces: `prereq-check.sh [--profile spec|run] [--capability <name>]`. Exit 0 = satisfied, 1 =
  something required is missing (named on stderr), 2 = usage error. Default (no flags) = every
  recommended capability, which is what `doctor.sh` calls. Tasks 2 and 3 consume the profiles.

- [ ] **Step 1: Write the failing tests**

Append to `plugins/cc-tuner/tests/execute-task/test_prereq.sh`, before its final exit. It already
defines `mkroot`, `MP`, `add_grilling`, `add_domain`, `add_codereview`, `add_codex`; add the rest:

```bash
add_cap() { mkdir -p "$ROOT/$MP/engineering/$1"; touch "$ROOT/$MP/engineering/$1/SKILL.md"; }
add_all_caps() { for c in tdd diagnosing-bugs research prototype; do add_cap "$c"; done; }

# A command must not fail because a capability it never uses is missing. This is the whole point of
# profiles: `/spec` failing over a Phase 6 review skill sends the user to fix an unrelated thing.
mkroot; add_grilling; add_domain; add_all_caps            # no code-review, no codex
HOME="$FAKE_HOME" bash "$S" --profile spec >/dev/null 2>&1 \
  && echo "PASS profile-spec-ignores-run-capabilities" \
  || { echo "FAIL profile-spec-ignores-run-capabilities"; fails=1; }
rm -rf "$ROOT"

# but a capability the profile DOES use is named exactly
mkroot; add_domain; add_all_caps; add_codereview; add_codex   # no grilling
OUT="$(HOME="$FAKE_HOME" bash "$S" --profile spec 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'grilling'; } \
  && echo "PASS profile-spec-names-the-missing-capability" \
  || { echo "FAIL profile-spec-names-the-missing-capability (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# a conditional capability is not a prerequisite of anything
mkroot; add_grilling; add_domain; add_codereview; add_codex
for c in tdd diagnosing-bugs research; do add_cap "$c"; done   # prototype absent
HOME="$FAKE_HOME" bash "$S" --profile spec >/dev/null 2>&1 \
  && HOME="$FAKE_HOME" bash "$S" --profile run >/dev/null 2>&1 \
  && echo "PASS conditional-absence-does-not-break-a-profile" \
  || { echo "FAIL conditional-absence-does-not-break-a-profile"; fails=1; }
# ...but asking for it directly, right before use, fails and names it
OUT="$(HOME="$FAKE_HOME" bash "$S" --capability prototype 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'prototype'; } \
  && echo "PASS capability-check-names-the-conditional" \
  || { echo "FAIL capability-check-names-the-conditional (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# the run profile still owns the Codex required-review contract
mkroot; add_grilling; add_domain; add_codereview; add_all_caps   # no codex
OUT="$(HOME="$FAKE_HOME" bash "$S" --profile run 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cc-codex-triage'; } \
  && echo "PASS profile-run-requires-the-codex-contract" \
  || { echo "FAIL profile-run-requires-the-codex-contract (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# no flags = doctor's view: everything recommended, conditionals included
mkroot; add_grilling; add_domain; add_codereview; add_codex
for c in tdd diagnosing-bugs prototype; do add_cap "$c"; done    # research absent
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'research'; } \
  && echo "PASS default-checks-every-recommended-capability" \
  || { echo "FAIL default-checks-every-recommended-capability (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# an unknown profile is a usage error, not a silent pass
mkroot; add_grilling; add_domain; add_codereview; add_codex; add_all_caps
HOME="$FAKE_HOME" bash "$S" --profile nonsense >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] \
  && echo "PASS unknown-profile-is-a-usage-error" \
  || { echo "FAIL unknown-profile-is-a-usage-error (rc=$rc)"; fails=1; }
rm -rf "$ROOT"
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

```bash
cd /Users/clicktronix/Projects/ai/cc-tuner
bash plugins/cc-tuner/tests/execute-task/test_prereq.sh; echo "rc=$?"
```

Expected: the pre-existing cases still PASS; the new ones FAIL because the script rejects
`--profile` as an unknown argument or ignores it. `rc=1`.

- [ ] **Step 3: Add the capability registry and the selector**

In `prereq-check.sh`, immediately after `set -u`, insert the argument parsing:

```bash
PROFILE=""            # empty = every recommended capability (doctor's view)
CAPABILITY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { echo "--profile requires a value" >&2; exit 2; }
      case "$2" in spec|run) PROFILE="$2" ;; *) echo "unknown profile '$2'" >&2; exit 2 ;; esac
      shift ;;
    --capability)
      [ "$#" -ge 2 ] || { echo "--capability requires a value" >&2; exit 2; }
      CAPABILITY="$2"; shift ;;
    *) echo "usage: prereq-check.sh [--profile spec|run] [--capability <name>]" >&2; exit 2 ;;
  esac
  shift
done
```

Replace the nine-entry `for entry in …` loop (or the three `if ! have_matt_skill …` blocks, whichever
this working copy carries) with one registry and one pass over it:

```bash
# The single list of capabilities cc-tuner names by hand. `profile` is which command needs it:
# `spec`, `run`, or `conditional` — a method used only when the situation calls for it, verified
# immediately before use rather than at preflight. Two lists would eventually disagree about what a
# command requires, which is how `/spec` ends up refusing to start over a Phase 6 review skill.
CAPABILITIES="
grilling|spec|skills/productivity/grilling/SKILL.md|/spec grills the requirements
domain-modeling|spec|skills/engineering/domain-modeling/SKILL.md|/spec pins vocabulary and writes the ADR
tdd|run|skills/engineering/tdd/SKILL.md|/run picks the seam the first failing check binds to
code-review|run|skills/engineering/code-review/SKILL.md|/run Phase 6 reviews the candidate
diagnosing-bugs|conditional|skills/engineering/diagnosing-bugs/SKILL.md|/spec reproduces a reported defect
research|conditional|skills/engineering/research/SKILL.md|/spec sources an external fact
prototype|conditional|skills/engineering/prototype/SKILL.md|/spec settles a contested model
"

while IFS='|' read -r cap scope rel need; do
  [ -n "$cap" ] || continue
  if [ -n "$CAPABILITY" ]; then
    [ "$cap" = "$CAPABILITY" ] || continue
  elif [ -n "$PROFILE" ]; then
    [ "$scope" = "$PROFILE" ] || continue
  fi
  if ! have_matt_skill "$rel"; then
    echo "MISSING: mattpocock-skills capability '$cap' — $need" >&2
    echo "  install/update: /plugin marketplace add mattpocock/skills && /plugin install mattpocock-skills@mattpocock" >&2
    missing=1
  fi
done <<EOF
$CAPABILITIES
EOF

if [ -n "$CAPABILITY" ] && [ "$missing" -eq 0 ]; then
  case "$CAPABILITIES" in
    *"
$CAPABILITY|"*) ;;
    *) echo "unknown capability '$CAPABILITY'" >&2; exit 2 ;;
  esac
fi
```

Gate the Codex contract on the same selector — it belongs to the `run` profile:

```bash
if [ -z "$CAPABILITY" ] && { [ -z "$PROFILE" ] || [ "$PROFILE" = "run" ]; }; then
  if ! have_required_codex_review; then
    echo "MISSING: cc-codex-triage required-review contract (--required + exact approval state)" >&2
    echo "  install/update: /plugin marketplace update cc-codex-triage && /plugin update cc-codex-triage@cc-codex-triage" >&2
    missing=1
  fi
fi
```

- [ ] **Step 4: Point the call sites at their profile**

```bash
grep -n 'prereq-check.sh' plugins/cc-tuner/commands/spec.md plugins/cc-tuner/commands/run.md
```

In `spec.md` append ` --profile spec` to the call; in `run.md` append ` --profile run`. Leave
`doctor.sh:57` calling it with no flags — doctor is the one place that should report the full
recommended set.

- [ ] **Step 5: Update the doctor fixture, README, and contract**

`test_doctor.sh`'s `plugins_ok()` creates three anchors; the default profile now requires seven plus
the Codex contract. Extend it with `tdd`, `diagnosing-bugs`, `research`, `prototype` under
`$CACHE/cache/m/mattpocock-skills/1/skills/engineering/`.

In `README.md`, replace the "Requires the **mattpocock-skills** and **cc-codex-triage** plugins…"
sentence with a statement of what each command requires: `/spec` needs `grilling` and
`domain-modeling`; `/run` needs `tdd`, `code-review` and the cc-codex-triage required-review
contract; `diagnosing-bugs`, `research` and `prototype` are conditional and checked at the moment
they are used; `/cc-tuner:setup`'s doctor reports the whole recommended set.

Add to `workflow-contract.json`'s `invariants` array:

```json
{
  "id": "capability-specific-prerequisites",
  "requirement": "A command verifies only the capabilities it uses; a conditional method is verified immediately before it is applied, never as a precondition of starting."
}
```

- [ ] **Step 6: Run the suites**

```bash
bash plugins/cc-tuner/tests/execute-task/test_prereq.sh; echo "rc=$?"
bash plugins/cc-tuner/tests/setup/test_doctor.sh;        echo "rc=$?"
bash tests/run.sh | tail -3
```

Expected: `rc=0` from both suites and `cc-tuner validate ok`. `tests/run.sh` also re-hashes
`workflow-contract.json`; if it reports a changed contract SHA, update
`EXPECTED_SHARED_CONTRACT_SHA256` in `test_contract.sh` to the value it prints and note in the commit
that the shared contract moved (codex-tuner is already diverged at 1.1.0/14 and is out of scope here).

- [ ] **Step 7: Mutation proof**

```bash
cp plugins/cc-tuner/scripts/execute-task/prereq-check.sh /tmp/prereq.premutation
# make the profile selector inert — every capability is required again
perl -0pi -e 's/\[ "\$scope" = "\$PROFILE" \] \|\| continue/:/' \
  plugins/cc-tuner/scripts/execute-task/prereq-check.sh
bash plugins/cc-tuner/tests/execute-task/test_prereq.sh; echo "rc=$?"
cp /tmp/prereq.premutation plugins/cc-tuner/scripts/execute-task/prereq-check.sh
```

Expected: `FAIL profile-spec-ignores-run-capabilities` and
`FAIL conditional-absence-does-not-break-a-profile`, `rc=1`. Then the restore returns the suite to
green — re-run it to confirm before committing.

- [ ] **Step 8: Commit**

```bash
git add plugins/cc-tuner/scripts/execute-task/prereq-check.sh \
        plugins/cc-tuner/commands/spec.md plugins/cc-tuner/commands/run.md \
        plugins/cc-tuner/README.md plugins/cc-tuner/workflow-contract.json \
        plugins/cc-tuner/tests/execute-task/test_prereq.sh \
        plugins/cc-tuner/tests/setup/test_doctor.sh
git commit -m "Scope prerequisites to the capability a command uses"
```

---

### Task 2: Name the method and its workspace in `/spec`

**Files:**
- Modify: `plugins/cc-tuner/commands/spec.md` — `## 2. Grill the problem` readiness list, and a new
  paragraph before `## 4. Create the task branch`
- Modify: `plugins/cc-tuner/tests/execute-task/test_contract.sh`

**Interfaces:**
- Consumes: the `spec` profile and `--capability` check from Task 1.
- Produces: nothing later tasks read.

- [ ] **Step 1: Write the failing assertions**

Add next to the other `$SPEC` assertions in `test_contract.sh`:

```bash
need "spec-diagnosing-bugs-is-read-only-in-readiness" \
  'read-only reproduction' "$SPEC"
need "spec-prototype-is-workspace-scoped" \
  'disposable workspace' "$SPEC"
need "spec-domain-modeling-writes-after-the-branch" \
  'ADR or glossary file is written only after §4' "$SPEC"
need "spec-does-not-run-tdd" \
  'Do not run `mattpocock-skills:tdd` here' "$SPEC"
need "spec-conditional-capability-is-checked-before-use" \
  'prereq-check.sh" --capability' "$SPEC"
```

- [ ] **Step 2: Run and confirm it fails**

```bash
bash plugins/cc-tuner/tests/execute-task/test_contract.sh; echo "rc=$?"
```

Expected: five `FAIL spec-*` lines naming the missing strings, `rc=1`.

- [ ] **Step 3: Rewrite the readiness list**

```bash
grep -n 'the observed problem or desired user outcome' plugins/cc-tuner/commands/spec.md
```

Replace the six-bullet list that starts there with:

```markdown
Resolve before calling the task ready, each through the method named with it. A conditional method is
verified immediately before it is applied, not at preflight:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/prereq-check.sh" --capability <name>
```

- the observed problem or desired user outcome — for a reported defect run
  `mattpocock-skills:diagnosing-bugs` as a **read-only reproduction**: read, run, and observe until the
  failure reproduces. If diagnosis needs edits to proceed, make them in a disposable workspace and
  discard it; a readiness phase has no branch to own them;
- architecture ownership, boundaries, and affected consumers;
- explicit scope and rejected alternatives;
- acceptance evidence;
- the first failing regression check or an honest non-code baseline — record the command and its
  expected failure. Do not run `mattpocock-skills:tdd` here: it writes tests, and until §4 there is no
  task branch to write them on. It belongs to `/run`'s implementation phase;
- targeted and full verification commands, environment, fixtures, and external dependencies — when an
  external API or version fact decides the answer, run `mattpocock-skills:research` for a primary
  source instead of asserting it. Context7 stays the route for dependency documentation.
```

- [ ] **Step 4: State the workspace rule once, before §4**

Insert immediately before the `## 4. Create the task branch` heading:

```markdown
### Where a method may write

Everything above §4 runs before this task owns a branch, so anything written there lands on the
integration branch. Two methods write, and both are constrained:

- `mattpocock-skills:prototype` — only when a state model, reducer, schema, or UI shape is still
  contested after the grill, and **only in a disposable workspace** (a scratch directory or a throwaway
  worktree, removed afterwards). Carry only the fragment that encodes the decision into §5, and say it
  came from a prototype. A prototype has never been committed to any branch of this repository.
- `mattpocock-skills:domain-modeling` — used for vocabulary throughout the grill, but an ADR or
  glossary file is written only after §4, on the task branch this spec owns.
```

- [ ] **Step 5: Run and confirm green**

```bash
bash plugins/cc-tuner/tests/execute-task/test_contract.sh; echo "rc=$?"
```

Expected: `PASS` on all five, `rc=0`.

- [ ] **Step 6: Mutation proof**

```bash
cp plugins/cc-tuner/commands/spec.md /tmp/spec.premutation
perl -0pi -e 's/disposable workspace/scratch area/g' plugins/cc-tuner/commands/spec.md
bash plugins/cc-tuner/tests/execute-task/test_contract.sh | grep '^FAIL'
cp /tmp/spec.premutation plugins/cc-tuner/commands/spec.md
```

Expected: `FAIL spec-prototype-is-workspace-scoped`.

- [ ] **Step 7: Commit**

```bash
bash tests/run.sh | tail -3
git add plugins/cc-tuner/commands/spec.md plugins/cc-tuner/tests/execute-task/test_contract.sh
git commit -m "Name each spec method and the workspace it may write to"
```

---

### Task 3: Place `tdd` inside `/run`'s implementation phase

**Files:**
- Modify: `plugins/cc-tuner/commands/run.md` — `## Phase 2 — implement`
- Modify: `plugins/cc-tuner/tests/execute-task/test_contract.sh`

**Interfaces:**
- Consumes: the `run` profile from Task 1, which already requires `tdd`.
- Produces: nothing later tasks read.

- [ ] **Step 1: Write the failing assertion**

```bash
need "run-implements-through-tdd" \
  'mattpocock-skills:tdd` on the task branch' "$RUN"
```

- [ ] **Step 2: Run and confirm it fails**

```bash
bash plugins/cc-tuner/tests/execute-task/test_contract.sh; echo "rc=$?"
```

Expected: `FAIL run-implements-through-tdd`, `rc=1`.

- [ ] **Step 3: Name the method in Phase 2**

```bash
grep -n '^## Phase 2 — implement' plugins/cc-tuner/commands/run.md
```

Add, as the paragraph directly under that heading:

```markdown
Implement through `mattpocock-skills:tdd` on the task branch or its worktree — the spec already names
the first failing check and its expected failure, so this phase observes that failure before writing
the code that removes it. This is the only phase that may write tests: `/spec` records what the check
will be, `/run` writes it.
```

- [ ] **Step 4: Run and confirm green**

```bash
bash plugins/cc-tuner/tests/execute-task/test_contract.sh; echo "rc=$?"
```

Expected: `PASS run-implements-through-tdd`, `rc=0`.

- [ ] **Step 5: Mutation proof**

```bash
cp plugins/cc-tuner/commands/run.md /tmp/run.premutation
perl -0pi -e 's/`mattpocock-skills:tdd` on the task branch/test-first on the task branch/' \
  plugins/cc-tuner/commands/run.md
bash plugins/cc-tuner/tests/execute-task/test_contract.sh | grep '^FAIL'
cp /tmp/run.premutation plugins/cc-tuner/commands/run.md
```

Expected: `FAIL run-implements-through-tdd`.

- [ ] **Step 6: Commit**

```bash
bash tests/run.sh | tail -3
git add plugins/cc-tuner/commands/run.md plugins/cc-tuner/tests/execute-task/test_contract.sh
git commit -m "Implement through tdd inside the run implementation phase"
```

---

## Out of Scope

- `/cc-tuner:plan`, `blocked_by`, the task DAG, `frontier`, schema v2, and UI-as-projection — that is
  PR 2, planned in `2026-08-12-canonical-plan-graph.md`. This PR deliberately adds no dependency field
  and no `plan` capability profile, so it ships nothing without a caller.
- The production defects observed in Marqa/Stokli — pre-init fail-open, `runctl init` never running,
  legacy journal without state, a session executing an already-loaded old command version. They stay on
  the roadmap as later PRs and share no files with this one.
- Opening cc-codex-triage's model-invocable surface, and parity for `codex-tuner` / `codex-cc-triage`.
- Fixing the shared cache-fallback ordering in `execute_task_codex_plugin_root`. It is a real latent
  issue and pre-dates this work; it must be fixed once for every companion resolver, not carved out
  for one.

## Release

Additive to the command surface plus a narrowed prerequisite check — a minor bump. `release-please`
owns the version fields; do not hand-edit `plugin.json`, `marketplace.json`, or
`.release-please-manifest.json` (`tests/run.sh` §3 and §5b verify they agree).

Open the PR against `main`, then run the delivery path on it: `cc-tuner:deep-review`,
`mattpocock-skills:code-review`, and Codex `--required` on the exact candidate SHA, with Linux and
macOS CI green on that SHA. Merge only after explicit user confirmation.
