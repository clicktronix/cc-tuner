# cc-tuner plugin

Sets a repository up for agent work and carries a task from an approved spec to a merged pull
request. One install, no per-project copies to drift.

## Skills

### `agent-rules`

Reads the applicable repository rules and linked contracts before a review or change, checking the
actual rule inventory so an outdated index cannot hide a rule. `/cc-tuner:setup install agent-rules`
adds a short loading instruction at the top of the root AGENTS.md (or AGENTS.override.md); `check` is
read-only. Placement rules: the root README.

### `claude-md-writer`

Create, refactor, and audit **CLAUDE.md**, **AGENTS.md** and **`.claude/rules/`** instruction files,
following the official memory docs (<https://code.claude.com/docs/en/memory>) and the AGENTS.md open
format. Triggers when you create, trim or split a CLAUDE.md or AGENTS.md, organize instructions into
`.claude/rules/`, or decide what belongs in CLAUDE.md vs rules vs `CLAUDE.local.md` vs tool config. Load order, size targets, imports, auto memory, path-scoped rules
and the verified source list are in the skill's `reference.md`.

### `statusline`

A two-line usage statusline. Plugins can't register a statusline, so the statusline node of
`/cc-tuner:setup` copies the script to `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cc-tuner-statusline.sh`
and wires it into the user's `settings.json` with a backup, offered rather than assumed
(`check statusline` and `remove statusline` also exist):

```
/cc-tuner:setup install statusline
```

```
➜ my-project git:(main) S:2 M:1 U:4 | Opus 4.8 xhigh | 1h12m
 | 5h:66%[▓▓▓▓▓░░░]>23:30  7d:9%[▓░░░░░░░]>17:00 | ctx:8%[▓░░░░░░░░░] | subagents: 2 sonnet · 1 opus
```

- **Line 1**: current directory, git branch with staged / modified / untracked counts (`✓` when
  clean), model and reasoning effort (when the model exposes it), session duration.
- **Line 2**: the rate-limit windows the plan has (utilization, bar, local reset time), then
  context-window usage, then the models of the subagents running now. Bars turn yellow at 50% and
  red at 80%. A plan without a 5-hour window shows only `7d`.

**Rate-limit data.** Claude Code's statusline payload carries `rate_limits.five_hour` and
`rate_limits.seven_day` ([docs](https://code.claude.com/docs/en/statusline)) for eligible claude.ai
Pro/Max accounts after the session's first API response; the script renders straight from it and
touches no credentials or network. A missing window is hidden, never shown as `0%`. Only when the
payload has no `rate_limits` at all does it fall back to Claude Code's OAuth usage endpoint
(`api.anthropic.com/api/oauth/usage`), cached for 5 minutes behind a best-effort `mkdir` lock. That
endpoint is **unofficial**: Anthropic does not document it and may change or remove it, and if it,
the token or a dependency is unavailable the rate-limit segment is dropped while the rest renders.
The token is read locally — macOS Keychain (`Claude Code-credentials`) or
`~/.claude/.credentials.json` elsewhere, honouring `$CLAUDE_CONFIG_DIR` — and sent only to
`api.anthropic.com`.

**Subagent models.** The payload does not name running subagents, so cc-tuner's mod writes their
models to `<config dir>/cc-tuner/subagents/<session id>` and rewrites the file every 5 seconds while
any runs. The script shows that text unless the file is empty or older than 30 seconds, which is how a
crash or a reload clears the segment; `refreshInterval` in `settings.json` redraws the line while the
session waits. Without this statusline the mod pins the same text under the prompt. Git change counts
are reused for 30 seconds per directory and branch, since the timer would otherwise repeat the scan;
the branch name is read on every render.

**Requirements.** `bash`, `jq`, `git`; the OAuth fallback also needs `python3`. Every payload field it
reads is from Claude Code's documented statusline payload.

**Customizing.** Edit the installed copy: colours, thresholds and bar length are in `make_bar`, the
cache TTL is `USAGE_CACHE_TTL` (300 s), and each segment function (`git_info`, `model_info`,
`duration_info`, `usage_info`, `context_info`) can be dropped from the final `printf`. Re-running
install after a plugin upgrade refreshes the copy and overwrites local edits, so keep customizations
in a fork of the script.

### `task-flow`

Repository chores around a task — branch and commit conventions, the pre-PR checklist, cleanup
after a merge, stacked-PR merges, the spec lifecycle (`wiki/PLANS/` → `ARCHIVE`, `docs/` fallback)
and case studies of the incidents behind its rules. GitHub Projects board recipes (create-on-board,
field-ID caching, card lifecycle) and epics live in `references/board.md`, read only when a board or
an epic is involved.

The always-on core installs per repo via the task-flow node of `/cc-tuner:setup` (plugins
can't ship `.claude/rules/*`): a versioned template, repo-specific deltas in
`task-flow.local.md`, and a diff-and-ask for a hand-maintained copy. Setup manages the local file's delivery block, review opt-out and cached board IDs;
it preserves other content.

Previews, dedicated MCP servers and test containers run as Bash background tasks, which Claude Code
stops when the session exits. A `/clear` does not stop them, so the plugin's hooks module
(`hooks/register.ts`, a Claude Code mod) stops the ones Bash started in the cleared conversation, except a task the guard keeps (see
[Sessions of one product](#sessions-of-one-product)).
The same module refuses a Bash command that would print secret values into the transcript: a bare `env`,
`printenv`, `set`, `export`, `declare` or `typeset`, or `cat`/`head`/`tail`/`less`/`more`/`bat` of a `.env`
file, also in a subshell, `$(…)` or `bash -c`. Output sent to a file or piped into `wc`, `grep -c` or
`grep -q` passes. The refusal names commands that print no value. It guards against the common accident and
is no boundary: `grep . .env` still prints the file.

### `deep-review`

A read-only review for large, cross-boundary or sensitive candidates, replacing the ordinary
advisory pass. Restricted `cc-tuner:deep-review-lens` agents read owner-prepared diff files; one
owner validates findings and coverage for the spec's verdict owner.

The shared `review-diff.sh` reader keeps inventory and packets consistent. `shard-diff.sh` validates
actual packet coverage and size before dispatch. Seven lenses run; with shards, four file-local
lenses run per shard and Specification, Architecture and Blind spots each cover the whole candidate.
Blind spots asks what the user and the spec did not consider (unwalked scenarios, business-logic
holes, simpler alternatives); its findings are questions for the owner, never blockers. Architecture,
Security and Blind spots run on Opus, the rest on Sonnet unless the packet is one of the Opus cases below. Past 19 lenses (four shards) the owner asks
the user whether to run them all, cut to the limit, or re-shard. The
[deep-review procedure](skills/deep-review/SKILL.md) owns the accepted partition and the line printed
before dispatch — lens count by model and effort.


### `verify-feature`

A stage of `/cc-tuner:run`, and a skill you can invoke on its own. It reads the spec's acceptance
criteria and the diff, finds what the repository already provides (test commands, fixtures, runbooks, a
dev server, a database, a browser tool), picks the instrument each behaviour needs, runs it, and
records **what was observed**, each line tagged with its instrument (`[browser]`, `[api]`, `[test]`,
`[cli]`) or marked `NOT PROVED`. Evidence must directly decide the criterion; unproved criteria return
to `/run`, which runs this stage in a subagent and takes back only the record. Steps:
`skills/verify-feature/SKILL.md`.

## /spec and /run

The task loop has two commands. `/cc-tuner:spec <issue | description>` does the discovery, creates the
task branch, resolves open decisions, has a read-only Opus agent look for Blind spots in the draft (its
questions go to the user), and confirms the contract and slices once. It saves the approved spec
and plan, commits when authorized, and projects the plan into native tasks when available.
`/cc-tuner:spec --groom <issue>` records decisions directly in the issue.

`/cc-tuner:run [--auto | --local-only] <spec>` implements, verifies and reviews the task. It performs
authorized commits, pushes and PR/MR writes. When commits are reserved for a person, it uses the
files in the task checkout and hands over the diff and evidence. When publication alone is reserved,
it can hand over a verified commit. Merge requires explicit authorization or requested `--auto`
within the repository's permissions. GitHub merges go through `scripts/merge.sh`.

Implementation units have a 300-turn cap and return unfinished work to the orchestrator. Deep-review
lenses have read-only tools and a lens limit. The orchestrator may split and reassign
slices while preserving scope and acceptance. See `skills/run/references/placement.md`.
Unattended execution continues only while
every gate is green, and never waives incomplete DoR, missing RED→GREEN evidence, failed tests, stale
review, unresolved `[eyes]`, CI that ran and did not pass, or scope beyond the spec. Where a repository
runs no CI at all, the spec says so in advance and a pull-request comment records what stood in for it
for that commit; what a person approves is the **mode**, once, at spec time. After merge it reconciles
only the task lifecycle; deploy, publish and migration remain forbidden.

Run progress lives in the saved plan file (its `- [x]` ticks) and in Claude Code's task list; there
is no state file. The task list survives `/compact` and resume unchanged. A new session (`startup` or
`/clear`) starts with an empty list, and a `SessionStart` hook asks the agent to rebuild it from the plan in HEAD, emitting the unfinished slices with their blocking edges and any open checkbox outside a slice. It only asks: a command hook cannot call
`TaskCreate`.

One thing checks rather than advises. `scripts/merge.sh [--check-only] [--ci <mode>]
[--review none:<reason>] <pr> <squash|merge> <candidate-sha> [review-thread]` re-reads the companion's exact-candidate approval, the public verdict,
CI and the head SHA, refuses unless they agree at that commit, and pins the head with
`--match-head-commit`. `--ci` says which checks answer for CI: GitHub's required ones by default
(`required` does not look at optional checks, so require an optional check on the branch or declare
`any` where it matters), every reported one with `any`, or none where the repository runs none, which
needs a PR comment recording the local result for the same commit. No mode lets a check it reads fail;
a skipped check does not count either way, and at least one must pass.
A pull request with neither a plan nor a named review is refused, drafts are refused until marked ready,
and `--unmanaged` merges only an ordinary pull request outside a run.

cc-tuner's hooks see only the agent's own tool calls, so a raw CLI call, the merge button on
github.com, `git push` and the REST API can all bypass `merge.sh`. It is workflow discipline, not a
local security boundary.

### Heavy checks

Heavy checks (full suite, e2e, builds, container starts) go through `scripts/heavy.sh`, whose
machine-wide slots limit how many run at once across sessions: one slot per 8 GB of RAM (at least 1),
an e2e run holds two, waiters start in arrival order. While the system reports memory pressure a check
waits at most `CC_TUNER_HEAVY_MEM_WAIT` seconds (default 600), then starts with a warning, and for the
next 600 s checks skip that wait. A check waits for a slot at most `CC_TUNER_HEAVY_WAIT` seconds
(default 1800), then starts without one, also with a warning. `CC_TUNER_HEAVY_SLOTS` overrides the
slot count, in slots of weight; set it user-wide, since sessions with different values see different
capacities. Who runs which check, and with what weight, is in `skills/run/references/placement.md`.

### Delivery routes and the tracker

`/spec` records the repository's `host:` (`github`, `gitlab`, `local` for no remote, or `other`), which
`scripts/setup/host.sh` reads from the remote URL without a network call; `/run` checks it again. On GitHub
delivery is `merge.sh`. On GitLab and with no remote, `/run` follows a delivery route shipped with the plugin
(`skills/run/references/route-<host>.md`), so a candidate cannot edit its own gate; on another host the
route is the user's own description. The repository keeps only a short key block in
`.claude/rules/task-flow.local.md`, written by `/cc-tuner:setup install delivery-route` and checked by
`scripts/setup/route.sh`. A missing or stale route blocks publication while local work continues. A route keeps the gate's order and
records, but the agent performs its steps, so no script refuses on its behalf.

Where issues live comes from `docs/agents/issue-tracker.md`, which `/setup-matt-pocock-skills` writes; the
spec's `tracker:` is `gh`, `glab`, `local` (markdown files under `.scratch/`), `other` or `none`. `/spec`
asks once when the file is absent. Boards stay GitHub-only.

### Sessions of one product

The hooks module keeps a record per live Claude session in `~/.cache/cc-tuner/sessions`. Sessions of one
repository, or of repositories sharing a `product` key, are peers. Before each tool call a guard allows,
notes (the call runs) or stops, naming what is at stake, the safe way and the ack.

Stops:

- Next to a peer writing in the same checkout: a branch switch, `rebase`, `merge`, `pull`, `reset --keep`.
- Losing files this session did not make, peer or not: `reset --hard`, `clean`, `restore`,
  `checkout -- <path>`, `stash`, `rm -r` or `worktree remove` of their checkout, `rm -r` of a directory
  with another session's uncommitted files.
- With a live peer: staging or committing such files (`add -A`, `commit -a`).
- Commit, push or PR while HEAD is not the branch this session was last on; the ack makes HEAD that branch.
- A peer's branch or worktree deleted, its branch force-pushed, its process killed, a stash entry not this
  session's dropped.
- A step that loses work in a directory the guard cannot read (`cd "$DIR" && git clean -fd`).
- Bash stopping a shared resource another session uses: the agent can acknowledge that specific stop.
- `TaskStop` for a shared task in use, or a tool leased exclusively to another session: wait for the
  other session to finish or release its lease. These operations have no Bash acknowledgement.

Notes:

- With no live peer: files a staging or committing step takes that this session did not make.
- An edit of a changed file this session did not make; an edit, `>` or `rm` on a file a peer edited; an edit
  where a peer writes or of a path it claimed; a branch switch where a peer's cwd is.
- Once a session, `the peers guard is inactive (…)`: it failed, or could not read the process list or a
  checkout.

Direct edits identify a writer. For Bash, the guard infers ownership from a file's `ctime` during
a saved command interval while no peer is writing. An editor save during a build can look like the
build's edit, including after resume. Inspect the actual diff before discarding or staging it.

For a Bash stop, the reason names the action and its `CC_TUNER_ACK=<key>`. The acknowledgement
lasts 30 minutes. The agent decides for a known peer; when an edit may belong to the user, preserve
it or obtain their decision before discarding it.

Tools, `mcp__cc-tuner__peers_*`:

- `peers_report [path]`: live peers of the repository at `path` or the cwd: branch, claims, edited paths,
  merge conflicts with HEAD. `/spec` calls it before approval.
- `peers_claim <plan>`: publishes the plan's open Owned paths and reports overlaps. `/run` calls it before
  the first slice, after each tick and before integration.
- `peers_release <key>`: gives up this session's leases of `key`. A lease also ends with its holder, or after
  10 minutes unused.

Resources are declared, never detected; setup writes them only when asked. The repository's go in
`.claude/cc-tuner-resources.json`:

```json
{"product": "shop", "resources": [{"key": "stack", "kind": "shared", "start": ["pnpm stack:up"], "stop": ["pnpm stack:down"]}]}
```

The machine's go in `~/.config/cc-tuner/resources.json` and apply across products:

```json
{"resources": [{"key": "chrome", "kind": "exclusive", "tools": ["mcp__chrome-devtools__*"]}]}
```

A `shared` resource stays up while another session of the product is live, and `/clear` keeps its task. An
`exclusive` one is leased to its first user, per product or, for the machine's, per machine; the lease is
taken under a kernel file lock, which needs `python3`. The machine
file can map repositories to products, `"products": {"shop": ["~/code/shop-api", "~/code/shop-web"]}`.
`"guard": false` disables peer coordination. The session-wide transcript check and Bash task tracking still run.

Known limits:

- With git older than 2.42, replacement refs (`git replace`) or no readable `ps`, nothing is checked: staging,
  committing and pushing run with the inactive note, and a step that loses files stops with an ack.
- Liveness is cached for a minute; a session idle for 8 h blocks only through its uncommitted files. Past 500
  files already changed at a first touch, only edited files are a session's own.

### Companions

**mattpocock-skills** is required by `/spec` and `/run`: grilling, domain modelling, module design,
prototypes, PR bodies, hard-bug diagnosis and ordinary review. **cc-codex-triage** is optional: it
supplies `review: codex` with a logged-in Codex CLI and the required-review interface (0.14+).
`scripts/setup/companion.sh` selects the spec value. An unavailable CLI or a recorded opt-out
gives `none:<reason>`. With usable Codex and a missing, disabled or incompatible bridge, resolve
setup or explicitly decline before approving the spec. The approved mode governs delivery.

## Output style

`Mechanism First` (`output-styles/mechanism-first.md`) ships with the plugin and appears in the
`/config` picker once cc-tuner is enabled. It makes answers lead with the mechanism behind a result
rather than a list of steps, draw ASCII diagrams for boundaries, pipelines and ownership seams, keep
issue and PR references in `<identifier> — <title>` form, and translate into the user's language
without transliterating English terms. It sets `keep-coding-instructions: true`, so Claude Code's own
engineering instructions stay in place.

Nothing installs it: pick it in `/config` → Output style, then `/clear`. The plugin does not set
`force-for-plugin`; which style you run is your choice.

## Install

```
/plugin marketplace add clicktronix/cc-tuner
/plugin install cc-tuner@cc-tuner
```

Then run `/reload-plugins` and `/cc-tuner:setup install`.

The `claude-md-writer`, `task-flow`, `deep-review` and `verify-feature` skills are model-invoked when
their descriptions match; `deep-review` and `verify-feature` are also available directly. The
agent may also start `/cc-tuner:spec` and `/cc-tuner:run` itself when the user asks for a task to be
planned or implemented; `--auto` stays the user's request. `/cc-tuner:setup` remains an explicit
user command: it writes user-global settings.

## Scope

Runs in Claude Code; also installs the shared `AGENTS.md` rule-loading instruction used by Codex.
Setup manages repository instructions and the active Claude profile's companions, session env and statusline.

## Maintaining

- `bash tests/run.sh` (repository root) is the gate. It needs `claude` on PATH at the version pinned in
  `tests/flow/CLAUDE_CODE_VERSION` (CI installs it) to validate and test the hooks module; the
  TypeScript check of that module runs only on a machine where Claude Code has loaded the plugin from
  a folder. The checks no script can run, because they need a live session, are in [tests/setup/setup-manual-checks.md](tests/setup/setup-manual-checks.md).
- `CHANGELOG.md` is written by release-please from commit messages; do not edit it by hand. Text a
  change removes from a skill is not archived anywhere: git history keeps it.

## License

MIT.
