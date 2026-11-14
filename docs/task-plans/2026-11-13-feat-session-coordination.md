# Sessions of one product see each other — plan

**Spec:** docs/ARCHIVE/PLANS/2026-11-13-session-coordination.md
**Branch:** feat/session-coordination

## Slice 1 — spike: which surface can stop an action for the agent
Blocked by: none
Owned paths: docs/spike-guard-surface.md,plugins/cc-tuner/tests/flow/CLAUDE_CODE_VERSION
Deciding check: the orchestrator reads docs/spike-guard-surface.md against every checkbox below; each has an `Observed:` line naming the engine version and command
Delivers: a recorded choice between the register.ts module and PreToolUse/PostToolUse hooks, each answer backed by an observation on the engine CI pins

- [x] a deny reaches the model and the user sees no prompt, in default and in bypass mode
- [x] how the surface learns its Claude pid for interactive, background and nested `claude -p` sessions, and whether it sees a call's result
- [x] whether a `CC_TUNER_ACK=` prefix still matches an allow rule like `Bash(git switch:*)`
- [x] whether SessionEnd fires, the decision latency of each surface, and whether the module can read the record store and `ps`
- [x] the pin is updated only if a needed observation requires a newer engine

Evidence: docs/spike-guard-surface.md → 10 `- Observed:` lines on 2.1.306, decision `register.ts` module; pin unchanged @ 6070ca1

## Slice 2 — sessions see each other
Blocked by: 1
Owned paths: plugins/cc-tuner/scripts/peers.sh,plugins/cc-tuner/tests/flow/test_peers.sh,plugins/cc-tuner/hooks/session-start.sh,plugins/cc-tuner/hooks/hooks.json
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh
Delivers: a session starting next to live peers of its product sees one line about them, and `peers_report` / `claim <plan>` show their branches, claims, edited paths and merge-tree conflicts

- [x] records live and die as the spec says (tombstone 24 h, resume adopts, `/clear` drops acks and claims, flock, malformed record noted)
- [x] peers are found by repository and by the `product` key of `.claude/cc-tuner-resources.json`
- [x] merge-tree runs only against same-repository peers and leaves the repository's object store unchanged on a cold cache
- [x] `claim <plan>` publishes open Owned paths and prints their overlap
- [x] the module renders the whole start line; it appears only with live peers or a task kept at `/clear`, on startup, clear and resume; plan restore still skips resume

Evidence: bash plugins/cc-tuner/tests/flow/test_peers.sh → 87 PASS, 0 FAIL (RED first: `FAIL record-written (want '63617', got '')`); mutate.sh liveness ignores start time → KILLED by `liveness-pid-reuse (a record whose pid was reused reads as live)`, control green; out-of-path: tests/flow/lib.sh exports CC_TUNER_PEERS_DIR into the suite's temp root @ 7adf44c

## Slice 3 — the guard reads commands and tracks what the session did
Blocked by: 2
Owned paths: plugins/cc-tuner/scripts/peers.sh,plugins/cc-tuner/tests/flow/test_peers.sh,plugins/cc-tuner/hooks/register.ts,plugins/cc-tuner/hooks/register.test.ts,plugins/cc-tuner/hooks/hooks.json,plugins/cc-tuner/tests/flow/test_mod.sh
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh
Delivers: the `tool.call` handler in `register.ts` (the Slice 1 choice) resolves every call's repository and checkout from its target through `peers.sh check` (`$.process.run`, pid from its `$PPID`), and the record learns edited paths and the expected branch after each successful call

- [x] wrappers (`heavy.sh --`, `bash -c`, `env`, `xargs`, `git -C`, `cd x &&`, `$(...)`) unwrap, each scope keeping its directory
- [x] a compound command is evaluated step by step (`switch -c x && commit`, `add f && commit`)
- [x] edited paths are recorded only after a successful call; any call in the checkout except a known read-only one marks the session a writer
- [x] the expected branch moves only when HEAD changed during this session's own call containing a switch; with HEAD already drifted, a failed or skipped switch keeps it
- [x] one test drives the shipped adapter end to end; the hook inventory assertion follows any new registration

