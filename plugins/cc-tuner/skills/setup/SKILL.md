---
description: One user-run command that sets a repository up for cc-tuner and says exactly what it did — rule loading, the task-flow rule, task tools, an optional statusline, an optional board — as independent nodes that each detect, propose, apply and verify. Use for "set up cc-tuner", "проверь окружение", or diagnosing why a board/gate/statusline step is not working.
argument-hint: '[check|install] [agent-rules|task-flow|task-tools|statusline|board]'
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Skill
disable-model-invocation: true
---

# /cc-tuner:setup

Parse `$ARGUMENTS`: the mode is `check` (default) or `install`; an optional node name limits the
run to that node and the nodes it depends on. `check` writes nothing anywhere. `install` applies
each node's change under one rule: an explicit install request authorises **additive** repository
edits — a block between markers, a new file, a missing key — and nothing more. A rewrite of the
repository's own instructions is not additive and has its own confirmation boundary in node 1.

## The nodes

Every node has the same shape — **detect** the current state, **propose** the change as a diff,
**apply** it, **verify** by re-detecting — and reports one row in the final table. A node that
fails blocks only the nodes that depend on it; unrelated nodes still run and still report. Do not
stop the command because one node stopped.

| # | node | depends on | writes |
|---|---|---|---|
| 0 | environment | — | nothing |
| 1 | instruction cleanup | 0 | `AGENTS.md` / `CLAUDE.md` / `.claude/rules/*` — only on confirmation |
| 2 | agent-rules discovery | 1 | one marked block in the root `AGENTS.md` (or `AGENTS.override.md`) |
| 3 | task-flow rule | 0 | `.claude/rules/task-flow.md`, `task-flow.local.md`; migrates `git-flow*` |
| 4 | task tools | 0 | `~/.claude/settings.json` — one `env` key |
| 5 | statusline | 0; serialised after 4 | `~/.claude/settings.json`, `~/.claude/cc-tuner-statusline.sh` |
| 6 | board wiring | 3, `gh` auth, a repository that uses a board | `task-flow.local.md` cached field IDs |
| 7 | Codex audit | every applied node | nothing |

Nodes 4 and 5 patch the same file. Never do both in one Bash call, and re-read the file right
before each patch so the second writer sees the first writer's result.

