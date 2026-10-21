# Manual checks for `/cc-tuner:setup`

Maintainer checklist, moved out of the skill: these need a live session, so no script runs them.

- [ ] `check` mode leaves every file byte-identical, including `~/.claude/settings.json`.
- [ ] Running `install` twice reports every node "up to date" the second time and writes nothing.
- [ ] A repository with `git-flow.local.md` comes out with `task-flow.local.md` still holding its
      cached field IDs, and `git-flow.md` gone.
- [ ] With no board (`board: none`) and with no `gh` auth, the run completes and the board row says
      skipped or blocked — never installed.
- [ ] A declined instruction-cleanup diff leaves the files untouched and unrelated nodes still run.
- [ ] With both nodes 4 and 5 applied, `settings.json` holds both edits.
- [ ] Without `cc-codex-triage`, the audit row says skipped and the command still completes.
