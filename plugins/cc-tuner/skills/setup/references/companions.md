# Node: the companion plugins

Procedure for the **companions** node of `/cc-tuner:setup`. `/cc-tuner:spec` and `/cc-tuner:run` call
skills from `mattpocock-skills`, and `/cc-tuner:run` reaches Codex through `cc-codex-triage`. This node
installs what is missing on one confirmation. It writes user-global plugin state, so like the
statusline it is **offered, never assumed**: `install` applies it only after the user says yes in this
run, and `check` writes nothing.

**One program owns the facts.** `scripts/setup/companion.sh` answers every question this node asks —
the table of companions, whether `codex` is usable, whether this repository declined Codex review,
whether a plugin is installed, disabled or absent here, and the command that fixes it. Do not restate
its rules here or test a marketplace by hand: a marketplace is configured only when its name **and** its
repository match, and `hint` is what decides.

**Shell state does not persist between Bash calls.** Re-run the **Detect** block at the start of any
Bash invocation that reads `$ROOT`, `$C`, `$HAVE_CLAUDE` or `$HAVE_JQ`.

**Where this node sits.** It runs after the testing-runbook node (0b) and before session env (4). It
writes `~/.claude/settings.json` (`enabledPlugins`) through `claude plugin install` and `claude plugin
enable`, so nodes 4 and 5 re-read that file after it.

## Contents