Evidence: bash plugins/cc-tuner/tests/flow/test_peers.sh → 132 PASS, 0 FAIL incl. `guard-e2e-*` (real `claude -p`, stubbed model API); test_mod.sh → module tests pass (RED first: `FAIL guard-switch-and-commit-moves-the-expectation (want 'x', got 'a')`) @ b9e2cd7
Carry to Slice 4: the writer mark is set in `before` (move it after the decision); verify `$.session.cwd()` follows a Bash `cd` from an earlier call; `check` costs ~105 ms median today.
Closed in Slice 4: `$.session.cwd()` follows a Bash `cd` from an earlier call (probe: `cd sub`, then `pwd`, then `ls`; the module read `repo`, `repo/sub`, `repo/sub` on 2.1.306 and 2.1.323).

## Slice 4 — the guard stops what would destroy a peer's checkout or process
Blocked by: 3
Owned paths: plugins/cc-tuner/scripts/peers.sh,plugins/cc-tuner/tests/flow/test_peers.sh,plugins/cc-tuner/hooks/register.ts,plugins/cc-tuner/hooks/register.test.ts
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh
Delivers: the agent gets notes and stops for the checkout, foreign files, the index, branch drift, branch and worktree deletion and kill, each with a short reason and an ack that lets it repeat

- [x] every checkout, file, index, branch, worktree, stash and kill stop has a stop test and a neighbouring allow test; Bash cases also behind the shell wrappers, git cases behind `git -C`
- [x] a writer idle over 2 h lifts only the switch stop; a dead peer lifts the liveness-based stops; foreign files stay protected
- [x] the ack passes one action on one target for 30 min, and nothing else; the adapter records it and strips the prefix before the call; the reason says re-running is the agent's choice

Evidence: bash plugins/cc-tuner/tests/flow/test_peers.sh → 321 PASS, 1 FAIL `latency (p95 362/497/299 ms per round, want at most 150)` at load 25 on 10 cores; 322 PASS at load 17 (RED first: 106 FAIL, e.g. `FAIL guard-switch-stops-next-to-a-writer (git switch x) (want 'stop', got 'allow')`) @ fc7f108
Latency moved to Slice 5: python per call costs ~68 ms CPU, 0.3–0.5 s under this machine's usual load; owner decision 2026-11-14: rewrite in TS.

## Slice 5 — the guard runs inside the module, in one language
Blocked by: 4
Owned paths: plugins/cc-tuner/scripts/peers.sh,plugins/cc-tuner/hooks/register.ts,plugins/cc-tuner/hooks/peers.ts,plugins/cc-tuner/hooks/register.test.ts,plugins/cc-tuner/hooks/peers.test.ts,plugins/cc-tuner/hooks/session-start.sh,plugins/cc-tuner/hooks/hooks.json,plugins/cc-tuner/tests/flow/test_peers.sh,plugins/cc-tuner/tests/flow/test_mod.sh,plugins/cc-tuner/tests/flow/lib.sh
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh && bash plugins/cc-tuner/tests/flow/test_mod.sh
Delivers: the same records, notes, stops and acks, decided in-process by the module with no python per call, and `report`, `claim` and `release` as tools the module registers
Model: opus — a cross-language port onto an unfamiliar module API in one context

- [x] first, observed on the CI-pinned engine: a `$.tool.register` tool is callable by the agent and by a subagent, `prompt.compose` (or another module path) puts the start line in the context on startup, clear and resume, and the test harness can drive `$.fs`; if one fails, stop and return before porting
- [x] `scripts/peers.sh` is gone; every Slice 2–4 behaviour keeps a passing test, and the liveness mutation (ignore the start time) still kills `liveness-pid-reuse`
- [x] a session writes only its own record, serialized in-process; a process is spawned only for `ps` (cached) and git reads a decision needs
- [x] the decision takes at most 150 ms p95 with 10 records, best of three rounds

Evidence: bash plugins/cc-tuner/tests/flow/test_peers.sh → 35 PASS incl. `PASS latency (p95 104 ms per round over 50 calls with 10 records)` at load 27; test_mod.sh → 55 module tests pass; tsc strict against the 2.1.322 engine types → no errors; mutation `live()` ignores start time → `(fail) liveness-pid-reuse  AssertionError: a record whose pid was reused reads as live` (RED first: `(fail) record-written ... Expected: true Received: false`); gate observed on 2.1.306: tool callable by agent and subagent, start line via `classic.SessionStart` on startup/clear/resume @ 6f25b82

