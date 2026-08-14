---
description: One entry point for setting cc-tuner up in a repo — checks CLI tools, gh scopes, companion plugins and MCP servers, then runs the installers that this repo actually needs. Use for "set up cc-tuner", "проверь окружение", or diagnosing why a board/gate/statusline step is not working.
argument-hint: '[check|install]'
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# /cc-tuner:setup

The three `*-setup` commands each install one thing and assume the environment around them is fine.
This command is the layer above: it finds out what is missing **before** anything is installed, then
runs only the installers this repo needs. `check` (default) reports and changes nothing; `install`
reports and then acts.

## 1. Diagnose

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/doctor.sh" quick
```

Pass `full` instead of `quick` when the user asks about MCP, or when a task-flow research step failed:
`full` adds a Context7 / chrome-devtools probe, which health-checks **every** configured MCP server
and can sit for 30 seconds on each unreachable one. That cost is why it is not the default.

Show the output as-is. `MISS` lines block something and carry their own fix; `WARN` lines are
degraded-but-usable. Exit is non-zero only when something is `MISS`.

Do not paraphrase a `MISS` into "you may want to" — each one names a command that fails without it.

## 2. Stop on blockers

If doctor exits non-zero, present the `MISS` lines and their fixes and stop. Two of them the user has
to run themselves, in their own shell:

- `gh auth refresh -s project` — an interactive browser flow; you cannot complete it for them.
- `/plugin install ...` — a Claude Code command, not a shell one.

In `check` mode, stop here regardless.

## 3. Install what this repo needs

Each of these is judgement, not a fixed list. Decide, say why, then delegate — the installers own
their own idempotency and confirmation prompts, so never reimplement their steps here.

- **`/cc-tuner:task-flow-setup`** — run it for any repo where work happens through branches and PRs,
  which is nearly all of them. Also run it when doctor reported a legacy `git-flow.md`: that path
  migrates the deltas file, and the cached board field IDs inside it, before anything overwrites it.
- **`/cc-tuner:smoke-verify-setup`** — only for repos with a frontend worth exercising. Check first
  (`package.json`, an `app/` or `src/components` tree). A backend-only repo should not install this;
  say so rather than installing a gate that will never fire.
- **`/cc-tuner:statusline-setup`** — user-level, not repo-level. Offer it once; if doctor already
  reported the script installed, skip silently.
## 4. Board wiring (`install` only, and only when `gh` is authorised)

The board is where setup most often stops half-done, because nothing fails loudly when it does.

1. Resolve the board and cache its field IDs into `.claude/rules/task-flow.local.md` — the recipes are
   in the `cc-tuner:task-flow` skill. Re-fetching these every session is the friction that makes
   agents skip the board, so caching them here is the point of doing it at setup time.
2. Check whether the org has an `Epic` issue type:
   ```bash
   gh api graphql -f query='query{organization(login:"<ORG>"){issueTypes(first:20){nodes{name}}}}'
   ```
   Absent → tell the user an **org admin has to add it in organisation settings**; it cannot be
   created through the API with an ordinary token. Until then the skill falls back to an `[Epic]`
   title prefix, which is a convention, not a filterable field. State that trade-off; do not create
   the prefix convention silently.

## 5. Report

End with what changed, what was deliberately skipped and why, and anything left for the user. A
skipped installer with a stated reason is a result; a silently skipped one is a bug report waiting to
be filed.

## Verification

- [ ] `check` mode wrote nothing — no installer ran, no file changed
- [ ] Every `MISS` was surfaced with its fix, none softened into a suggestion
- [ ] Any installer that was skipped has a stated reason
- [ ] A repo that had `git-flow.md` came out with `task-flow.local.md` still holding its cached field IDs
