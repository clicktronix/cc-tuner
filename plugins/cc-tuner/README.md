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
can't ship `.claude/rules/*`): a versioned template, repo-specific deltas in an untouched
`task-flow.local.md`, migration of the legacy `git-flow*` files, and a diff-and-ask for a
hand-maintained copy.

Previews, dedicated MCP servers and test containers run as Bash background tasks, which Claude Code
stops when the session exits. A `/clear` does not stop them, so the plugin's hooks module
(`hooks/register.ts`, a Claude Code mod) stops the ones Bash started in the cleared conversation.
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
actual packet coverage and size before dispatch. Four file-local lenses run per shard; Specification
and Architecture each cover the whole candidate. The limit is 18 lenses (four shards) unless the user
raises it in the conversation. The [deep-review procedure](skills/deep-review/SKILL.md) owns the
accepted partition and the line printed before dispatch — lens count, model and effort, with a dollar
figure only from a source the owner can name.


### `verify-feature`

A stage of `/cc-tuner:run`, and a skill you can invoke on its own. It reads the spec's acceptance
criteria and the diff, finds what the repository already provides (test commands, fixtures, runbooks, a
dev server, a database, a browser tool), picks the instrument each behaviour needs, runs it, and
records **what was observed**, each line tagged with its instrument (`[browser]`, `[api]`, `[test]`,
`[cli]`) or marked `NOT PROVED`. Evidence must directly decide the criterion; unproved criteria return
to `/run`. Steps: `skills/verify-feature/SKILL.md`.

## /spec and /run

The task loop has two commands. `/cc-tuner:spec <issue | description>` does the discovery, creates the
task branch, resolves open decisions, confirms the contract and tracer-bullet slices once, then commits
the spec and plan and, when the Task tools are available, publishes the slices as native tasks.
`/cc-tuner:run [--auto] <spec>` works that plan to a merged pull request: it proves each slice
RED→GREEN, reviews the candidate (Matt Pocock review, or `cc-tuner:deep-review` for large or sensitive
changes), obtains the review the spec names (Codex's by default, or none with a recorded reason) at the
exact final SHA, and merges only through `scripts/merge.sh`. Implementation may be handed to
`cc-tuner:slice-unit` subagents, one per slice, capped at `maxTurns: 300` so an over-long slice returns
partial; the parent owns integration, proof, review and every later gate. Procedures:
`skills/spec/SKILL.md`, `skills/run/SKILL.md`.

Without `--auto`, `/run` works through slice commits, push and a draft PR and stops once, before the
merge, which belongs to the user after checked preflight. With `--auto` it runs unattended only while
every gate is green, and never waives incomplete DoR, missing RED→GREEN evidence, failed tests, stale
review, unresolved `[eyes]`, CI that ran and did not pass, or scope beyond the spec. Where a repository
runs no CI at all, the spec says so in advance and a pull-request comment records what stood in for it
for that commit; what a person approves is the **mode**, once, at spec time. After merge it reconciles
only the task lifecycle; deploy, publish and migration remain forbidden. Heavy checks (full suite, e2e,
builds) go through `scripts/heavy.sh`, whose machine-wide slots (`CC_TUNER_HEAVY_SLOTS`, default 1) keep
several sessions from running them at once.

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

cc-tuner registers no global raw-command interceptor, so a raw CLI call, the merge button on
github.com, `git push` and the REST API can all bypass `merge.sh`. It is workflow discipline, not a
local security boundary.

Uses the **mattpocock-skills** plugin for grilling, domain modelling, module design, prototypes, PR
bodies, hard-bug diagnosis and ordinary review, and **cc-codex-triage** for the default `review: codex`
gate (both checked at runtime via prereq-check). Without cc-codex-triage a spec declares
`review: none:<reason>` and the run's owner publishes the verdict; cc-tuner works standalone without
either. Integration rounds outside the review cap and `renew` need cc-codex-triage 0.14+; with an older
companion prereq-check prints a NOTE and `/run` uses a normal round and the companion's reset.

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

The `claude-md-writer`, `task-flow`, `deep-review` and `verify-feature` skills are model-invoked when
their descriptions match; `deep-review` and `verify-feature` are also available directly. The
agent may also start `/cc-tuner:spec` and `/cc-tuner:run` itself when the user asks for a task to be
planned or implemented; `--auto` stays the user's request. `/cc-tuner:setup` remains an explicit
user command: it writes user-global settings.

## Scope

Claude Code only. The plugin writes Claude Code's own surfaces — memory files (CLAUDE.md, `.claude/rules/`, `CLAUDE.local.md`), user settings (statusline), and per-repo rule installs — it does not manage other agents' instruction files.

## Maintaining

- `bash tests/run.sh` (repository root) is the gate. It needs `claude` on PATH at the version pinned in
  `tests/flow/CLAUDE_CODE_VERSION` (CI installs it) to validate and test the hooks module; the
  TypeScript check of that module runs only on a machine where Claude Code has loaded the plugin from
  a folder. The checks no script can run, because they need a live session, are in [tests/setup/setup-manual-checks.md](tests/setup/setup-manual-checks.md).
- `CHANGELOG.md` is written by release-please from commit messages; do not edit it by hand. Text a
  change removes from a skill is not archived anywhere: git history keeps it.

## License

MIT.
