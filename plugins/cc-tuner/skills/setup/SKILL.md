---
description: Check or configure cc-tuner for this repository; report changes and remaining setup steps.
argument-hint: '[check|install|remove] [companions|agent-rules|task-flow|task-tools|statusline|board|delivery-route]'
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Skill
disable-model-invocation: true
---

# /cc-tuner:setup

Parse `$ARGUMENTS`. The mode is `check` (default), `install`, or `remove`; `remove` applies only to
the statusline. An optional node name limits the run to that node and its dependencies.

`check` writes nothing anywhere. `install` applies each node's change under one rule: an explicit
install request authorises **additive** repository edits — a block between markers, a new file, a
missing key — and nothing more. A rewrite of the repository's own instructions is not additive and has
its own confirmation boundary in node 2.

## Plugin root

References read the plugin's own files through `$PLUGIN`. Claude Code fills `${CLAUDE_PLUGIN_ROOT}` in this
skill's text but not in a reference or a plain shell, so every Bash call that uses `$PLUGIN` starts with this
block. When the filled value is not a directory, the block asks `claude plugin list --json` for the install
that applies to this repository, by `plugin-here.sh`'s scope rule (that script lives in the plugin root, so
it cannot locate it).

```bash
# The exact token, no `:-` default: Claude Code fills it here, and the shell leaves it unset.
PLUGIN="${CLAUDE_PLUGIN_ROOT}"
if [ ! -d "$PLUGIN" ]; then
  REAL=$(cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && pwd -P)
  # projectPath is stored as typed, so resolve it; "-" stands in for an empty field, which a tab IFS collapses.
  PLUGIN=$(claude plugin list --json 2>/dev/null | jq -r '.[]
      | select(.id == "cc-tuner@cc-tuner" and .enabled != false)
      | [ (if .scope == "local" then 0 elif .scope == "project" then 1 else 2 end), .scope,
          (.projectPath // "-"), (.installPath // "-") ] | @tsv' | sort -n |
    while IFS="$(printf '\t')" read -r _ scope ppath ipath; do
      if [ "$scope" = user ] || [ "$(cd "$ppath" 2>/dev/null && pwd -P)" = "$REAL" ]; then
        printf '%s\n' "$ipath"; break
      fi
    done)
fi
[ -d "$PLUGIN" ] || { echo "Could not locate the cc-tuner plugin: is it installed and enabled?"; exit 1; }
```

## Active profile

Use `CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` and `SETTINGS="$CONFIG_DIR/settings.json"`
in each Bash call that reads or writes user settings. Companions, session env and statusline all use
this profile. Repository settings stay in `.claude/`.

## The nodes

Every node has the same shape — **detect** the current state, **propose** the change as a diff,
**apply** it, **verify** by re-detecting — and reports one row in the final table. A node that
fails blocks only the nodes that depend on it; unrelated nodes still run and still report. Do not
stop the command because one node stopped.

| # | node | depends on | writes |
|---|---|---|---|
| 0 | environment | — | nothing |
| 0b | testing runbook | — | in install mode, missing commands/services/limits appended to an existing runbook; never a new document |
| 0c | companions | 0, after 0b | in install mode, after one per-plugin confirmation: user-scope `claude plugin install` / `enable`, which write `enabledPlugins` in `$SETTINGS`; a declined `cc-codex-triage` adds one line to `task-flow.local.md` |
| 1 | agent-rules discovery | 0 | one marked block in the root `AGENTS.md` (or a non-empty `AGENTS.override.md`) |
| 2 | instruction cleanup | 1 | `AGENTS.md` / `CLAUDE.md` / `.claude/rules/*` — only on confirmation; keeps the block first |
| 3 | task-flow rule | 0 | `.claude/rules/task-flow.md`, `task-flow.local.md`; migrates `git-flow*` |
| 3b | delivery route | 0 (its `host:` line), 3 | one short key block between `cc-tuner:delivery-route` markers in `task-flow.local.md`, written by `route.sh`; nothing on `github` |
| 4 | session env | 0, after 0c | `$SETTINGS` — up to two `env` keys |
| 5 | statusline | 0, after 0c; serialised after 4 | `$SETTINGS`, `$CONFIG_DIR/cc-tuner-statusline.sh` |
| 6 | board wiring | 3, `gh` auth, a repository that uses a board | `task-flow.local.md` cached field IDs |
| 7 | Codex audit | every applied node, and 0c's result | nothing |

