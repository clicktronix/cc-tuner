# Sessions of one product see each other and do not break each other's work

**Goal:** a Claude Code session knows which live sessions work on its product (branch, checkout,
claims) and which of their branches conflict with its own. An action that would destroy state it
does not own is stopped with a reason addressed to the agent, which decides what to do. The guard
never asks the user; for files of unknown owner the reason says they may be the user's.
**Issue:** #73
**Sources:** [research and debate](2026-11-13-session-coordination-research.md); owner decisions
2026-11-13 (three grilling rounds, one blind-spots round); Codex plan review, thread
`cc-tuner-73-plan`.

**Architecture:**

- **Record.** The hooks module (`plugins/cc-tuner/hooks/peers.ts`, imported by `register.ts`) keeps one
  JSON per Claude session in `~/.cache/cc-tuner/sessions`. One language: the owner chose TS over a
  python helper on 2026-11-14 after python per call cost 0.3–0.5 s under this machine's load.
  - **Writing.** A session writes only its own record, serialized in-process; others only read it.
  - **Identity.** A session is its Claude process, identified by pid plus start time. A nested
    `claude -p` is a peer like any other (owner decision 2026-11-14); a subagent shares its parent's pid.
  - **Per checkout, the record holds:**
    - the expected branch: the branch at first touch. It moves only when HEAD changed during this
      session's own call that contains a switch (HEAD read before and after that call). A failed
      or skipped switch keeps it, even when HEAD had already drifted. A switch inside a background
      task is seen later as drift and passes with an ack;
    - the time of the last writer call;
    - the paths edited through Edit/Write, recorded after the call succeeds.
  - **Per session, the record holds:** claims and acks.
  - **Leases** live apart: one lock directory per resource key, taken with an atomic `mkdir`, so the
    check and the grant are one step.
  - **When the process ends,** the record turns into a tombstone kept for 24 h. A resumed session
    with the same `session_id` adopts it.
  - **On `/clear`,** acks and claims are dropped.
  - **A malformed record** is skipped with a note.