### 0. Environment

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/doctor.sh" quick
```

Pass `full` instead of `quick` when the user asks about MCP, or when a task-flow research step
failed: `full` adds a Context7 / chrome-devtools probe, which health-checks **every** configured MCP
server and can sit for 30 seconds on each unreachable one. That cost is why it is not the default.

Show the output as-is. `MISS` lines block the nodes that need that tool and carry their own fix;
`WARN` lines are degraded-but-usable. Do not paraphrase a `MISS` into "you may want to" — each one
names a command that fails without it. Two fixes the user has to run themselves, in their own shell:

- `gh auth login` — an interactive browser flow; you cannot complete it for them.
- `/plugin install ...` — a Claude Code command, not a shell one.

A `MISS` does not end the command. Record which nodes it blocks and continue with the rest.

### 1. Instruction cleanup

Read the repository's `AGENTS.md`, `CLAUDE.md` and `.claude/rules/*.md` and its stated policy.
Healthy instructions are left alone: this node exists for the repository whose instruction files
contradict each other, duplicate a rule the linter already enforces, or bury an always-on rule under
prose that belongs in a skill. When that is the case, invoke `cc-tuner:claude-md-writer` in audit
mode and let it produce the rebuilt files.

**This node rewrites canonical instructions, so the install rule above does not cover it.** Always
show the full diff. Ask for confirmation only when the user's request did not already authorise a
reorganisation, or when the diff resolves a contradiction between two rules by choosing one — a
user who asked for the cleanup is not asked again because of the file's type. A declined diff
leaves every file untouched; node 2 still runs. In `check` mode, report what the audit would change
and write nothing.

### 2. Agent-rules discovery

Codex builds its instruction chain once at startup and does not load `.claude/rules` on a matching
read the way Claude Code does, so the root instruction file has to say "read the applicable rules".

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

### 3. Task-flow rule

Read [references/task-flow-rule.md](references/task-flow-rule.md) and run it in the current mode.
The order inside it is load-bearing: the `git-flow.local.md` → `task-flow.local.md` migration runs
before anything creates the deltas file, and the legacy `git-flow.md` is removed only after the new
rule is in place. A differing or legacy rule file is shown as a diff and asked about once; "keep"
is a terminal state for this node only.

### 4. Task tools

The native task tools (`TaskCreate`, `TaskUpdate`, `TaskList`) are opt-in on current models, and
nothing the plugin ships can turn them on. Without them `/cc-tuner:spec` commits the plan and
publishes no visible task list, which reads as the plugin not working. When node 0 reported
`CLAUDE_CODE_ENABLE_TODO_TOOLS` unset, in install mode add
`"env": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"}` to `~/.claude/settings.json`, preserving the rest of
the file, after the user agrees once.

An env edit is configuration for a later session, not proof the tools loaded. This command cannot
observe the next session, so its verify column reads **"written; takes effect after restart"**,
and it names the check the user makes there: in the new session, `TaskCreate` is in the tool list
or it is not. Do not report this node as verified from inside the session that wrote it.

### 5. Statusline

User-global, not repository-scoped, and offered rather than assumed: mention it once, and apply
it in install mode only after the user says yes in this run. Read
[references/statusline.md](references/statusline.md) for the copy, the guarded `settings.json`
patch, `remove` and the restart note. Serialise it after node 4 for the shared-file reason above.

The `Mechanism First` output style is in the same category — the plugin ships it, so there is
nothing to install. Mention it once, as a preference: `/config` → Output style → `Mechanism
First`, then `/clear`, because the style is read once at session start. Never select it for the
user — a style rewrites part of the system prompt for every response, and that choice is theirs.

### 6. Board wiring (`install` only, and only when `gh` is authorised)

The board is where setup most often stops half-done, because nothing fails loudly when it does.

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
   are in the `cc-tuner:task-flow` skill. Re-fetching these every session is the friction that
   makes agents skip the board, so caching them here is the point of doing it at setup time. Node 3
   must have run: it is what guarantees `task-flow.local.md` exists and carries any migrated IDs.
2. Check whether the org has an `Epic` issue type:
   ```bash
   gh api graphql -f query='query{organization(login:"<ORG>"){issueTypes(first:20){nodes{name}}}}'
   ```
   Absent → tell the user an **org admin has to add it in organisation settings**; it cannot be
   created through the API with an ordinary token. Until then the skill falls back to an `[Epic]`
   title prefix, which is a convention, not a filterable field. State that trade-off; do not create
   the prefix convention silently.

### 7. Codex audit (optional, install mode)

If `cc-codex-triage` is installed, spend one read-only call to have a second model check what this
command claims it did, within the authorisation the install request already gave — no new
permission question:

```text
/cc-codex-triage:ask --oneshot Here is the setup report for this repository: <the table below>.
Check the repository and say which rows you cannot confirm and why.
```

Fix confirmed findings and re-verify only the affected nodes; do not start an external review
loop. When the bridge is not installed, the row reads **"audit: skipped — bridge not installed"**.
Never omit the row: an absent check reported as nothing is indistinguishable from a passed one.

## Report

End with one table — `node | before | action | verification` — one row per node including the
skipped and blocked ones, then what is deliberately left for the user (`gh auth login`, a restart,
a declined diff). A row that says "installed" must be one whose verify step actually re-detected
the installed state; reporting an install that could not have happened is worse than not offering
it, because nothing later contradicts the claim.

## Verification of this command

- [ ] `check` mode leaves every file byte-identical, including `~/.claude/settings.json`.
- [ ] Running `install` twice reports every node "up to date" the second time and writes nothing.
- [ ] A repository with `git-flow.local.md` comes out with `task-flow.local.md` still holding its
      cached field IDs, and `git-flow.md` gone.
- [ ] With no board (`board: none`) and with no `gh` auth, the run completes and the board row says
      skipped or blocked — never installed.
- [ ] A declined instruction-cleanup diff leaves the files untouched and node 2 still runs.
- [ ] With both nodes 4 and 5 applied, `settings.json` holds both edits.
- [ ] Without `cc-codex-triage`, the audit row says skipped and the command still completes.
