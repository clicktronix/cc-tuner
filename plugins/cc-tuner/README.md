# cc-tuner plugin

Skills that tune Claude Code's own configuration. One install, no per-project copies to drift.

## Skills

### `agent-rules`

Read the applicable repository rules and linked contracts before reviewing or changing code.
The skill follows the project's index and checks the actual rule inventory so newly added rules
are not hidden by an outdated table. `/cc-tuner:setup install agent-rules` adds a short portable
loading instruction at the start of the root AGENTS.md (or AGENTS.override.md), without copying
rules or generating per-repository skills. The block precedes the file's own heading so the
instruction budget cannot truncate it. `check` is read-only and separates a missing block from a
late one; repeated installation is a no-op.


### `claude-md-writer`

Create, refactor, and audit **CLAUDE.md** and **`.claude/rules/`** memory files for Claude Code, following the official memory docs (<https://code.claude.com/docs/en/memory>). Triggers when you create/trim/split a CLAUDE.md, organize instructions into `.claude/rules/`, or decide what belongs in CLAUDE.md vs rules vs `CLAUDE.local.md` vs tool config.

What it covers (Claude Code memory facts checked against the docs):

- **CLAUDE.md < 200 lines** — the only published size target; loads every session.
- **`paths:` frontmatter only on `.claude/rules/*.md`**, never on CLAUDE.md (CLAUDE.md loads by directory hierarchy; conditional loading is a rules-file feature).
- **Documented load order** — managed → user → project → local; files are concatenated, not overriding, and conflicts are resolved arbitrarily (so the fix is to remove conflicts, not lean on precedence). Rules and subdirectory CLAUDE.md are separate mechanisms, not precedence tiers.
- **Code style / conventions belong in CLAUDE.md** (the docs' own example is "use 2-space indent"); only hard *blocks* go to hooks/settings.
- Correct details on **imports** (max 4 hops), **auto memory** (`MEMORY.md`, first 200 lines / 25 KB, machine-local), **path-scoped rules** (trigger on read; user-level rules *do* load), **monorepo** (`claudeMdExcludes`), and **HTML-comment stripping**.

Deep examples and the verified source list are in the skill's `reference.md`.

### `statusline`

A two-line usage-focused statusline for Claude Code:

```
➜ my-project git:(main) S:2 M:1 U:4 | Opus 4.8 xhigh | 1h12m
 | 5h:66%[▓▓▓▓▓░░░]>23:30  7d:9%[▓░░░░░░░]>17:00 | ctx:8%[▓░░░░░░░░░]
```

Rate-limit windows (5h / 7d utilization + reset time), context-window %, git branch with
staged/modified/untracked counts, model + reasoning effort, and session duration. Bars go
green → yellow (≥50%) → red (≥80%). Cross-platform (macOS Keychain, Linux/Windows
`~/.claude/.credentials.json`).

Plugins can't register a statusline themselves, so the statusline node of `/cc-tuner:setup`
wires it into the user's `settings.json` — offered, not assumed:

```
/cc-tuner:setup install statusline    # the node; /cc-tuner:statusline-setup forwards here for one release
```

The 5h/7d data uses Claude Code's **unofficial** OAuth usage endpoint — it degrades
silently if that ever breaks. The OAuth token is read locally and only sent to
`api.anthropic.com`.

### `task-flow`

Canonical git workflow — branch naming, Conventional Commits (incl. breaking
changes), PR verification gates, GitHub Projects board recipes (create-on-board,
field-ID caching, card lifecycle), spec lifecycle (`wiki/PLANS/` → `ARCHIVE`,
`docs/` fallback), and anti-pattern case studies with dated incidents.

The always-on core installs per repo via the task-flow node of `/cc-tuner:setup` (plugins
can't ship `.claude/rules/*`): a versioned template, repo-specific deltas in an untouched
`task-flow.local.md`, migration of the legacy `git-flow*` files, and a diff-and-ask for a
hand-maintained copy. `/cc-tuner:task-flow-setup` forwards to the node for one release.

### `deep-review`

A read-only exhaustive review for large, cross-boundary, or sensitive candidates. It fans out six
independent lenses against one immutable SHA, then validates and deduplicates their output without a
top-ten cap. It replaces the ordinary Matt Pocock advisory pass for these candidates. Both routes
then use the required Codex review of the final SHA.

### `verify-feature`

A stage of `/cc-tuner:run`, and a skill you can invoke on its own. It answers one question — what
would show this change working, and did it? — from the change in front of it:

1. read the spec's acceptance criteria and the diff;
2. find what this repository already has: test commands, fixtures, testing runbooks, and what can
   actually be driven right now (a dev server, a database, a browser tool, a CLI);
3. choose the instrument per behaviour — a screen is opened and interacted with, an endpoint gets a
   real request, a schema change is applied to a disposable copy and its data and constraints read,
   a calculation gets the inputs that used to be wrong;
4. run it and record **what was observed**, not that it works.

Evidence must directly decide the criterion: lint can prove formatting, an approved non-code diff
check can prove a documentation edit, and an existing test can prove the behaviour it exercises.
Reuse valid observations rather than repeating the same command at every stage. Unrelated static
checks do not prove runtime behaviour; unproved criteria return to `/run` for handling.

This replaced an opt-in Stop-hook gate that classified changes by file path and demanded a fixed proof
per class. Paths do not know what a change does — a `.tsx` file can be a pure formatter and a `.sql`
file a comment — so the gate asked for the wrong evidence about as often as the right one, and the
part that mattered, deciding what would actually prove this behaviour, was never expressible in a
regex.

## /spec and /run

The task loop has two commands. `/cc-tuner:spec` does the discovery, creates the task branch, confirms
the contract and vertical slices once, then commits the spec and plan and — when the Task tools are
available — publishes the slices as native tasks. `/cc-tuner:run` works that plan to a merged pull
request; `--auto` removes its delivery stops when the spec is auto-ready.

`/cc-tuner:spec <issue | description>` does all the discovery and planning. It reads the repo, issue, architecture,
code, tests, and consumers, resolves open decisions with `mattpocock-skills:grilling` and uses
`mattpocock-skills:domain-modeling` when vocabulary needs work. It drafts an executable contract. Its DoR names the observed
baseline, first failing check and expected failure, targeted/full checks, environment and data. Every
acceptance criterion names its deciding machine or human step; every `[eyes]` item records a machine
replacement or waiver. Its DoD binds verification, reviews, PR head, and CI to the same candidate.
It presents that contract and its tracer-bullet slices for one approval, writes both artifacts,
validates the plan, commits the reviewed artifacts together, then publishes native tasks in two passes because `TaskCreate`
takes no dependency argument.

`/cc-tuner:run [--auto] <spec>` works that plan. It asks the plan linter for the first safe ready
batch, proves each slice
RED→GREEN and runs the negative proof its spec assigned — a mutation where the spec asked for one —
ticks it off in the committed file, synchronizes an advanced target and archives the spec before
candidate review. It chooses Matt Pocock review for ordinary changes or `cc-tuner:deep-review` for
large or sensitive changes, then obtains Codex's required review
at the exact final SHA. It publishes the final approval as a pull-request review and merges only with green CI on that same
commit — under the mode the spec declared — and `--match-head-commit` pinning it. Implementation may
be handed to subagents the run dispatches itself, one per slice; the parent owns integration, the
proof, the review and every later gate.

Without `--auto`, `/run` works local slice commits without interruption, then stops before the first
push/PR unless already authorized; merge belongs to the user after checked preflight. Real unresolved
decisions or waivers block only dependent work. With `--auto`, it runs unattended
only while every gate is green. `--auto` never waives incomplete DoR, missing RED→GREEN
evidence, failed tests, stale review, unresolved `[eyes]`, CI that ran and did not pass, or scope
beyond the spec. Where a repository runs no CI at all, the spec has to say so in advance and a pull-request comment has
to record what stood in for it, naming that commit. That record is an attributable claim, not a check:
under `--auto` the unattended run writes it about its own work, so what a person approved is the
**mode**, once, at spec time — not each merge's claim. A merge with nothing written down is still
refused. After merge it may reconcile only the task lifecycle; deploy, publish, and migration remain
forbidden.

These replace `/cc-tuner:execute-task`, which tried to do both jobs in one pipeline and could do
neither well: its intake step was marked "human gate, always", so full autonomy was structurally
impossible, while the interactive work was compressed into one step of ten.

Run progress lives in the committed plan file and in Claude Code's own task list. There is no state
file: the plan's `- [x]` ticks are the record that survives a session, the task list is the record
that is visible inside one, and `git` and `gh` hold the delivery facts. Nothing keeps a second copy.

The task list survives `/compact` and resume unchanged, which was measured, so nothing is restored
there. A genuinely new session — `startup` or `/clear` — starts with an empty list, and a
`SessionStart` hook asks the agent to rebuild it from the plan, emitting the unfinished slices with
their blocking edges and every finished slice they still depend on. It asks: a command hook cannot
call `TaskCreate`, so recovery is advisory in exactly the way the plan itself is.

One thing checks rather than advises. `scripts/merge.sh [--ci <mode>] <pr> <squash|merge>
<candidate-sha> [review-thread]` re-reads the companion's exact-candidate approval, the public verdict,
CI and the head SHA, refuses unless they agree at that commit, and pins the head with
`--match-head-commit` so it cannot move between the check and the merge. `--ci` says which checks
answer for CI — GitHub's required ones by default, every reported one where a repository has no branch
protection, or none at all where it runs none, and that last one only alongside a PR comment
recording the local result for the same commit. No mode lets a check it reads fail — and each mode
says which checks it reads: `required` asks GitHub for the required ones and does not look at the
rest, so a failing optional check does not block a merge under it. Where an optional check matters,
require it on the branch or declare `any`. On a pull request that
carries no cc-tuner plan it merges straight through: the plugin must not seize work that is not its own.

`/run` invokes that script directly. cc-tuner does not register a global raw-command interceptor:
earlier versions tried to judge arbitrary Bash text and alternated between bypasses and blocking
unrelated merges. A raw CLI call, the merge button on github.com, `git push` and the REST API can all
bypass this checked path. It is workflow discipline, not a local security boundary.

Requires the **mattpocock-skills** and **cc-codex-triage** plugins (checked at runtime via prereq-check;
cc-tuner installs and works standalone without them).

## Output style

`Mechanism First` (`output-styles/mechanism-first.md`) ships with the plugin and appears in the
`/config` picker once cc-tuner is enabled. It makes answers lead with the mechanism behind a result
rather than a list of steps, draw ASCII diagrams for boundaries, pipelines and ownership seams, keep
issue and PR references in `<identifier> — <title>` form, and translate into the user's language
without transliterating English terms. It sets `keep-coding-instructions: true`, so Claude Code's own
engineering instructions stay in place.

Nothing installs it: pick it in `/config` → Output style, then `/clear`, since the style is read once
at session start. The plugin does not set `force-for-plugin` — which style you run is your choice,
not the plugin's.

## Install

```
/plugin marketplace add clicktronix/cc-tuner
/plugin install cc-tuner@cc-tuner
```

The `claude-md-writer`, `task-flow`, `deep-review` and `verify-feature` skills are model-invoked when
their descriptions match; `deep-review` and `verify-feature` are also available directly. The
setup and lifecycle playbooks remain explicit user commands: `/cc-tuner:setup` (every installer
is a node of it; the old `task-flow-setup` and `statusline-setup` entry points forward for one
release), `/cc-tuner:spec` and `/cc-tuner:run`.

## Scope

Claude Code only. The plugin writes Claude Code's own surfaces — memory files (CLAUDE.md, `.claude/rules/`, `CLAUDE.local.md`), user settings (statusline), and per-repo rule installs — it does not manage other agents' instruction files.

## License

MIT.