- [Detect](#detect)
- [check](#check)
- [install](#install)
- [Record the decline](#record-the-decline)
- [Verification](#verification)

## Detect

Run the **Plugin root** block from [SKILL.md](../SKILL.md#plugin-root) first, in the same Bash call —
`${CLAUDE_PLUGIN_ROOT}` is not set in a reference — then:

```bash
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT="$PWD"
C="$PLUGIN/scripts/setup/companion.sh"
HAVE_CLAUDE=0; command -v claude >/dev/null 2>&1 && HAVE_CLAUDE=1
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
echo "claude=$HAVE_CLAUDE jq=$HAVE_JQ codex=$(bash "$C" codex)"
if OPTOUT="$(bash "$C" optout "$ROOT")"; then echo "codex review declined: $OPTOUT"; fi
bash "$C" table | cut -f1 | while IFS= read -r ID; do
  printf '%s\t%s\n' "$ID" "$(bash "$C" state "$ID" "$ROOT" | head -n 1)"
done
```

`table` lists the two companions with their marketplace and source. `state` prints `installed`,
`disabled`, `absent` or `unknown` (with the version and scope after the first two). Its scope rule is the
resolver's own: a copy installed for another project does not count, and an enabled copy that applies
here wins over a disabled one.

Decide the state of each companion, in this order:

1. `claude` is not on PATH (the desktop app or an IDE) → **no CLI**: install nothing; see the fallback.
2. `jq` is missing or `state` is `unknown` → **unknown**: say "cannot tell what is installed", name `jq`
   (<https://jqlang.github.io/jq/download/>) when that is the reason, and install nothing; see the
   fallback.
3. `installed` → nothing to do.
4. `disabled` → **disabled**; the fix is `claude plugin enable`.
5. `absent` → **absent**.

For a disabled or absent companion, `bash "$C" hint <id> "$ROOT"` prints the one command that fixes it,
in `/plugin …` form:

- `/plugin enable <id>` — disabled here.
- `/plugin install <id>` — absent, marketplace configured from the expected repository.
- `/plugin marketplace add <source> && /plugin install <id>` — absent, no marketplace of that name.
- exit 3 with `CONFLICT: marketplace <name> is configured from <repo>, expected <source> — remove it or
  install by hand` on stderr — a marketplace of that name comes from **another repository**. This is a
  stop for that plugin: show both sources, offer nothing for it, and do not install from that
  marketplace. The shell forms map one to one: `claude plugin marketplace add <source>`,
  `claude plugin install <id>`, `claude plugin enable <id>`.

Which companions are **offered**:

- `mattpocock-skills@mattpocock` — whenever it is `absent` or `disabled` (and `hint` is not a conflict):
  `/spec` and `/run` need it.
- `cc-codex-triage@cc-codex-triage` — only when `companion.sh codex` prints `ready`, `optout` exits 1 (the repository
  has not declined Codex review), and it is `absent` or `disabled`.

Without a usable Codex, `cc-codex-triage` is optional, not missing: report it as optional, say specs use
`review: none:<reason>` (`bash "$C" review "$ROOT"` prints the exact value), and — when `codex` exists
but is not logged in — name `codex login`. That login is interactive; the user runs it themselves, and
a later `/cc-tuner:setup install companions` offers the plugin. A repository that declined Codex review
is reported the same way, with its recorded reason, and the plugin is not offered again; deleting the
`cc-tuner-review: none:` line from `.claude/rules/task-flow.local.md` makes it offered again.

## check

Write nothing. One line per companion: installed (with its version from node 0), disabled, absent,
unknown, conflicting or optional (no usable Codex, or declined), each absent or disabled one with the
`hint` command, and `/cc-tuner:setup install companions` as the way to have it installed.

## install

1. **Fallbacks, which install nothing — before anything else**, because with no `claude` or no jq every
   state is `unknown` and no plugin would count as offered.
   - **`claude` is not on PATH** → nothing can say what is installed, so print, for the user to type into
     their own session, `bash "$C" commands <id>` for mattpocock-skills and — when `bash "$C" codex`
     prints `ready` and the repository has not opted out — for cc-codex-triage, saying an already
     installed one can be skipped. Mark the node "printed, not installed".
   - **No jq, or `state` is `unknown`** → "cannot tell what is installed" with the reason; install
     nothing; mark the node blocked.
2. **Nothing to do** → when no companion is offered, report each one's state ("up to date", optional,
   declined, conflict) and finish.
3. **Confirm once, per plugin.** One `AskUserQuestion` with `multiSelect: true`, one option per
   offered plugin, plus a last option **Install nothing**. Each option shows the plugin's source —
   `<marketplace> from <source>` taken from `table`, for example `mattpocock from mattpocock/skills` —
   the command(s) that will run (`claude plugin marketplace add <source>` only when `hint` says the
   marketplace is not configured, then `claude plugin install <id>`; for a disabled one `claude plugin
   enable <id>`), and that a **user-scope** plugin applies to every repository on this machine and runs
   its hooks in every session. Only the plugins the user ticks are applied; a plugin that was offered
   and not ticked is declined, and **Install nothing** declines all of them. The row reads "declined"
   and the other nodes still run.
4. **Apply** each ticked companion, fail-closed per plugin: a failed marketplace add means no install
   of that plugin, and one plugin's failure does not stop the other. Only add a marketplace when `hint`
   says to; running `marketplace add` on a configured marketplace is a needless failure that must not
   block the install.
   ```bash
   apply() {  # apply <plugin-id>
     local hint src
     hint="$(bash "$C" hint "$1" "$ROOT")" || { echo "STOP: $1 — not applied"; return 1; }
     case "$hint" in
       "/plugin enable "*) claude plugin enable "$1" ;;
       "/plugin marketplace add "*)
         src="$(bash "$C" table "$1" | cut -f3)"
         claude plugin marketplace add "$src" || { echo "ERROR: marketplace add $src failed; $1 not installed"; return 1; }
         claude plugin install "$1" ;;
       "/plugin install "*) claude plugin install "$1" ;;
       *) echo "nothing to do for $1" ;;
     esac
   }
   apply mattpocock-skills@mattpocock   # repeat per ticked companion
   ```
   Note every plugin this run installed or enabled: its commands are not loaded in this session, so the
   Codex audit (node 7) does not call it.
5. **Record the decline** when `cc-codex-triage` was offered and not ticked (below).
6. **Say what is left.** An installed plugin's commands are not loaded into this session: tell the user
   to run `/reload-plugins` or restart Claude Code. After installing `mattpocock-skills`, mention
   `/setup-matt-pocock-skills` once — a user-only command that records where this repository's issues
   live — and do not run it; the tracker question is `/cc-tuner:spec`'s.

## Record the decline

Declining `cc-codex-triage` when it was offered is a decision about this repository, not a missing
step: doctor and the preflight report the missing bridge as a note, and `/cc-tuner:spec` writes
`review: none:<reason>` into the spec instead of `review: codex`. The decision is recorded as one line
in `.claude/rules/task-flow.local.md`. The edit is additive, so the install request covers it.

```bash
LOCAL="$ROOT/.claude/rules/task-flow.local.md"
if bash "$C" optout "$ROOT" >/dev/null; then
  echo "decline already recorded"
elif [ -f "$LOCAL" ]; then
  [ -z "$(tail -c1 "$LOCAL")" ] || printf '\n' >> "$LOCAL"
  printf '%s\n' 'cc-tuner-review: none:declined-in-setup' >> "$LOCAL" && echo "recorded in $LOCAL"
else
  echo "task-flow.local.md does not exist yet"
fi
```

Commit `task-flow.local.md` with the recorded line, as the delivery-route block is: a task worktree reads the
committed file, so an uncommitted decline is lost there. When the file does not exist, the task-flow node (3) has not run. If it runs in this invocation, hold the
decision: its step 6 creates the file and then runs this block. Otherwise the line is **not** recorded —
skip, and say so: the row reads "declined — review: none not recorded; run `/cc-tuner:setup install
task-flow companions`". Never create the file here with a different header than the task-flow node's.

When the line is recorded the row reads **"declined — review: none recorded"**.

## Verification

- [ ] Re-run **Detect**: `state` prints `installed` for each companion this node installed or enabled.
- [ ] `claude plugin list --json` has a row for the id with `enabled` true, and its `version` goes in
      the report.
- [ ] A companion that fails either check is reported as **install did not take effect**, with the
      command output — never as installed.
- [ ] The verify column of an installed row reads **"installed; run /reload-plugins or restart to load
      its commands"**. This command cannot observe the commands loading, so it never claims they are.
- [ ] A declined cc-codex-triage reads "declined — review: none recorded" only when `optout` now exits 0.
- [ ] A declined, printed, conflicting or blocked node is reported as such, and the report's "left for
      the user" names the typed commands, `codex login`, `jq`, or the conflicting marketplace.
