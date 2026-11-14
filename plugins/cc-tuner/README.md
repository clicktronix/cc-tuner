# cc-tuner plugin

Skills that tune Claude Code's own configuration. One install, no per-project copies to drift.

## Skills

### `agent-rules`

Reads the applicable repository rules and linked contracts before a review or change, checking the
actual rule inventory so an outdated index cannot hide a rule. `/cc-tuner:setup install agent-rules`
adds a short loading instruction at the top of the root AGENTS.md (or AGENTS.override.md); `check` is
read-only. Placement rules: the root README.

### `claude-md-writer`

Create, refactor, and audit **CLAUDE.md** and **`.claude/rules/`** memory files, following the official
memory docs (<https://code.claude.com/docs/en/memory>). Triggers when you create, trim or split a
CLAUDE.md, organize instructions into `.claude/rules/`, or decide what belongs in CLAUDE.md vs rules vs
`CLAUDE.local.md` vs tool config. Load order, size targets, imports, auto memory, path-scoped rules
and the verified source list are in the skill's `reference.md`.

### `statusline`

A two-line usage statusline: rate-limit windows (5h / 7d), context-window %, git status, model and
effort, session duration. Plugins can't register a statusline, so the statusline node of
`/cc-tuner:setup` wires it into the user's `settings.json`, offered rather than assumed:

```
/cc-tuner:setup install statusline
```

Sample output, data sources and the unofficial-endpoint caveat: `skills/statusline/SKILL.md`.

### `task-flow`

Canonical git workflow — branch naming, Conventional Commits (incl. breaking
changes), PR verification gates, GitHub Projects board recipes (create-on-board,
field-ID caching, card lifecycle), spec lifecycle (`wiki/PLANS/` → `ARCHIVE`,
`docs/` fallback), and anti-pattern case studies with dated incidents.

The always-on core installs per repo via the task-flow node of `/cc-tuner:setup` (plugins
can't ship `.claude/rules/*`): a versioned template, repo-specific deltas in
`task-flow.local.md`, migration of the legacy `git-flow*` files, and a diff-and-ask for a
hand-maintained copy. Setup manages the local file's delivery block, review opt-out and cached board IDs;
it preserves other content.

Previews, dedicated MCP servers and test containers run as Bash background tasks, which Claude Code
stops when the session exits. A `/clear` does not stop them, so the plugin's hooks module
(`hooks/register.ts`, a Claude Code mod) stops the ones Bash started in the cleared conversation, except a task the guard keeps (see
[Sessions of one product](#sessions-of-one-product)).
The same module refuses a Bash command that would print secret values into the transcript —
`env`, `printenv`, `set`, `export`, `declare` or `typeset` with nothing to run or name, or
`cat`/`head`/`tail`/`less`/`more`/`bat` of a `.env` file — wherever the shell would run it (after
`&&`, in a pipe, a subshell or `$(…)`), reading comments, redirections, quotes and heredocs the way
the shell does, and names commands that answer the same question
without printing a value, even one that spans lines.

### `deep-review`

A read-only review for large, cross-boundary or sensitive candidates, replacing the ordinary
advisory pass. Restricted `cc-tuner:deep-review-lens` agents read owner-prepared diff files; one
owner validates findings and coverage before required Codex review of the final SHA.

The shared `review-diff.sh` reader keeps inventory and packets consistent. `shard-diff.sh` validates
actual packet coverage and size before dispatch. Seven lenses run; with shards, four file-local
lenses run per shard and Specification, Architecture and Blind spots each cover the whole candidate.
Blind spots asks what the user and the spec did not consider (unwalked scenarios, business-logic
holes, simpler alternatives); its findings are questions for the owner, never blockers. Architecture,
Security and Blind spots run on Opus, the rest on Sonnet. Past 19 lenses (four shards) the owner asks
the user whether to run them all, cut to the limit, or re-shard. The
[deep-review procedure](skills/deep-review/SKILL.md) owns the accepted partition and the line printed
before dispatch — lens count by model and effort, with a dollar figure only from a source the owner
can name.


### `verify-feature`

A stage of `/cc-tuner:run`, and a skill you can invoke on its own. It reads the spec's acceptance
criteria and the diff, finds what the repository already provides (test commands, fixtures, runbooks, a
dev server, a database, a browser tool), picks the instrument each behaviour needs, runs it, and
records **what was observed**, each line tagged with its instrument (`[browser]`, `[api]`, `[test]`,
`[cli]`) or marked `NOT PROVED`. Evidence must directly decide the criterion; unproved criteria return
to `/run`, which runs this stage in a Sonnet subagent and takes back only the record. Steps:
`skills/verify-feature/SKILL.md`.

## /spec and /run

The task loop has two commands. `/cc-tuner:spec <issue | description>` does the discovery, creates the
task branch, resolves open decisions, has a read-only Opus agent look for Blind spots in the draft (its
questions go to the user), confirms the contract and tracer-bullet slices once, then commits the spec
and plan, puts the issue's card on the board, and, when the Task tools are available, publishes the
slices as native tasks. `/cc-tuner:spec --groom <issue>` does the discovery and the interview only and
records the decisions in the issue, with no branch, spec or plan; a later `/cc-tuner:spec <issue>`
builds on that record.
`/cc-tuner:run [--auto] <spec>` works that plan to a merged pull request: it proves each slice
RED→GREEN, reviews the candidate (Matt Pocock review, or `cc-tuner:deep-review` for large or sensitive
changes), obtains the review the spec names (Codex's by default, or none with a recorded reason) at the
exact final SHA, and on GitHub merges only through `scripts/merge.sh` (other hosts: see Delivery routes
below). Where the spec names a board, `/run` moves the card to In Progress, In review and Done as it goes,
and the epic's card with its first and last sub-issue. Implementation may be handed to
`cc-tuner:slice-unit` subagents, one per slice, capped at `maxTurns: 300` so an over-long slice returns
partial; the parent owns integration, proof, review and every later gate. Procedures:
`skills/spec/SKILL.md`, `skills/run/SKILL.md`.

`/run` continues through slice commits, push and a draft PR/MR. Merge requires `--auto` or an explicit
user instruction for that delivery; otherwise it hands over the checked candidate and command.
Unattended execution continues only while
every gate is green, and never waives incomplete DoR, missing RED→GREEN evidence, failed tests, stale
review, unresolved `[eyes]`, CI that ran and did not pass, or scope beyond the spec. Where a repository
runs no CI at all, the spec says so in advance and a pull-request comment records what stood in for it
for that commit; what a person approves is the **mode**, once, at spec time. After merge it reconciles
only the task lifecycle; deploy, publish and migration remain forbidden. Heavy checks (full suite, e2e,
builds) go through `scripts/heavy.sh`, whose machine-wide slots limit how many run at once across
sessions: one slot per 8 GB of RAM (at least 1), an e2e run holds two, waiters start in arrival order (an older heavy.sh may overtake),
and a check waits while the system reports memory pressure, at most `CC_TUNER_HEAVY_MEM_WAIT` seconds
(default 600), then starts with a warning. `CC_TUNER_HEAVY_SLOTS` overrides the slot count, in slots of weight; set it user-wide,
since sessions with different values see different capacities.

Run progress lives in the committed plan file (its `- [x]` ticks) and in Claude Code's task list; there
is no state file. The task list survives `/compact` and resume unchanged. A new session (`startup` or
`/clear`) starts with an empty list, and a `SessionStart` hook asks the agent to rebuild it from the
plan, emitting the unfinished slices with their blocking edges. It only asks: a command hook cannot call
`TaskCreate`.

One thing checks rather than advises. `scripts/merge.sh [--ci <mode>] <pr> <squash|merge>
<candidate-sha> [review-thread]` re-reads the companion's exact-candidate approval, the public verdict,
CI and the head SHA, refuses unless they agree at that commit, and pins the head with
`--match-head-commit`. `--ci` says which checks answer for CI: GitHub's required ones by default
(`required` does not look at optional checks, so require an optional check on the branch or declare
`any` where it matters), every reported one with `any`, or none where the repository runs none, which
needs a PR comment recording the local result for the same commit. No mode lets a check it reads fail.
A pull request with neither a plan nor a named review is refused, drafts are refused until marked ready,
and `--unmanaged` merges only an ordinary pull request outside a run.

cc-tuner's hooks see only the agent's own tool calls, so a raw CLI call, the merge button on
github.com, `git push` and the REST API can all bypass `merge.sh`. It is workflow discipline, not a
local security boundary.

### Delivery routes and the tracker

`/spec` records the repository's `host:` (`github`, `gitlab`, `local` for no remote, or `other`), which
`scripts/setup/host.sh` reads from the remote URL without a network call; `/run` checks it again. On GitHub
delivery is `merge.sh`. On GitLab and with no remote, `/run` follows a delivery route shipped with the plugin
(`skills/run/references/route-<host>.md`), so a candidate cannot edit its own gate; on another host the
route is the user's own description. The repository keeps only a short key block in
`.claude/rules/task-flow.local.md`, written by `/cc-tuner:setup install delivery-route` and checked by
`scripts/setup/route.sh`: `/run` stops when it is missing or wrong. A route keeps the gate's order and
records, but the agent performs its steps, so no script refuses on its behalf.

Where issues live comes from `docs/agents/issue-tracker.md`, which `/setup-matt-pocock-skills` writes; the
spec's `tracker:` is `gh`, `glab`, `local` (markdown files under `.scratch/`), `other` or `none`. `/spec`
asks once when the file is absent. Boards stay GitHub-only.

### Sessions of one product

The hooks module keeps one record per live Claude session in `~/.cache/cc-tuner/sessions`, so sessions in
one repository, or in repositories sharing a `product` key, see each other. Before every tool call a guard
allows, notes or stops. A stop names the peer, what would be lost and one way on; the agent picks it, and
the user is never asked.

- **Stops:** a branch switch in a checkout another session writes in; discarding or committing files this
  session did not edit (`reset --hard`, `stash`, `clean`, `restore`, `commit -a`, `add -A`); commit, push
  or PR from a branch other than the one the session started on; deleting a peer's branch or removing its
  worktree; a shared resource's stop command, or `TaskStop` of its start, while another product session is
  live; an exclusive resource leased to another session; `kill` of a peer's process.
- **Notes**, and the action runs: an edit in a checkout with another writer or of a path a peer claimed; a
  branch switch where a peer's cwd is.

A Bash stop is passed by running the same command prefixed `CC_TUNER_ACK=<key>` (the key is in the reason).
The ack covers one action on one target for 30 minutes, and the prefix is stripped before the command runs.
Lease and `TaskStop` stops have no ack: wait, or `SendMessage` the holder.

Three tools, `mcp__cc-tuner__peers_*`:

- `peers_report` lists the product's live peers with branch, claims and edited paths, and for peers in the
  same repository the `git merge-tree` conflicts of HEAD against their branch. `/spec` calls it before the
  approval.
- `peers_claim <plan>` publishes the plan's open Owned paths as this session's claim, then reports their
  overlap with peers. `/run` calls it before the first slice, after each tick and before integration.
- `peers_release <key>` gives up an exclusive resource lease; so do 10 minutes of silence and the holder's
  death.

Resources are declared, never detected. `.claude/cc-tuner-resources.json` holds the repository's:

```json
{"product": "shop", "resources": [{"key": "stack", "kind": "shared", "start": ["pnpm stack:up"], "stop": ["pnpm stack:down"]}]}
```

`~/.config/cc-tuner/resources.json` holds the machine's, checked across products:

```json
{"resources": [{"key": "chrome", "kind": "exclusive", "tools": ["mcp__chrome-devtools__*"]}]}
```

A `shared` resource stays up while another session of the product is live; an `exclusive` one is leased to
its first user. Setup writes them only when asked.

The user file may also map repositories to products, `"products": {"shop": ["~/code/shop-api", "~/code/shop-web"]}`,
which covers every branch and worktree. `"guard": false` in either file turns the guard off there. A
session idle for 8 h blocks nothing that depends only on its being alive; its uncommitted files stay protected.

Known limits: a peer's liveness is cached for a minute. A kept task survives `/clear` and `/run`'s final
cleanup, not the exit of the Claude process, which stops its background tasks itself.

### Companions

**mattpocock-skills** is required by `/spec` and `/run`: grilling, domain modelling, module design,
prototypes, PR bodies, hard-bug diagnosis and ordinary review. **cc-codex-triage** is optional: it
supplies the default `review: codex` gate and needs a logged-in Codex CLI (`codex login`); without it a
spec declares `review: none:<reason>` and the run's owner publishes the verdict. `/cc-tuner:setup install`
installs accepted companions after one confirmation, and prereq-check reports what is missing. `scripts/setup/companion.sh`
owns the companion table, the Codex check and the recorded opt-out. Integration rounds
outside the review cap and `renew` need cc-codex-triage 0.14+; with an older companion prereq-check
prints a NOTE and `/run` uses a normal round and the companion's reset.

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