## Slice 6 — shared and exclusive resources
Blocked by: 5
Owned paths: plugins/cc-tuner/hooks/register.ts,plugins/cc-tuner/hooks/peers.ts,plugins/cc-tuner/hooks/register.test.ts,plugins/cc-tuner/hooks/peers.test.ts,plugins/cc-tuner/tests/flow/test_peers.sh
Deciding check: bash plugins/cc-tuner/tests/flow/test_peers.sh && bash plugins/cc-tuner/tests/flow/test_mod.sh
Delivers: a declared shared resource is not stopped under another live product session, and an exclusive one is used by one session at a time

- [x] a shared stop command or `TaskStop` is stopped while another product session is live; `/clear` keeps the task and the next start line names it; neither offers an ack for `TaskStop`
- [x] two simultaneous first users get one lease; a machine resource is leased across products
- [x] only the current holder's `release` frees a lease; a lease also moves after 10 min of silence and on death; an ack does not pass it
- [x] a repository without the resources file adds no repository rules; machine resources still apply

Evidence: bash plugins/cc-tuner/tests/flow/test_peers.sh → rc 0, `PASS resource-lease-first-user-takes-it-with-mkdir`, `PASS resource-shared-stop-reaches-the-model`, `PASS latency (p95 195/204/70 ms per round ...)`; test_mod.sh → module tests pass incl. the lease race and `resource-lease-outside-a-repository`; tsc clean (RED first: `(fail) resource: two simultaneous first users get one lease ... TypeError: sr.peers.lease is not a function`); out-of-path: test_mod.sh inventory line for the other-MCP-tools hook @ 1800caf

## Slice 7 — cc-tuner's texts use it
Blocked by: 6
Owned paths: plugins/cc-tuner/skills/spec,plugins/cc-tuner/skills/run,plugins/cc-tuner/skills/task-flow,plugins/cc-tuner/skills/setup,plugins/cc-tuner/assets/task-flow,plugins/cc-tuner/README.md,plugins/cc-tuner/tests/contract
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: /spec and /run show peers and publish claims, the rule template and task-flow cleanup take a worktree next to another writer, and setup and the README describe the resources file

- [x] `/spec` runs `report` before approval; `/run` runs `claim` before the first slice, after each tick and before integration
- [x] the rule template and post-merge cleanup use a worktree when another writer is live; `/run`'s final cleanup leaves a task the guard keeps
- [x] setup documents both resources files; the README documents the three tools and the ack
- [x] contract pins cover these texts

Evidence: bash plugins/cc-tuner/tests/contract/test_contract.sh → 0 FAIL with 15 new pins (RED first: 15 FAIL, e.g. `FAIL spec-reports-peers-before-approval (missing 'call `mcp__cc-tuner__peers_report`' ...)`); rule template marker v0.23.0 @ 6481e94
Fix after verify-feature: the start line reached no model on Team/Enterprise and managed machines (`classic.SessionStart` skipped by the built-in sec-default); it now rides `prompt.submit` context, and e2e runs under `--managed-settings` (RED first: `FAIL start-line-on-startup`); `kill -0` stopped as a kill, now a probe (RED first: `FAIL guard-kill-signal-0-is-a-probe-and-runs`) → test_peers.sh 48 PASS, module tests pass, tsc clean @ 2723859
Review fixes (deep-review REQUEST_CHANGES on 3cf7c25, 7 lenses): 26 validated items in five groups (no model-chosen binary or git config runs before permission; scope from targets outside a repository; versioned, shape-checked records with visible failures and an unreadable-status stop; nested/resume/reload keep the right record; ack key, discard forms, expected-branch moves and safe-first reasons) → test_peers.sh all PASS, 93 module tests, latency p95 26 ms, mutation still kills `liveness-pid-reuse` @ f2285f0
Owner decisions 2026-11-14 (edit note for foreign dirty files, `"guard": false`, idle peer 8 h, product map in the user file; writer marked before an allowed call) → 98 module tests pass, `bash tests/run.sh` → `cc-tuner validate ok` @ f075a80
