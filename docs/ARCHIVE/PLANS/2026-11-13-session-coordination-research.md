# cc-tuner #73 — Coordinate concurrent sessions working on the same product: research

Date: 2026-11-13. Base: cc-tuner `origin/main` = `bc3b965`. Claude Code 2.1.323.
Input for `/cc-tuner:spec 73`; facts only, design questions at the end.

## 1. Field data (last 30 days, 134 Claude + 132 Codex sessions, estimates)

| Product | Hours with ≥2 sessions | Max concurrent | Max branches at once | Sessions main checkout / worktree | Hours ≥2 in one directory |
|---|---|---|---|---|---|
| product A | 68 of 205 | 8 | 4 | 17 / 54 | 43 |
| product B | 41 of 221 | 8 | 4 | 33 / 28 | 24 |
| product C (work) | 107 of 229 | 7 | 3 | 16 / 38 | 105 (least reliable) |
| a notes repository | 11 of 48 | 5 | 1 | 25 / 0 | 11 |
| cc-tuner family | 2.4 of 4.2 | 9 | 3 | 15 / 4 | 2.4 |

Live snapshot 2026-11-13: three interactive sessions share one repository of product A.

What actually collided (10 transcript events): a foreign WIP in the main checkout (product A
analyzer, ~19 files); a PR opened from the wrong branch because another session had switched the
shared checkout; `stack:down` removed a Supabase stack another session started; a `next dev`
supervisor held the heavy slot ~6 h; a lint error in another agent's spec; a merge conflict in a
skill both sides edited; shared Chrome :9222; uv cache lock across products.

Conclusions: contention is mostly over **checkout/branch state and local resources**, less over
the same file; about a third of concurrent time is several sessions in **one directory**, so
worktree-only coordination misses it; a **product spans repositories** (product A platform/agent/analyzer, product B frontend/backend run concurrently 7–10 h, paired PRs).

## 2. Platform (code.claude.com docs + local checks)

- `claude agents --json` (no TTY) lists **every** live session on the machine, interactive and
  background: `id, sessionId, name, cwd, kind, state, startedAt`. Verified locally: 15 entries.
  A script can answer "which sessions of this product are alive" without the model.
- `CLAUDE_CODE_SESSION_ID` is set in Bash and hook subprocesses and equals the hooks' `session_id`
  (changes on `/clear`). The session name is not in the env.
- `ListAgents`/`SendMessage`: on by default from 2.1.224; machine-wide; idle receiver gets a new
  turn; receiver queue 50; held messages up to 100; `crossSessionInbound` accept/hold/refuse;
  bypass-mode receivers hold messages from non-bypass senders. `SendMessage` is denied in
  a notes repository `settings.local.json:16`; this session lists peers but cannot send.
- Socket: `CLAUDE_CODE_MESSAGING_SOCKET`/`TOKEN` reach hooks and Bash, but only posting to the
  session's **own** socket is documented; the payload format and a peer's socket are not. A script
  cannot wake a peer; only the model can, via `SendMessage`.
- Hooks: `PreToolUse` on Edit/Write gets the absolute `file_path`, can `ask`/`deny` or add
  `additionalContext`; `SessionStart` fires on startup/resume/clear/compact/fork (cc-tuner
  registers `startup|clear` only); `SessionEnd` has a 1.5 s default timeout; `UserPromptSubmit`
  also fires for incoming peer messages; `WorktreeCreate` does not fire for `git worktree add`.
- Agent teams: experimental, one team per lead session, task-claim lock only; the docs say two
  teammates editing one file overwrite each other. Not usable across independent sessions.
- Codex sessions are invisible to `claude agents`; anything they hold needs a TTL.

## 3. cc-tuner today

- No state in the git common dir. cc-codex-triage keeps thread state per worktree
  (`git rev-parse --absolute-git-dir`), explicitly not shared between checkouts.
- Reusable patterns: heavy.sh (flock slots, locked tickets created by rename, `caller_gone`);
  cc-codex-triage `dir-lock.sh` (mkdir + PID owner). The heavy-capacity spec rejected messaging
  between sessions: "kernel locks already coordinate and survive a crashed session".
- `plan-lint.sh` Owned paths: comma-separated literal repo-relative paths or directory prefixes, no
  globs; overlap is a prefix test after normalising to a trailing `/`; checked only within one plan
  and its `--active` set. The union of open slices' Owned paths is a ready-made claim.
- Natural check points: `run` "Before starting" after plan resolve/lint (`run/SKILL.md:65-92`),
  the loop's `ready-batches` call (`:96-105`), `spec` section 6 approval (`spec/SKILL.md:207-224`).
