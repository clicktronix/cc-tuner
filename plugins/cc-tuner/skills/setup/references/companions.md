# Node: the companion plugins

Procedure for the **companions** node of `/cc-tuner:setup`. `/cc-tuner:spec` and `/cc-tuner:run` call
skills from `mattpocock-skills`, and `/cc-tuner:run` reaches Codex through `cc-codex-triage`. This node
installs what is missing on one confirmation. It writes user-global plugin state, so like the
statusline it is **offered, never assumed**: `install` applies it only after the user says yes in this
run, and `check` writes nothing.

**Shell state does not persist between Bash calls.** Re-run the **Detect** block at the start of any
Bash invocation that reads `$ROOT`, `$HAVE_CLAUDE` or `$HAVE_JQ`.

## Contents

- [The companions](#the-companions)
- [Detect](#detect)
- [check](#check)
- [install](#install)
- [Verification](#verification)

## The companions

| plugin id | marketplace | source | offered |
|---|---|---|---|
| `mattpocock-skills@mattpocock` | `mattpocock` | `mattpocock/skills` | whenever it is not installed and enabled — `/spec` and `/run` need it |
| `cc-codex-triage@cc-codex-triage` | `cc-codex-triage` | `clicktronix/cc-codex-triage` | only when `codex` is on PATH and `codex login status` exits 0 |

Without a usable Codex, `cc-codex-triage` is optional, not missing: report it as optional, say specs
use `review: none:<reason>`, and — when `codex` exists but is not logged in — name `codex login`. That
login is interactive; the user runs it themselves, and a later `/cc-tuner:setup install companions`
offers the plugin.

## Detect

```bash
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT="$PWD"
HAVE_CLAUDE=0; command -v claude >/dev/null 2>&1 && HAVE_CLAUDE=1
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
CODEX=none
if command -v codex >/dev/null 2>&1; then
  if codex login status >/dev/null 2>&1; then CODEX=ready; else CODEX=nologin; fi
fi
echo "claude=$HAVE_CLAUDE jq=$HAVE_JQ codex=$CODEX"
for ID in mattpocock-skills@mattpocock cc-codex-triage@cc-codex-triage; do
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/plugin-here.sh" "$ID" "$ROOT" >/dev/null 2>&1
  echo "$ID plugin-here=$?"
done
```

`plugin-here.sh` exits 0 when an enabled installation applies to this repository, 1 when none does and
2 when it cannot tell. Node 0's doctor output reports the same states; the exit code is what this
node acts on. For an exit 1, tell absent from disabled:

```bash
claude plugin list --json | jq -r --arg id "$ID" '.[]? | select(.id == $id) | "\(.scope) enabled=\(.enabled)"'
```

A row with `enabled=false` is a **disabled** plugin: it needs `claude plugin enable`, not an install.

Decide the state of each companion, in this order:

1. `claude` is not on PATH (the desktop app or an IDE) → **no CLI**: install nothing; see the fallback.
2. `jq` is missing or `plugin-here.sh` exits 2 → **unknown**: say "cannot tell what is installed", name
   `jq` (`brew install jq`) when that is the reason, and install nothing; see the fallback.
3. exit 0 → **installed**; nothing to do.
4. exit 1 with an `enabled=false` row → **disabled**.
5. exit 1 otherwise → **absent**.

The command text for an absent plugin comes from the helper that doctor and the preflight use; do not
restate its rule:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/install-hint.sh" mattpocock mattpocock/skills mattpocock-skills@mattpocock
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/install-hint.sh" cc-codex-triage clicktronix/cc-codex-triage cc-codex-triage@cc-codex-triage
```

It prints the `/plugin …` form — `/plugin install <id>` when the marketplace is configured, otherwise
`/plugin marketplace add <source> && /plugin install <id>`. The shell form maps one to one:
`claude plugin marketplace add <source>` and `claude plugin install <id>`.

## check

Write nothing. One line per companion: installed (with its version from node 0), disabled, absent,
unknown or optional (no usable Codex), each absent one with the `install-hint.sh` command, and
`/cc-tuner:setup install companions` as the way to have it installed.

## install

1. **Nothing to do** → when every offered companion is installed, report "up to date" and finish.
2. **Fallbacks, which install nothing.**
   - **`claude` is not on PATH** → print, for the user to type into their own session, the
     `install-hint.sh` text for each offered absent companion (`/plugin marketplace add …` and
     `/plugin install …`), and for a disabled one `/plugin enable <id>`. Mark the node "printed, not
     installed".
   - **No jq, or exit 2** → "cannot tell what is installed" with the reason; install nothing; mark the
     node blocked.
3. **Confirm once.** Ask with AskUserQuestion, one question for everything offered, listing exactly
   what will run — for each absent companion its `claude plugin marketplace add <source>` (only when
   the marketplace is not configured) and `claude plugin install <id>`, for each disabled one
   `claude plugin enable <id>` — and that installs are **user scope**, the default, so they apply to
   every repository on this machine. Options: install all listed / skip. On skip, install nothing; the
   row reads "declined" and the other nodes still run.
4. **Apply** each confirmed companion, fail-closed: a failed add means no install for that plugin, and
   one plugin's failure does not stop the other. Set `ID`, `MKT` and `SRC` from the table.
   ```bash
   ID=mattpocock-skills@mattpocock; MKT=mattpocock; SRC=mattpocock/skills   # replace per companion
   if ! claude plugin marketplace list --json | jq -e --arg n "$MKT" 'any(.[]?; .name == $n)' >/dev/null 2>&1; then
     claude plugin marketplace add "$SRC" || { echo "ERROR: marketplace add $SRC failed; $ID not installed"; exit 1; }
   fi
   claude plugin install "$ID" || { echo "ERROR: install $ID failed"; exit 1; }
   ```
   For a disabled one, run `claude plugin enable "$ID"` instead.
5. **Say what is left.** An installed plugin's commands are not loaded into this session: tell the user
   to run `/reload-plugins` or restart Claude Code. After installing `mattpocock-skills`, mention
   `/setup-matt-pocock-skills` once — a user-only command that records where this repository's issues
   live — and do not run it; the tracker question is `/cc-tuner:spec`'s.

## Verification

- [ ] Re-run **Detect**: `plugin-here.sh` exits 0 for each companion this node installed or enabled.
- [ ] `claude plugin list --json` has a row for the id with `enabled` true, and its `version` goes in
      the report.
- [ ] A companion that fails either check is reported as **install did not take effect**, with the
      command output — never as installed.
- [ ] The verify column of an installed row reads **"installed; run /reload-plugins or restart to load
      its commands"**. This command cannot observe the commands loading, so it never claims they are.
- [ ] A declined, printed or blocked node is reported as such, and the report's "left for the user"
      names the typed commands, `codex login`, or `jq`.