- **Scope of an action.** The repository and the checkout are taken from the action's target path
  (an Edit's `file_path`, `git -C`, `cd x &&`), not from the session's cwd. Peers are live sessions
  in the same repository, or in repositories with the same `product` key.
- **Idle peer.** A live session with no call for 8 h (owner decision 2026-11-14) blocks nothing that
  depends only on its liveness (stash drop, its branch, `TaskStop`, a shared stop); its foreign files
  stay protected.
- **Writer.** A live session that made any call in the checkout in the last 2 h, except a known
  read-only form (`git status/log/diff/show`, `ls`, `cat`, `grep`, `rg`, `find` without a
  redirection, `-delete`/`-exec`, `--output` or `--pre`); an uncertain form counts as a writer call. Running tests
  counts; a false writer stop passes with an ack. The 2 h window applies only to the writer stop
  on a branch switch; the other peer-dependent protections follow liveness.
- **Foreign file.** A dirty or staged file this session cannot call its own. Its own are the paths it
  edited (Edit, Write; such a path stays its own even if another session edits it later) and, in a
  checkout no other session writes in, the files whose inode last changed (ctime, which no tool sets
  back) inside one of its own Bash calls in this process. A checkout becomes mixed for good once
  another session writes there after this one came, or when a live session ever wrote there (its
  background tasks may still); a writer marks itself before it writes, the check runs after the
  call's first touch and before any decision, and a sweep keeps a tombstone while a live session's
  unmixed checkout still depends on its mark. A resumed or adopted record infers nothing from before.
  Everything else is foreign and its protection does not expire: a file already changed when the
  session first touched the checkout, one changed between its calls (the user, a tool left running,
  a copy that kept old times), a deleted file, and in a mixed checkout every file it did not edit.
  Known limit: a writer with no record (the user, a tool outside Claude) changing a file while the
  session's own command runs, or a file such a command later rewrites, counts as the session's.
- **Guard.** It runs before every tool call and returns `allow`, `note` or `stop`.
  - **How it reads commands.**
    - It unwraps `heavy.sh --`, `bash -c`, `env`, `xargs`, `git -C`, `cd x &&` and `$(...)`, and
      each scope keeps its own directory.
    - It checks a compound command step by step. `switch -c x && commit` moves the expected branch
      first. In `add f && commit`, `f` is staged for the following commit.
    - A git, gh or kill command it cannot parse gets a note.
  - **Note**, and the action runs:
    - an edit in a checkout with another writer;
    - an edit of a foreign dirty file, once per path per hour;
    - an edit of a path claimed by a peer;
    - a branch switch where a peer's cwd is.
  - **Stop:**
    - a branch switch in a checkout with another writer;
    - discarding or committing foreign files: `reset --hard`, `stash`, `clean`, `restore`,
      `checkout -- <path>`, `commit -a`, `add -A`/`.`/`-u`/`<dir>`, `commit` with a foreign staged
      file;
    - `stash drop`/`clear` while a peer works in the repository;
    - commit, push or PR from a branch other than the expected one, whoever switched it;
    - deleting a peer's expected branch;
    - removing a worktree that is a peer's cwd or holds foreign files;
    - a shared resource's stop command while another product session is live;
    - `TaskStop` of a background task that ran a shared resource's start command, while another
      product session is live. The `/clear` cleanup in `register.ts` keeps such a task running, and
      the next session-start line says so;
    - using an exclusive resource leased to another session;
    - `kill` of a process that descends from a peer.
  - **Stop reason.** It is short: who (the peer, or "unknown owner"), what would be lost, and one
    way on.
    - For a Bash stop, the way on is the same command prefixed `CC_TUNER_ACK=<key>`, which covers
      one action on one target for 30 min. The guard records the ack and strips the prefix before
      the call, so the user's allow rules still match. When a peer owns what is at stake, the reason
      says the choice is the agent's; for files of unknown owner it says they may be the user's.
    - For a lease or a `TaskStop`, there is no ack. The way on is to wait, or to `SendMessage` the
      holder when that tool is available.
- **Resources** are declared, not detected.
  - `.claude/cc-tuner-resources.json` holds `product` and resources. Each resource has a `key`, a
    `kind` (`shared` or `exclusive`), `start`/`stop` command prefixes (teardowns included), and,
    for MCP, tool patterns.
  - Slice 2 reads `product`; the resources slice reads the rest.
  - The user file `~/.config/cc-tuner/resources.json` holds machine resources (Chrome :9222), which
    are checked across products, and may map repositories to products (`"products": {"<name>":
    ["<path>", …]}`), which works for every branch and worktree without a commit.
  - `"guard": false` in either file turns the guard off for that repository or the machine (owner
    decision 2026-11-14).
  - Every live product session consumes a shared resource.
  - An exclusive resource is leased by its first user until the holder runs `peers_release <key>`
    (checked under the same lock; anyone else's release is refused), 10 min after the holder's last
    use, or the holder's death. A repository's resource has one lease per product (per repository
    without one), a machine's one per machine. A call denied one resource gives back the ones it
    took for itself.
  - A repository without the file adds no repository rules; machine resources still apply.
- **Visibility.**
  - The module adds one line to the first prompt after startup, clear and resume (`prompt.submit`
    context), when peers are live or a task was kept at `/clear`. Not a `classic.SessionStart` hook:
    on Team/Enterprise and managed machines the built-in `sec-default` plugin passes `classic.*` events
    past user-installed modules.
  - `peers_report [path]` lists the peers of the repository at `path` (the cwd by default) and its
    product with branch (a detached HEAD shown as such), claims and edited paths. For peers in
    the same repository, it adds the `git merge-tree` conflicts of HEAD against their branch, run
    in a temporary object directory so the repository's object store is untouched, and cached per
    SHA pair.
  - `peers_claim <plan>` publishes the plan's open Owned paths under the plan's real path, so plans of
    one relative path in two repositories are two claims, then prints `report` with their overlap.
  - `/spec` runs `report` on the target repository before approval, and the agent compares it with
    the draft.
  - `/run` runs `claim` before the first slice, after each tick, and before integration.
- **cc-tuner's own texts.** The rule template and task-flow's post-merge cleanup take a worktree
  when the checkout has another writer, instead of switching or stashing in place. `/run`'s final
  cleanup leaves a task the guard keeps. `/clear` keeps a task that started a shared resource;
  stopping it is refused only while another product session is live, and it ends with its Claude
  process.
- **Git reads** by the guard are inert: `GIT_OPTIONAL_LOCKS=0`, `core.fsmonitor=false`, submodules ignored, literal
  pathspecs, no transport and no lazy fetch (`GIT_ALLOW_PROTOCOL` naming no protocol, `GIT_NO_LAZY_FETCH`). `status`
  runs in a bare git directory of its own (objects through alternates, HEAD pinned, the real index read, info/exclude
  copied, only the core settings that shape status passed), so no repository config, include, hook or filter driver
  exists there however the repository changes meanwhile; it reads the real attributes, so line endings are git's.
  merge-tree runs isolated the same way. Output the engine cut off, or a `ps` that fails, counts as no answer: a
  destructive step, a kill or a shared stop then stops with an ack.
- **Tools** the module registers: `peers_report`, `peers_claim <plan>`, `peers_release <key>`. The guard
  itself is the `tool.call` handler.
- **Guard surface:** the `register.ts` module (Slice 1, `docs/spike-guard-surface.md`): its `tool.call`
  handler sees each call before and after `next` and reuses `commands()`. The start line comes from
  the module too; `session-start.sh` keeps plan restore only and is unchanged.
- **Rejected:**
  - messages as the record (best-effort delivery);
  - the guard asking the user (a permission prompt);
  - a git-common-dir store;
  - parent-directory products;
  - detected resources;
  - automatic takeover;
  - a first-touch baseline (misses later changes; a foreign file covers it);
  - a `reference-transaction` git hook (per-repo install, clashes with husky, blind to the
    working tree);
  - file-name overlap as the conflict signal (66 % false alarms);
  - LLM relevance;
  - broadcast.
- **Follow-up issues:**
  - Codex sessions (their files are already protected as foreign);
  - waking idle peers;
  - cross-repository dependency notices;
  - a dev server holding a heavy slot.

## Definition of Ready

- [x] **Problem.** 10 collisions in 30 days of transcripts:
  - foreign WIP in a shared checkout;
  - a PR opened from a branch another session switched to;
  - `stack:down` killing another session's stack;
  - Chrome :9222 contention;
  - a merge conflict in a file both sessions edited.

  A third of concurrent time is several sessions in one directory. cc-tuner shares no state
  between sessions.
- [x] **Scope.**
  - New: `hooks/peers.ts` and its tests (the python `scripts/peers.sh` of Slices 2–4 is ported and removed).
  - Changed:
    - the guard surface;
    - the `spec`, `run`, `setup` and `task-flow` skills;
    - `assets/task-flow/rule.template.md`;
    - the plugin README;
    - contract pins.
- [x] **Acceptance:** each criterion has a deciding check.
- [x] **Test plan.** Module tests drive the core through an in-memory machine; `test_peers.sh` runs real
  `claude -p` sessions against a stubbed model API, with `sleep` processes as peers. The record
  directory comes from `CC_TUNER_PEERS_DIR` (`$.env`), the Claude pid from the module's own parent.
- [x] **Delivery.** `feat/session-coordination` → `main`, one PR, CI `validate.yml`.

## Acceptance criteria

Each check is `bash plugins/cc-tuner/tests/flow/test_peers.sh && bash plugins/cc-tuner/tests/flow/test_mod.sh`,
test group in brackets.

- [x] [machine] The record lifecycle works as Architecture states:
  - a dead pid becomes a tombstone, and so does a live pid with another start time;
  - a tombstone expires after 24 h;
  - resume adopts the record;
  - `/clear` drops acks and claims;
  - parallel writers lose no path;
  - a malformed record gives a note.

  (`record-*`)
- [x] [machine] Every guard stop above has a stop test and a neighbouring allow test:
  - a writer idle for more than 2 h, which lifts only the switch stop;
  - a dead peer, which lifts the liveness-based stops but leaves its foreign files protected;
  - this session's own files, branch or child process.

  The Bash cases also run behind the shell wrappers, including
  `echo "$(cd ../x && git status)"; git reset --hard`. The git cases also run behind `git -C`.
  Native tools get adapter fixtures.

  Compound cases: `switch -c x && commit`, `add f && commit`, and `git switch -c x && false`,
  which moves the expectation. With HEAD already drifted from `a`, a failed switch, a failed switch
  followed by `; true`, and `false && git switch c` keep it at `a`. A session that only ran tests
  is a writer; one that only ran `git status` is not; `cat x > f`, `find . -delete` and
  `git status && npm test` are writer calls.

  One test drives the shipped adapter end to end. (`guard-*`)
- [x] [machine] Ack:
  - the same Bash command with the printed `CC_TUNER_ACK=` key runs;
  - another action or target is still stopped;
  - the same command after 30 min is still stopped;
  - a lease or a `TaskStop` stop offers no ack.

  (`ack-*`)
- [x] [machine] Resources:
  - a shared stop command or a `TaskStop` is stopped while another product session is live, and
    runs when none is;
  - `/clear` keeps the task and the next start line names it;
  - two simultaneous first users get one lease;
  - a machine resource's MCP tool leased by a session of another product is stopped, and a repository
    resource of one key in two products does not contend;
  - a non-holder's `release` is refused, and so is a former holder's after reassignment;
  - a lease moves on the holder's `release`, 10 min after its last use, and on death;
  - machine resources apply in a repository without its file.

  (`resource-*`)
- [x] [machine] Report:
  - `report` lists the peers of the repository and of the product;
  - it prints merge-tree conflicts only for a conflicting same-repository branch;
  - it shows the Owned-path overlap after `claim`;
  - it leaves the repository's object store unchanged for a merge result that did not exist
    before, with a cold cache.

  (`report-*`)
- [x] [machine] The session-start line appears only with live peers or a task kept at `/clear`
  (also when its peer has since exited), on startup, clear and resume. Plan restore still skips
  resume. (`start-*`)
- [x] [machine] The guard decides in at most 150 ms p95 over 50 calls with 10 records, on the CI
  macOS runner. (`latency`)
- [x] [machine] The texts above are present. — `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- [ ] [eyes] Two real sessions in one scratch checkout:
  - the second session's `git switch` is stopped;
  - its agent picks a way on by itself;
  - you see no prompt.

  Machine replacement: the Slice 1 spike observes the deny in default and bypass modes, plus the
  guard tests. Waiver: none.

## Test plan

- **Regression:** module tests (`peers.test.ts`, `register.test.ts`) through `test_mod.sh`, and
  `plugins/cc-tuner/tests/flow/test_peers.sh` for end-to-end sessions (`claude -p`, stubbed model API).
- **First failing check:** write the harness and its `record-written` case first, then run
  `bash plugins/cc-tuner/tests/flow/test_peers.sh`. Expected: `FAIL record-written`, because there
  is no session record yet.
- **Targeted:** `test_peers.sh`, `tests/flow/test_mod.sh`, `tests/contract/test_contract.sh`.
- **Full:** `bash tests/run.sh` (claude at `tests/flow/CLAUDE_CODE_VERSION`). The EVALUATED_SHA
  guard is handled as in #75.
- **Static:** module validation and type check in `test_mod.sh`.
- **Runtime:** macOS and Linux, git ≥ 2.38 (`merge-tree --write-tree`), no network.
- **Mutation:** make `live()` in `hooks/peers.ts` ignore the start time. `liveness-pid-reuse` must then
  FAIL with `a record whose pid was reused reads as live`.
- **Known limit:** a peer's liveness is cached for a minute, so a peer that just exited can cause a
  false stop for up to 60 s; the ack passes it.

## Definition of Done

Recorded on the PR before merge:

- the first failing check was observed failing;
- targeted, full and static checks are green;
- the verify-feature record is on the PR;
- the diff was read;
- advisory findings were closed;
- Codex approved the exact SHA;
- CI is green on it;
- the follow-up issues are filed.

## Completion and reconciliation

Reported after merge: the squash merge, the spec archived, #73 closed, the worktree and branches
removed.

## Run config

branch: feat/session-coordination
target: main
host: github
merge: squash
auto_ready: no — the [eyes] live check has only a partial machine replacement
ci: any — `.github/workflows/validate.yml` runs `bash tests/run.sh` on ubuntu-latest and macos-latest
    for every pull request; observe with `gh pr checks <pr>`.
review: codex — cc-codex-triage is installed and reviews this repository.
target_test: bash plugins/cc-tuner/tests/flow/test_peers.sh && bash plugins/cc-tuner/tests/flow/test_mod.sh
full_test: bash tests/run.sh
full_test_cadence: per-candidate
tracker: gh
board: none