- The only cross-session signal today is the board card's Status (GitHub only).
- Identifiers available: branch, plan/spec path, issue number, Codex thread; no session id used.
- Tests: bash 3.2, python3 stdlib, `CC_TUNER_*` seams, `tests/run.sh` gate.

## 4. Prior art

- MCP Agent Mail: advisory leases (paths/globs, exclusive flag, TTL + explicit renew, logged
  force-release); the grant succeeds and returns a conflict list; one JSON per reservation;
  rename-aware pre-commit guard with a `warn` mode. Copy the record and the guard, not the server.
- Clash: pairwise `git merge-tree` over `git worktree list` plus a `PreToolUse` hook. Grove: hunk-
  and symbol-level overlap, daemon. Worktree orchestrators (claude-squad, Conductor, Crystal, Vibe
  Kanban, uzi, container-use, Sculptor) document no overlap detection.
- `git merge-tree --write-tree --name-only --quiet A B`: exit 1 means conflict; sees committed work
  only, N(N-1)/2 pairs.

## 5. Deepening (2026-11-13, second pass)

### Committed-work overlap: `git merge-tree` on live branches

Five repositories (product A platform/agent/analyzer, product B frontend/backend), git 2.52, active =
branch tip in the last 7 days or a worktree HEAD; objects written to a temp dir via alternates,
loose-object counts unchanged before/after.

| Repo | Active | Dirty active worktrees | Pairs | Conflicting | File-overlap pairs | merge-tree median / max |
|---|---|---|---|---|---|---|
| A/platform | 8 | 1 (18 files) | 28 | 20 | 21 | 0.19 / 0.62 s |
| A/agent | 2 | 1 (3) | 1 | 1 | 1 | 0.40 s |
| B/frontend | 6 | 0 (main checkout: 26 files) | 15 | 8 | 10 | 0.10 / 0.25 s |
| B/backend | 20 | 10 (145) | 190 | 62 | 119 | 0.04 / 1.42 s |

- One session checking itself against N active branches is O(N): 0.4–6 s for 2–8 branches. The
  full matrix (234 pairs) took 53 s, an audit cost, not a checkpoint cost.
- File overlap is a poor proxy: 100 of 151 overlapping pairs merge cleanly (mostly shared
  ancestors on a stack), and 40 of 91 conflicting pairs share no file in diffs against the default
  tip (divergent bases; plausible explanation, not proven).
- Hot spots are generated or shared registries: shared generated catalogs (`contracts/*.json`), i18n locale files, `_generated/*`. A backup branch conflicts with
  almost everything: noise needs a filter (detached review/stage worktrees, backup branches).
- 166 uncommitted files across 12 of 37 active branches, plus 27 in main checkouts: merge-tree
  cannot see them, so committed overlap needs a second signal for work in progress.

### Discovery and wake-up (Codex research, thread `cc-tuner-73-research`, checked locally)

- `claude agents --json` exists since 2.1.145 (`--all`, `id`, `state` in 2.1.169). Verified:
  interactive entries carry `pid, sessionId, cwd, status, startedAt, name, kind` and no `id`;
  background entries carry `id` and `state`. `--cwd` filters background sessions only.
- `sessionId` changes on `/clear`; resume can switch conversation. Codex recommends a claim keyed
  by its own participant id plus pid and process start time, with the conversation id as a mutable
  attribute. Not tested here.
- Inbox socket (static reading of the 2.1.323 binary plus a third-party implementation,
  github.com/PeterSR/claude-code-socket-transport): NDJSON
  `{"msgV":1,"msg_id","type":"user","message":{"role":"user","content"},"priority","session_id","from"}`.
  The token is checked against the receiver's own tokens, so a peer cannot authenticate; on
  macOS/Linux an unauthenticated peer message is still accepted under the inbound rules (a
  bypass-mode receiver holds it). Receipts arrive asynchronously. Undocumented payload, so a
  script → peer send depends on an internal format. Not exercised.
- Documented alternative: a recipient-side hook with `asyncRewake: true` runs in the background
  and wakes Claude on exit code 2 with its stderr as a system reminder (hooks.md:454); `timeout`
  still applies (hooks.md:4179), so a watcher must re-arm. Which event arms it and the maximum
  timeout were not checked.
- Codex 0.167.2: no JSON list of live sessions (`codex agents` is a TUI; app-server
  `thread/loaded/list` covers one app-server only); `codex queue --thread <id> --message` wakes a
  loaded idle thread; `SessionStart` and `PreToolUse` hooks exist (need trust).
- A wake starts a paid turn in the peer.

## 6. What communication is worth building (debate with Codex, thread `cc-tuner-73-research`)

