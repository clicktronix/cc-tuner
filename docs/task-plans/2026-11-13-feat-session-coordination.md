# Sessions of one product see each other — plan

**Spec:** docs/PLANS/2026-11-13-session-coordination.md
**Branch:** feat/session-coordination

## Slice 1 — spike: which surface can stop an action for the agent
Blocked by: none
Owned paths: docs/spike-guard-surface.md,plugins/cc-tuner/tests/flow/CLAUDE_CODE_VERSION
Deciding check: the orchestrator reads docs/spike-guard-surface.md against every checkbox below; each has an `Observed:` line naming the engine version and command
Delivers: a recorded choice between the register.ts module and PreToolUse/PostToolUse hooks, each answer backed by an observation on the engine CI pins

- [ ] a deny reaches the model and the user sees no prompt, in default and in bypass mode
- [ ] how the surface learns its Claude pid for interactive, background and nested `claude -p` sessions, and whether it sees a call's result
- [ ] whether a `CC_TUNER_ACK=` prefix still matches an allow rule like `Bash(git switch:*)`
- [ ] whether SessionEnd fires, the decision latency of each surface, and whether the module can read the record store and `ps`
- [ ] the pin is updated only if a needed observation requires a newer engine

## Slice 2 — sessions see each other
Blocked by: 1
Owned paths: plugins/cc-tuner/scripts/peers.sh,plugins/cc-tuner/tests/flow/test_peers.sh,plugins/cc-tuner/hooks/session-start.sh,plugins/cc-tuner/hooks/hooks.json
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh
Delivers: a session starting next to live peers of its product sees one line about them, and `peers.sh report` / `claim <plan>` show their branches, claims, edited paths and merge-tree conflicts

- [ ] records live and die as the spec says (tombstone 24 h, resume adopts, `/clear` drops acks and claims, flock, malformed record noted)
- [ ] peers are found by repository and by the `product` key of `.claude/cc-tuner-resources.json`
- [ ] merge-tree runs only against same-repository peers and leaves the repository's object store unchanged on a cold cache
- [ ] `claim <plan>` publishes open Owned paths and prints their overlap
- [ ] `peers.sh` renders the whole start line; it appears only with live peers or a task kept at `/clear`, on startup, clear and resume; plan restore still skips resume

## Slice 3 — the guard reads commands and tracks what the session did
Blocked by: 2
Owned paths: plugins/cc-tuner/scripts/peers.sh,plugins/cc-tuner/tests/flow/test_peers.sh,plugins/cc-tuner/hooks/register.ts,plugins/cc-tuner/hooks/register.test.ts,plugins/cc-tuner/hooks/hooks.json,plugins/cc-tuner/tests/flow/test_mod.sh
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh
Delivers: on the chosen surface, every tool call resolves its repository and checkout from its target, and the record learns edited paths and the expected branch after each successful call

- [ ] wrappers (`heavy.sh --`, `bash -c`, `env`, `xargs`, `git -C`, `cd x &&`, `$(...)`) unwrap, each scope keeping its directory
- [ ] a compound command is evaluated step by step (`switch -c x && commit`, `add f && commit`)
- [ ] edited paths are recorded only after a successful call; any call in the checkout except a known read-only one marks the session a writer
- [ ] the expected branch moves only when HEAD changed during this session's own call containing a switch; with HEAD already drifted, a failed or skipped switch keeps it
- [ ] one test drives the shipped adapter end to end; the hook inventory assertion follows any new registration

## Slice 4 — the guard stops what would destroy a peer's checkout or process
Blocked by: 3
Owned paths: plugins/cc-tuner/scripts/peers.sh,plugins/cc-tuner/tests/flow/test_peers.sh,plugins/cc-tuner/hooks/register.ts,plugins/cc-tuner/hooks/register.test.ts
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh
Delivers: the agent gets notes and stops for the checkout, foreign files, the index, branch drift, branch and worktree deletion and kill, each with a short reason and an ack that lets it repeat

- [ ] every checkout, file, index, branch, worktree, stash and kill stop has a stop test and a neighbouring allow test; Bash cases also behind the shell wrappers, git cases behind `git -C`
- [ ] a writer idle over 2 h lifts only the switch stop; a dead peer lifts the liveness-based stops; foreign files stay protected
- [ ] the ack passes one action on one target for 30 min, and nothing else
- [ ] the decision takes at most 150 ms p95 with 10 records

## Slice 5 — shared and exclusive resources
Blocked by: 4
Owned paths: plugins/cc-tuner/scripts/peers.sh,plugins/cc-tuner/tests/flow/test_peers.sh,plugins/cc-tuner/hooks/register.ts,plugins/cc-tuner/hooks/register.test.ts
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh
Delivers: a declared shared resource is not stopped under another live product session, and an exclusive one is used by one session at a time

- [ ] a shared stop command or `TaskStop` is stopped while another product session is live; `/clear` keeps the task and the next start line names it; neither offers an ack for `TaskStop`
- [ ] two simultaneous first users get one lease; a machine resource is leased across products
- [ ] only the current holder's `release` frees a lease; a lease also moves after 10 min of silence and on death; an ack does not pass it
- [ ] a repository without the resources file adds no repository rules; machine resources still apply

## Slice 6 — cc-tuner's texts use it
Blocked by: 5
Owned paths: plugins/cc-tuner/skills/spec,plugins/cc-tuner/skills/run,plugins/cc-tuner/skills/task-flow,plugins/cc-tuner/skills/setup,plugins/cc-tuner/assets/task-flow,plugins/cc-tuner/README.md,plugins/cc-tuner/tests/contract
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: /spec and /run show peers and publish claims, the rule template and task-flow cleanup take a worktree next to another writer, and setup and the README describe the resources file

- [ ] `/spec` runs `report` before approval; `/run` runs `claim` before the first slice, after each tick and before integration
- [ ] the rule template and post-merge cleanup use a worktree when another writer is live; `/run`'s final cleanup leaves a task the guard keeps
- [ ] setup documents both resources files; the README documents the four commands and the ack
- [ ] contract pins cover these texts