Nodes 0c, 4 and 5 all write `$SETTINGS`, in that order: 0c through the `claude` CLI, 4 and
5 by patching. Never do two of them in one Bash call, and re-read the file right before each patch, so a
later writer never starts from a copy read before an earlier one ran.

### 0. Environment

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/doctor.sh" quick
```

Pass `full` instead of `quick` when the user asks about MCP, or when a task-flow research step
failed: `full` adds a Context7 / chrome-devtools probe, which health-checks **every** configured MCP
server and can sit for 30 seconds on each unreachable one. That cost is why it is not the default.

Show the output as-is. `MISS` lines block the nodes that need that tool and carry their own fix;
`WARN` lines are degraded-but-usable. Do not paraphrase a `MISS` into "you may want to" — each one
names a command that fails without it. Fixes the user has to run themselves, in their own shell or
session:

- `gh auth login` — an interactive browser flow; you cannot complete it for them.
- `codex login` — likewise interactive.
- `/plugin install ...` — a Claude Code command, not a shell one. Node 0c runs the shell form for a
  missing companion plugin; the user types the `/plugin` form only when `claude` is not on PATH.
  A `MISS` that names a `CONFLICT` has no command: the marketplace name is taken by another repository.

A `MISS` does not end the command. Record which nodes it blocks and continue with the rest.

### 0b. Testing runbook

Find what the repository already says about verifying itself — test commands and runners in
`package.json`, `Makefile`, `pyproject.toml`, `justfile`; a `TESTING.md`, `SMOKE.md`,
`CONTRIBUTING.md` or `docs/`/`wiki/` page describing how the project is exercised by hand; the
services, fixtures and credentials a run needs. Compare that against what the runners actually
define and what `cc-tuner:verify-feature` will need at run time: the command it cannot otherwise
know, the service it cannot start, the environment limit it cannot guess.

In `check` mode report **found: <files>**, or **none found**, plus the gaps. In `install` mode, when a
runbook exists, append the missing commands, service requirements and environment limits to it as a
diff — that is an additive edit to an existing document and is covered by the install request. When
no runbook exists, report the gaps for this node and continue the other nodes. Creating a new
testing document is outside this additive setup step.

### 0c. Companions

`/cc-tuner:spec` and `/cc-tuner:run` need `mattpocock-skills`; the required review of `/cc-tuner:run`
needs `cc-codex-triage` and a logged-in `codex`. Read [references/companions.md](references/companions.md)
and run it in the current mode; `scripts/setup/companion.sh` answers every question about the two plugins.
The node installs or enables what is missing after one confirmation per plugin, offers `cc-codex-triage`
only when `companion.sh codex` prints `ready` and the repository has not declined it, and records a decline in
`task-flow.local.md`. Without `claude` on PATH it prints the `/plugin` commands instead; without `jq` it
installs nothing.

### 1. Agent-rules discovery

Codex does not load `.claude/rules` on a matching read, so the root instruction file has to say "read
the applicable rules".

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/agent-rules-setup.py" check --repo .
```

Use `install` instead of `check` in install mode. Exit 1 in check mode means the file needs an
edit, and the last line says which: `MISSING` when no block is installed, `PRESENT BUT NOT FIRST`
when one is installed below prose the instruction budget can truncate — a late block is not a
missing one. Exit 2 means a conflicting block, symlink, or operational error: inspect it rather than
overwriting or claiming success. In install mode the last line reads `INSTALLED` or `MOVED`. The
helper honours a non-empty root `AGENTS.override.md`, leaves empty overrides empty so they do not
hide `AGENTS.md`, preserves existing prose and every rule file, and installs no per-repository
skill: `cc-tuner:agent-rules` is supplied by the plugin, and the instruction also works without it.
It needs a working Python 3; if node 0 reported none, report this node as unavailable.