Agreed after one round (Claude's opening position was written before Codex's reply):

- The record is the truth; any message only points at a record change. Pull is the default,
  push publishes a changed fact, a wake needs a receiver that declared it is waiting for it.
- The record describes intent and dependencies: participant id (pid + start time), product and
  its repositories, checkout/worktree, branch/HEAD, Owned paths, resources held **or used**,
  consumed contracts/refs, `waiting_for`, freshness.
- Value sits in guards at the action point, not in chat. A pre-commit guard is too late for a
  shared checkout: the foreign file may already be overwritten.
- The receiver decides relevance in a script, before any model turn; the sender is responsible
  only for the fact being right and cannot mark everything urgent. Deduplicate by event and
  revision.
- Not worth building: progress broadcast, an LLM judging each event, fixing a peer's lint
  automatically, a wake per commit, automatic takeover of an expired claim.

What changed Claude's position:

- **Waking.** A permanent per-session `asyncRewake` watcher gives way to a bounded watcher armed
  only for an explicit `waiting_for`.
- **A merge into the target that conflicts with a peer's branch** needs no wake. The active peer
  sees the delta at its next hook, and an idle peer at its next checkpoint.
- **A dead holder** releases the claim, not the resource. Resources track consumers, because
  `stack:down` stays dangerous after the creator leaves.

New point from Codex:

- **One write-owner per checkout.** Disjoint Owned paths do not protect a shared HEAD/index, so a
  second writer in the same directory needs a worktree; readers may share it. This matches
  placement.md:18 for units, but it would change how the user works today: about a third of
  concurrent time is spent in one directory. **This is an owner decision.**

Ranked use cases, with the paid wake-turns each is expected to cost:

| # | Use case | Trigger | Channel | Relevance decided by | Wakes |
|---|---|---|---|---|---|
| 1 | Protect checkout/WIP | a second writer, branch drift, or an unknown dirty file before a mutation or PR | record + hook guard | a local guard, by checkout and expected branch | 0 |
| 2 | Protect a shared resource | stop, remove or reconfigure a stack, port or cache that is in use | record + hook guard; an addressed request to the holder when blocked | the resource key and its consumers | 0, or 1 when a decision is needed |
| 3 | Keep cross-repo dependencies | a prerequisite becomes ready; a branch or ref that is in use is deleted | record + cleanup guard; a wake for a waiting consumer | the dependency declared in the spec or claim, ready at a SHA | 0 if active, 1 if idle and waiting |
| 4 | Warn of an integration conflict | Owned paths or a shared registry overlap; a pair's SHA changed | record + merge-tree cached per SHA pair; a guard before integration | path overlap and the concrete pair | 0 |
| 5 | Hand over useful diagnostics | a reproducible foreign failure, or an answer to a registered question | record; a wake only on subscription | the owner or consumer, with the SHA still current | ≤1 |

Machine-scoped resources (Chrome debug port, uv cache) cross products. `heavy.sh` keeps owning
capacity admission.

## 7. Questions for the spec

1. What is claimed: declared paths (Owned paths of open slices), the checkout/branch a session
   works in, local resources (stack, port, browser), or a mix. Field data weighs checkout and
   resources over files.
2. Product key: one repository's git common dir, or a product root spanning sibling repositories
   (product A, product B).
3. Declared vs derived: explicit claims written by `/spec`/`/run`, or derived from live sessions'
   cwd, branch, dirty files and branch diff, or attributed edits recorded by a hook. Many sessions
   are ad hoc and never run `/run`.
4. Enforcement: report at spec/run checkpoints, `PreToolUse` warn/ask on Edit/Write, a guard
   before branch switch/PR in a shared checkout, or a pre-commit guard.
5. Liveness: `claude agents --json` pid membership (pid + start time) for Claude sessions; TTL
   for Codex, which has no machine-wide list.
6. Wake-up: none (peers learn at their next hook or checkpoint), `SendMessage` from the model,
   a recipient-side `asyncRewake` watcher, or a direct socket write (undocumented payload).
7. Committed overlap: run `git merge-tree` of this branch against each active peer branch at
   checkpoints (O(N), seconds) as the signal for committed work, with claims or dirty paths
   covering uncommitted work; filter for stack, review and backup branches.
8. Checkout policy: one write-owner per checkout (a second writer must take a worktree) versus
   guarded sharing of one directory.
9. Resource scope: per-product versus machine-wide keys (Chrome port, uv cache), and whether
   resources are declared by the session or detected.
10. Side finding: a long-running dev server inside `heavy.sh` held a slot for ~6 h (2026-11-01,
   before #72). Not in #73's scope.
