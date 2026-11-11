# Node: the companion plugins

Procedure for the **companions** node of `/cc-tuner:setup`. `/cc-tuner:spec` and `/cc-tuner:run` use skills
from `mattpocock-skills`, and `/cc-tuner:run` reaches Codex through `cc-codex-triage`. This node installs
what is missing after one confirmation. It writes user-global plugin state, so like the statusline it is
**offered, never assumed**: `check` writes nothing.

**`scripts/setup/companion.sh` owns the facts:** the companion table, whether `codex` is usable, whether this
repository declined Codex review, each plugin's state here, and the command that fixes it. Ask it; never test
a marketplace by hand.

**Shell state does not persist between Bash calls.** Re-run the **Detect** block at the start of every Bash
call that uses `$ROOT`, `$C`, `$HAVE_CLAUDE` or `$HAVE_JQ`.

## Contents

- [Detect](#detect)
- [check](#check)
- [install](#install)
- [Record the decline](#record-the-decline)
- [Verification](#verification)

## Detect

Run the **Plugin root** block from [SKILL.md](../SKILL.md#plugin-root) first, in the same Bash call, then:

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

`table` lists the two companions with their marketplace and source. `state` prints `installed`, `disabled`,
`absent` or `unknown`, with the version and scope after the first two; a copy installed for another project
does not count.

Each companion's state, decided in this order:

1. `claude` is not on PATH (the desktop app or an IDE) → **no CLI**; see install step 1.
2. `jq` is missing or `state` is `unknown` → **unknown**: "cannot tell what is installed", naming `jq`
   (<https://jqlang.github.io/jq/download/>) when that is the reason; see install step 1.
3. `installed` → nothing to do.
4. `disabled` → **disabled**.
5. `absent` → **absent**.

For a disabled or absent companion, `bash "$C" hint <id> "$ROOT"` prints the one command that fixes it:

- `/plugin enable <id>` — disabled here.
- `/plugin install <id>` — absent; its marketplace is configured from the expected repository.
- `/plugin marketplace add <source> && /plugin install <id>` — absent; no marketplace of that name.
- exit 3 and `CONFLICT: marketplace <name> is configured from <repo>, expected <source> — remove it or
  install by hand` on stderr — another repository holds the marketplace name. Stop for that plugin: show
  both sources and offer nothing for it.

Each `/plugin` form has a shell form: `claude plugin marketplace add <source>`, `claude plugin install <id>`,
`claude plugin enable <id>`.

Which companions are **offered**, when absent or disabled and without a conflict:

- `mattpocock-skills@mattpocock` — always: `/spec` and `/run` need it.
- `cc-codex-triage@cc-codex-triage` — only when `companion.sh codex` (`bash "$C" codex`) prints `ready` and `optout` exits 1 (the
  repository has not declined Codex review).

Without a usable Codex, `cc-codex-triage` is optional, not missing: report it as optional, with the spec's
value from `bash "$C" review "$ROOT"` (`review: none:<reason>`). When `codex` exists but is not logged in,
tell the user to run `codex login` themselves (it is interactive) and then
`/cc-tuner:setup install companions`. A repository that declined Codex review is reported the same way, with
its reason; the plugin is offered again only after the `cc-tuner-review: none:` line is deleted from
`.claude/rules/task-flow.local.md`.

## check

Write nothing. One line per companion: installed (with its version from node 0), disabled, absent, unknown,
conflicting, or optional (no usable Codex, or declined). Each disabled or absent one carries its `hint`
command and `/cc-tuner:setup install companions`.

## install

1. **Fallbacks first.** Without `claude` or `jq` every state is `unknown`, so nothing counts as offered.
   - **`claude` is not on PATH** → run `bash "$C" commands <id>` and show its output.
     The user runs those `/plugin` commands in their session. Do this
     for mattpocock-skills, and for cc-codex-triage when `bash "$C" codex` prints `ready` and `optout` exits
     1, whatever its state. Say that an installed one can be skipped. The row reads "printed, not installed".
   - **No jq, or `state` is `unknown`** → "cannot tell what is installed", with the reason. Install nothing;
     the row reads "blocked".
2. **Nothing to do** → no companion is offered: report each companion's state (up to date, optional, declined, conflict) and finish.
3. **Confirm once, per plugin.** One `AskUserQuestion` with `multiSelect: true`: one option per offered
   plugin and a last option **Install nothing**. Each option shows:
   - the source, `<marketplace> from <source>` from `table`, for example `mattpocock from mattpocock/skills`;
   - the commands that will run: `claude plugin marketplace add <source>` only when `hint` says so, then
     `claude plugin install <id>`; `claude plugin enable <id>` for a disabled one;
   - that a user-scope plugin applies to every repository on this machine and runs its hooks in every
     session.

   **Install nothing** overrides every other tick: when it is selected, nothing is applied and every
   offered plugin is declined. Otherwise an offered plugin left unticked is declined. A declined row reads
   "declined" and the other nodes still run.
4. **Apply** each ticked companion. Each plugin fails on its own: a failed marketplace add skips that
   plugin's install and never stops the other.
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
   Note each plugin this run installed or enabled: its commands are not loaded yet, so the Codex audit
   (node 7) skips it.
5. **Record the decline** when `cc-codex-triage` was offered and left unticked (below).
6. **Say what is left.** Installed commands load after `/reload-plugins` or a restart: tell the user. After
   installing `mattpocock-skills`, mention `/setup-matt-pocock-skills` once, a user-only command that records
   where this repository's issues live; do not run it.

## Record the decline

Declining an offered `cc-codex-triage` is a decision about this repository: doctor and the preflight then
report the missing bridge as a note, and `/cc-tuner:spec` writes `review: none:<reason>`. The decision is one
line in `.claude/rules/task-flow.local.md`, an additive edit the install request covers:

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

The line is committed with `task-flow.local.md`, since task worktrees read only committed files. When the
file does not exist yet, the task-flow node (3) has not run. If it runs in this invocation, its step 6 creates
the file and then runs this block. Otherwise skip, and say so: the row reads "declined — review: none not
recorded; run `/cc-tuner:setup install task-flow companions`". Never create the file here. When the line is
recorded, the row reads **"declined — review: none recorded"**.

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
