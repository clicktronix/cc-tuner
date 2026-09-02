---
description: One user-run entry point for checking cc-tuner prerequisites and routing to the installers a repo needs. Use for "set up cc-tuner", "проверь окружение", or diagnosing why a board/gate/statusline step is not working.
argument-hint: '[check|install]'
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
disable-model-invocation: true
---

# /cc-tuner:setup

The three `*-setup` commands each install one thing and assume the environment around them is fine.
This command is the layer above: it finds out what is missing **before** anything is installed, then
prints only the installer commands this repo needs. `check` (default) reports and changes nothing;
`install` may wire the board after the user runs the suggested installers.

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

- `gh auth login` — an interactive browser flow; you cannot complete it for them.
- `/plugin install ...` — a Claude Code command, not a shell one.

In `check` mode, stop here regardless.

## 3. Install what this repo needs

Each of these is judgement, not a fixed list. Decide, say why, then print the exact command for the
user. Every installer is user-invoked and owns its own idempotency and confirmation prompts; never
invoke it from this skill or reimplement its steps. Reporting an install that could not have happened
is worse than not offering it, because nothing later contradicts the claim.

- **`/cc-tuner:task-flow-setup`** — offer it for any repo where work happens through branches and PRs,
  which is nearly all of them. Also offer it when doctor reported a legacy `git-flow.md`: that path
  migrates the deltas file, and the cached board field IDs inside it, before anything overwrites it.
  Print `/cc-tuner:task-flow-setup install`.
- **`/cc-tuner:smoke-verify-setup`** — user-run only. Decide whether the repo wants it: only one with
  a frontend worth exercising does, so check first (`package.json`, an `app/` or `src/components`
  tree). A backend-only repo should not have it; say so rather than offering a gate that will never
  fire. When it does want it, print the command for the user to run:

  ```
  /cc-tuner:smoke-verify-setup install
  ```
- **`/cc-tuner:statusline-setup`** — user-level, not repo-level. Offer its command once; if doctor
  already reported the script installed, skip silently. Print `/cc-tuner:statusline-setup install`.
- **The `Mechanism First` output style** — the plugin ships it, so there is nothing to install and
  no installer to print. Mention it once, as a preference rather than a fix: it makes answers lead
  with the mechanism, draw ASCII diagrams for boundaries and pipelines, and translate without
  transliterating. To use it: `/config` → Output style → `Mechanism First`, then `/clear`, because
  the style is read once at session start. Never select it for the user — a style rewrites part of
  the system prompt for every response, and that choice is theirs.

## 4. Board wiring (`install` only, and only when `gh` is authorised)

The board is where setup most often stops half-done, because nothing fails loudly when it does.

**First, does this repo track work on a board at all?** A spec may say `board: none`, and such a repo
never runs a board command. Ask if you do not know. If the answer is no, skip the whole step, say it
was skipped and why, and do not mention the `project` scope — a repo with no board is not missing
anything.

**Only then is the `project` scope required, and here it is load-bearing.** Doctor merely warns about
it, because doctor cannot know the answer to the question above. Without the scope every step below
fails with an opaque GraphQL error, so if the board is in play and doctor warned, stop this step,
print `gh auth refresh -s project` for the user to run — it is an interactive browser flow you cannot
complete for them — and say the board is not wired.

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
- [ ] No user-run installer was reported as done — each was printed for the user to run
- [ ] A repo with no board was not asked for a `project` scope, and heard why step 4 was skipped
- [ ] A repo that had `git-flow.md` came out with `task-flow.local.md` still holding its cached field IDs
