---
description: Check or configure cc-tuner for this repository; report changes and remaining setup steps.
argument-hint: '[check|install|remove] [companions|agent-rules|task-flow|task-tools|statusline|board|delivery-route]'
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Skill
disable-model-invocation: true
---

# /cc-tuner:setup

Parse `$ARGUMENTS`. The mode is `check` (default), `install`, or `remove`; `remove` applies only to
the statusline. An optional node name limits the run to that node and its dependencies.

`check` writes nothing. An explicit `install` request authorises **additive** repository edits (a
block between markers, a new file, a missing key) and nothing more. Rewriting the repository's own
instructions is not additive: node 2 has its own confirmation.

## Plugin root

References read the plugin's files through `$PLUGIN`. Claude Code fills `${CLAUDE_PLUGIN_ROOT}` in this
skill's text but not in a reference or a plain shell, so start every Bash call that uses `$PLUGIN` with
this block. When the filled value is not a directory, it finds the install that applies to this
repository.

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

Every node **detects** the current state, **proposes** the change as a diff, **applies** it and
**verifies** by re-detecting, then reports one row in the final table. A failed node blocks only the
nodes that depend on it; the rest still run and report.

| # | node | depends on | writes |
|---|---|---|---|
| 0 | environment | — | nothing |
| 0b | testing runbook | — | in install mode, missing commands/services/limits appended to an existing runbook; never a new document |
| 0c | companions | 0, after 0b | in install mode, after one per-plugin confirmation: user-scope `claude plugin install` / `enable`, which write `enabledPlugins` in `$SETTINGS`; a declined `cc-codex-triage` adds one line to `task-flow.local.md` |
| 1 | agent-rules discovery | 0 | one marked block in the root `AGENTS.md` (or a non-empty `AGENTS.override.md`) |
| 2 | instruction cleanup | 1 | `AGENTS.md` / `CLAUDE.md` / `.claude/rules/*` — only on confirmation; keeps the block first |
| 3 | task-flow rule | 0 | `.claude/rules/task-flow.md`, `task-flow.local.md` |
| 3b | delivery route | 0 (its `host:` line), 3 | one short key block between `cc-tuner:delivery-route` markers in `task-flow.local.md`, written by `route.sh`; nothing on `github` |
| 4 | session env | 0, after 0c | `$SETTINGS` — up to two `env` keys |
| 5 | statusline | 0, after 0c; serialised after 4 | `$SETTINGS`, `$CONFIG_DIR/cc-tuner-statusline.sh` |
| 6 | board wiring | 3, `gh` auth, a repository that uses a board | `task-flow.local.md` cached field IDs |
| 7 | Codex audit | every applied node, and 0c's result | nothing |

Nodes 0c, 4 and 5 all write `$SETTINGS`, in that order. Never do two of them in one Bash call, and
re-read the file right before each patch.

### 0. Environment

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/doctor.sh" quick
```

Pass `full` instead of `quick` when the user asks about MCP, or when a task-flow research step
failed: it adds a Context7 / chrome-devtools probe, which can wait 30 seconds on each unreachable MCP
server.

Show the output as-is. A `MISS` line blocks the nodes that need that tool and carries its own fix; do
not soften it. A `WARN` line is degraded but usable. A `MISS` does not end the command: record which
nodes it blocks and continue. Fixes only the user can run:

- `gh auth login`, `codex login`: interactive.
- `/plugin install ...`: a Claude Code command. Node 0c runs the shell form for a missing companion;
  the user types the `/plugin` form only when `claude` is not on PATH. A `MISS` that names a
  `CONFLICT` has no command: the marketplace name is taken by another repository.

### 0b. Testing runbook

Find what the repository already says about verifying itself: test commands and runners in
`package.json`, `Makefile`, `pyproject.toml`, `justfile`; a `TESTING.md`, `SMOKE.md`,
`CONTRIBUTING.md` or `docs/`/`wiki/` page on exercising the project by hand; the services, fixtures
and credentials a run needs. Compare that with what the runners define and what
`cc-tuner:verify-feature` needs at run time: a command it cannot know, a service it cannot start, an
environment limit it cannot guess.

In `check` mode report **found: <files>** or **none found**, plus the gaps. In `install` mode append
the missing commands, service requirements and environment limits to an existing runbook, as a diff.
When no runbook exists, report the gaps and go on: this node never creates a testing document.

### 0c. Companions

`/cc-tuner:spec` and `/cc-tuner:run` need `mattpocock-skills`; the required review of `/cc-tuner:run`
needs `cc-codex-triage` and a logged-in `codex`. Read [references/companions.md](references/companions.md)
and run it in the current mode; `scripts/setup/companion.sh` answers every question about the two plugins.
The node installs or enables what is missing after one confirmation per plugin, offers `cc-codex-triage`
only when `companion.sh codex` prints `ready` and the repository has not declined it, and records a decline in
`task-flow.local.md`. Without `claude` on PATH it prints the `/plugin` commands instead; without `jq` it
installs nothing.

### 1. Agent-rules discovery

Codex does not load `.claude/rules` by itself, so the root instruction file has to tell it to.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/agent-rules-setup.py" check --repo .
```

Use `install` instead of `check` in install mode. Exit 1 in check mode means the file needs an
edit, and the last line says which: `MISSING` (no block), `PRESENT BUT NOT FIRST` (the block sits
below prose the instruction budget can truncate) or `OUTDATED` (the block differs from the bundled
text). Exit 2 means several blocks, a symlink, or an operational error: inspect it; do not overwrite
or claim success. In install mode the last line reads `INSTALLED`, `MOVED` or `UPDATED`. The helper
honours a non-empty root `AGENTS.override.md` and preserves existing prose and every rule file. It
needs Python 3; if node 0 reported none, report this node as unavailable.