An installed block proves the loading instruction is present, not that an agent obeys it. Start a
fresh Codex session to pick up changed startup instructions.

This node runs **before** instruction cleanup on purpose: with the block already in place, the
writer knows the Codex bridge exists and will not build a hand-made one beside it.

### 2. Instruction cleanup

Read the repository's `AGENTS.md`, `CLAUDE.md` and `.claude/rules/*.md` and its stated policy.
Healthy instructions are left alone: this node exists for the repository whose instruction files
contradict each other, duplicate a rule the linter already enforces, or bury an always-on rule under
prose that belongs in a skill. When that is the case, invoke `cc-tuner:claude-md-writer` in audit
mode and let it produce the rebuilt files. Tell it the `agent-rules` block from node 1 is the Codex
bridge — it keeps the block first, byte for byte, and generates no per-repository skill or pointer
table.

**This node rewrites canonical instructions, so the install rule above does not cover it.** Always
show the full diff. Ask for confirmation only when the user's request did not already authorise a
reorganisation, or when the diff resolves a contradiction between two rules by choosing one — a
user who asked for the cleanup is not asked again because of the file's type. A declined diff
leaves every file untouched; the later nodes still run. In `check` mode, report what the audit would
change and write nothing.

### 3. Task-flow rule

Read [references/task-flow-rule.md](references/task-flow-rule.md) and run it in the current mode.
The order inside it is load-bearing: the `git-flow.local.md` → `task-flow.local.md` migration runs
before anything creates the deltas file, and the legacy `git-flow.md` is removed only after the new
rule is in place. A differing or legacy rule file is shown as a diff and asked about once; "keep"
is a terminal state for this node only.
When node 0c held a declined `cc-codex-triage` because `task-flow.local.md` did not exist yet, this node
records it right after creating the file (step 6 of the reference).

### 3b. Delivery route

Outside GitHub no script refuses a bad merge, so `/cc-tuner:run` follows a route text from the plugin
(`skills/run/references/route-<host>.md`) instead of `merge.sh`. The repository holds only a short key
block naming that route. Read [references/delivery-route.md](references/delivery-route.md) and run it in
the current mode. It needs node 3, takes the host from `scripts/setup/host.sh`, and leaves the block to
`scripts/setup/route.sh`:

- `github` — nothing to write; `merge.sh` is the route.
- `gitlab`, `local` — the plugin's key block.
- `other` — the user's own description of how a candidate is opened, recorded, checked and merged; that
  description is the route.

Writing a missing block is additive; replacing one is confirmed. The block is committed with
`task-flow.local.md`, so task worktrees have it.

### 4. Session env

Two keys, both user-global, both offered once and applied in install mode only after the user
agrees; the `env` block is patched in one write, preserving the rest of the file.

**Task tools.** The native task tools (`TaskCreate`, `TaskUpdate`, `TaskList`) are opt-in on
current models, and nothing the plugin ships can turn them on. Without them `/cc-tuner:spec`
commits the plan and publishes no visible task list, which reads as the plugin not working. When
node 0 reported `CLAUDE_CODE_ENABLE_TODO_TOOLS` unset, add `"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"`.

**Nesting.** A `general-purpose` unit can still spawn down to depth 3 by the platform default, though
`/cc-tuner:run` tells units not to delegate and deep-review's lenses carry no Agent tool. When node 0
reported `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` unset, recommend `"2"`: a unit can run its own
`Explore` lookup, which the unit brief allows, while nothing below it can spawn. `"1"` is the strict
form and forbids that lookup too. Say what either changes outside cc-tuner — sessions using this
profile, including `/code-review` at max effort, which dispatches a verifier per candidate from
inside a subagent — because that is the user's call, not the plugin's. Heavy-check slots need no
setting: heavy.sh gives one slot per 8 GB of RAM. To override, set `CC_TUNER_HEAVY_SLOTS` (slots, an
e2e run holds two); set it user-wide, since sessions with different values see different capacities.

