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
- [ ] On a fresh machine, `install` installs the companions on one yes and writes the local route.
      Start a session with an empty config directory in a new repository with no remote:
      `cd "$(mktemp -d)" && git init -q && CLAUDE_CONFIG_DIR=$(mktemp -d) claude`, install cc-tuner,
      and run `/cc-tuner:setup install`. Confirm: a single confirmation lists `mattpocock-skills`
      (and `cc-codex-triage` only when `codex login status` succeeds); after it,
      `claude plugin list --json` shows each with `enabled` true at user scope, and the verify column
      says to run `/reload-plugins` or restart rather than claiming the commands are loaded;
      `.claude/rules/task-flow.local.md` holds the `local` block between `cc-tuner:delivery-route`
      markers; and every report row matches what `claude plugin list --json` and that file show.
- [ ] With `claude` off PATH (the desktop app or an IDE terminal), the companions row prints the
      `/plugin marketplace add …` and `/plugin install …` commands and installs nothing; with `jq`
      off PATH it says it cannot tell what is installed and installs nothing.
- [ ] A companion that is installed but disabled gets `claude plugin enable`, not a second install.