A changed block reaches Codex only in a fresh Codex session: say so.

### 2. Instruction cleanup

Read the repository's `AGENTS.md`, `CLAUDE.md` and `.claude/rules/*.md` and its stated policy.
Leave healthy instructions alone. When the files contradict each other, duplicate a rule the linter
already enforces, or bury an always-on rule under prose that belongs in a skill, invoke
`cc-tuner:claude-md-writer` in audit mode and let it produce the rebuilt files. Tell it the
`agent-rules` block from node 1 is the Codex bridge: it stays first, byte for byte, with no
per-repository skill or pointer table beside it.

**This node rewrites canonical instructions, so the install rule above does not cover it.** Always
show the full diff. Ask for confirmation only when the user's request did not already authorise a
reorganisation, or when the diff resolves a contradiction between two rules by choosing one. A
declined diff leaves every file untouched; the later nodes still run. In `check` mode, report what
the audit would change.

### 3. Task-flow rule

Read [references/task-flow-rule.md](references/task-flow-rule.md) and run it in the current mode,
keeping its step order. A differing or legacy rule file is shown as a diff and asked about once;
"keep" ends this node only. When node 0c held a declined `cc-codex-triage` because
`task-flow.local.md` did not exist yet, this node records it right after creating the file (step 5
of the reference).

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
current models, and the plugin cannot turn them on. Without them a plan is committed but no task
list is shown. When node 0 reported `CLAUDE_CODE_ENABLE_TODO_TOOLS` unset, add
`"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"`.

**Nesting.** The platform default lets a subagent spawn down to depth 3. When node 0 reported
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` unset, recommend `"2"`: a unit can run its own `Explore`
lookup, and nothing below it can spawn. `"1"` forbids that lookup too. Say that either value applies
to every session using this profile, including `/code-review` at max effort, which dispatches
verifiers from inside a subagent: the choice is the user's.

**Heavy checks** need no setting: heavy.sh gives one slot per 8 GB of RAM. `CC_TUNER_HEAVY_SLOTS`
overrides the count (an e2e run holds two); set it user-wide, since sessions with different values
see different capacities. A check waits at most `CC_TUNER_HEAVY_MEM_WAIT` seconds (default 600) while
the system reports memory pressure.

Detect has two halves: is `TaskCreate` in this session's tool list (your own tool list), and is the
key in `$SETTINGS`?

| tools | env | action |
|---|---|---|
| present | any | nothing to do |
| absent | set | the setting has not taken effect yet (this session predates it) or this model does not offer the tools; report which, and that a restart decides |
| absent | unset | the install case above |

An env edit takes effect in a later session, which this command cannot observe. After writing
either key the verify column reads **"written; takes effect after restart"** and names the user's
check: in the new session, `TaskCreate` is in the tool list or it is not. Do not report this node as
verified from the session that wrote it.

### 5. Statusline

User-global: mention it once, and apply it in install mode only after the user says yes in this
run. Read [references/statusline.md](references/statusline.md) for the copy, the guarded
`settings.json` patch and the restart note. `/cc-tuner:setup remove statusline` runs the reference's
**remove** section, the only `remove` this command supports.

The `Mechanism First` output style ships with the plugin. Offer it once, as a preference: `/config`
→ Output style → `Mechanism First`, then `/clear`. Never select it for the user: a style rewrites
part of the system prompt for every response.

### 6. Board wiring (`install` only, and only when `gh` is authorised)

**First, does this repository track work on a board at all?** Ask if you do not know. If not,
skip the step, say it was skipped and why, and do not mention the `project` scope.

**With a board, the `project` scope is required:** without it every step below fails with an opaque
GraphQL error. If doctor warned about the scope, block this node, print `gh auth refresh -s project`
for the user to run (it is interactive) and report the board as not wired.

1. Resolve the board and cache its field IDs into `.claude/rules/task-flow.local.md` with the
   recipes in [board.md](../task-flow/references/board.md). Node 3 must have run: it guarantees
   `task-flow.local.md` exists and carries any migrated IDs.
2. Check whether the org has an `Epic` issue type, with the query in board.md's Epics section. When
   it is absent, tell the user an **org admin has to add it in organisation settings**, and that
   until then the skill falls back to an `[Epic]` title prefix, which is a convention, not a
   filterable field.

### 7. Codex audit (optional, install mode)

Runs only when `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/companion.sh" codex` prints `ready`,
`companion.sh state cc-codex-triage@cc-codex-triage` prints `installed`, and node 0c did not install or
enable the plugin in this run (its commands load only after `/reload-plugins`). Then one read-only
call has a second model check what this command claims it did; the install request already
authorised it:

```text
/cc-codex-triage:ask --oneshot Here is the setup report for this repository: <the table below>.
Check the repository and say which rows you cannot confirm and why.
```

Fix confirmed findings and re-verify only the affected nodes; do not start an external review
loop. When it does not run, the row says which condition failed:

- **"audit: skipped — bridge not installed"**
- **"audit: skipped — codex is not ready (absent or not logged in)"**
- **"audit: skipped — bridge installed in this run, loads after /reload-plugins or a restart"**

Never omit the row.

## Resources files

Session coordination reads two optional files: `.claude/cc-tuner-resources.json` (the repository's `product` key
and its shared or leased resources) and `~/.config/cc-tuner/resources.json` (machine resources such as Chrome's
debugging port). Write one only when the user asks; the plugin README has the format.

## Report

End with one table, `node | before | action | verification`, one row per node including the skipped
and blocked ones, then what is left for the user (`gh auth login`, a restart, a declined diff). A
row says "installed" only when its verify step re-detected the installed state.