Detect has two halves: is `TaskCreate` in this session's tool list (your own tool list), and is the
key in `$SETTINGS`?

| tools | env | action |
|---|---|---|
| present | any | nothing to do |
| absent | set | the setting has not taken effect yet (this session predates it) or this model does not offer the tools; report which, and that a restart decides |
| absent | unset | the install case above |
| present | unset | the host enabled them another way; leave the env alone and say so |

An env edit is configuration for a later session, not proof the tools loaded. This command cannot
observe the next session, so after writing either key its verify column reads
**"written; takes effect after restart"**, and it names the check the user makes there: in the new
session, `TaskCreate` is in the tool list or it is not. Do not report this node as verified from
inside the session that wrote it.

### 5. Statusline

User-global, not repository-scoped, and offered rather than assumed: mention it once, and apply
it in install mode only after the user says yes in this run. Read
[references/statusline.md](references/statusline.md) for the copy, the guarded `settings.json`
patch and the restart note. Serialise it after node 4 for the shared-file reason above.
`/cc-tuner:setup remove statusline` runs the reference's **remove** section — the only `remove` this
command supports.

The `Mechanism First` output style ships with the plugin, so there is nothing to install. Offer it
once, as a preference: `/config` → Output style → `Mechanism First`, then `/clear`. Never select it
for the user — a style rewrites part of the system prompt for every response, and that choice is
theirs.

### 6. Board wiring (`install` only, and only when `gh` is authorised)

**First, does this repo track work on a board at all?** A spec may say `board: none`, and such a
repo never runs a board command. Ask if you do not know. If the answer is no, skip the whole step,
say it was skipped and why, and do not mention the `project` scope — a repo with no board is not
missing anything.

**Only then is the `project` scope required, and here it is load-bearing.** Doctor merely warns
about it, because doctor cannot know the answer to the question above. Without the scope every
step below fails with an opaque GraphQL error, so if the board is in play and doctor warned, block
this node, print `gh auth refresh -s project` for the user to run — it is an interactive browser
flow you cannot complete for them — and report the board as not wired.

1. Resolve the board and cache its field IDs into `.claude/rules/task-flow.local.md` — the recipes
   are in the `cc-tuner:task-flow` skill. Node 3 must have run: it guarantees `task-flow.local.md`
   exists and carries any migrated IDs.
2. Check whether the org has an `Epic` issue type, with the query in the `cc-tuner:task-flow` skill's
   Epics section. Absent → tell the user an **org admin has to add it in organisation settings**; it
   cannot be created through the API with an ordinary token. Until then the skill falls back to an
   `[Epic]` title prefix, which is a convention, not a filterable field. State that trade-off; do not
   create the prefix convention silently.

### 7. Codex audit (optional, install mode)

Runs only when `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/companion.sh" codex` prints `ready`,
`companion.sh state cc-codex-triage@cc-codex-triage` prints `installed`, and node 0c did not install or
enable the plugin in this run (its commands load only after `/reload-plugins`). Then spend one read-only
call to have a second model check what this command claims it did, within the authorisation the install
request already gave — no new permission question:

```text
/cc-codex-triage:ask --oneshot Here is the setup report for this repository: <the table below>.
Check the repository and say which rows you cannot confirm and why.
```

Fix confirmed findings and re-verify only the affected nodes; do not start an external review
loop. When it does not run, the row says which condition failed:

- **"audit: skipped — bridge not installed"**
- **"audit: skipped — codex is not ready (absent or not logged in)"**
- **"audit: skipped — bridge installed in this run, loads after /reload-plugins or a restart"**

Never omit the row: an absent check reported as nothing is indistinguishable from a passed one.

## Report

End with one table — `node | before | action | verification` — one row per node including the
skipped and blocked ones, then what is deliberately left for the user (`gh auth login`, a restart,
a declined diff). A row that says "installed" must be one whose verify step actually re-detected
the installed state.
