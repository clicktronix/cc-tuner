# heavy.sh starts heavy checks by machine capacity

**Goal:** a heavy check starts when the machine can take it: capacity follows the machine's memory,
a check holds as many slots as it weighs, queue-aware waiters start in arrival order, and while the
operating system reports memory pressure (including pressure from work outside heavy.sh) a check
waits up to a bound, then starts with a warning; checks in the next 600 s skip the wait and say so.
**Issue:** #72
**Architecture:** `plugins/cc-tuner/scripts/heavy.sh` stays the single owner of admission.

- *Capacity.* A slot is one unit of capacity: `CC_TUNER_HEAVY_SLOTS` (set user-wide; documented as
  units of weight now, `--slots` stays a synonym) or, unset, max(1, floor(total RAM / 8 GB)) with
  total from `hw.memsize` (macOS) or `MemTotal` rounded up to a whole GiB (Linux).
- *Weight.* `--weight w`, default 1, clamped to capacity with a note; the check holds w locks among
  `slot-1..N.lock` (flock, file names unchanged, so a pre-change heavy.sh holding `slot-1` still blocks).
- *Arrival order.* A ticket per waiter in `queue/` under the slot directory, created already locked
  (temp name, flock, rename) and numbered by a counter under a short lock. Only the oldest live ticket
  takes slots; it keeps what it took and waits for the rest (only the head accumulates, so no
  deadlock). It polls every 0.1 s while other waiters keep `CC_TUNER_HEAVY_POLL`, so a pre-change
  waiter, which has no ticket, rarely takes the slot the head still needs. The head removes dead tickets. A waiter whose
  parent became PID 1 (its session died) leaves the queue.
- *Memory pressure.* Before starting, the head waits while the OS reports pressure: macOS
  `kern.memorystatus_vm_pressure_level` >= 2 (warn/critical), Linux `/proc/pressure/memory` `some avg10`
  >= 10. After `CC_TUNER_HEAVY_MEM_WAIT` (default 600 s) it starts with the warning line
  `heavy.sh: started under memory pressure after <n>s`, and writes a deficit mark in the slot directory;
  for the next 600 s no check waits for pressure, and each one under pressure says
  `heavy.sh: started under memory pressure (...)`. Unreadable signal: start and say pressure was not
  measured.
- *Unchanged.* Exit code and stdin passthrough, process-group supervision, keeper for leftovers, a
  nested call runs inside its parent's slots (the outer call's weight governs), interrupt stops the
  group.
- *Seams.* `CC_TUNER_HEAVY_TOTAL_MB` and `CC_TUNER_HEAVY_PRESSURE` (normal|warn|critical|unknown)
  replace the OS readings in tests; `test_heavy.sh` exports both for the whole file.

Rejected: messaging between sessions (kernel locks already coordinate and survive a crashed session);
named weight classes (table in code); an available-memory threshold (`kern.memorystatus_level` counts
active memory as free — 31% measured equal to active+inactive+free+speculative; the honest
free+inactive+speculative+purgeable was 2.5 GB with 11 GB swapped, so any threshold blocks nearly
always on 16 GB); waiting forever or failing on pressure (stalls delivery or reads as a failed test);
first-come without a queue (a weight-2 check starves); a capacity file shared by sessions (one more
command and state; the env var set user-wide gives the same number to every session); weight 2 for
`docker compose up -d` (returns in seconds; the slot cannot bound containers).

## Definition of Ready
- [x] Problem/baseline: `heavy.sh` takes `CC_TUNER_HEAVY_SLOTS` slots (default 1) of equal weight and
      never looks at memory (`scripts/heavy.sh:36-37`, the `try_slot` loop); `--weight` is not an option.
- [x] Scope: `scripts/heavy.sh`, `tests/flow/test_heavy.sh`, `tests/flow/test_heavy_owner.py`, the callers' guidance in
      `skills/run/references/placement.md`, `agents/slice-unit.md` (if it names the call), the
      plugin README and `skills/setup/SKILL.md` heavy-check lines, contract pins; out of scope:
      coordinating feature work between sessions (#73), CPU-based capacity, cgroup limits, Windows.
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment and data are explicit
- [x] Delivery: branch feat/heavy-capacity, PR to main, tracker gh, CI validate.yml

## Acceptance criteria
- [x] [machine] With capacity 2, two weight-1 checks run at the same time and a weight-2 check starts
      only when both slots are free — checked by: `bash plugins/cc-tuner/tests/flow/test_heavy.sh`
- [x] [machine] Unset `CC_TUNER_HEAVY_SLOTS` gives capacity max(1, floor(total/8 GB)) (16 GB -> 2,
      7 GB -> 1, 64 GB -> 8 through `CC_TUNER_HEAVY_TOTAL_MB`); a set value wins; a weight above
      capacity runs alone and says it was clamped — checked by: test_heavy.sh
- [x] [machine] Arrival order: a weight-1 check that arrives while a weight-2 check waits does not start
      before it — checked by: test_heavy.sh
- [x] [machine] Memory pressure: under warn/critical the head waits and says so, starts once pressure
      is normal, starts with the warning line after `CC_TUNER_HEAVY_MEM_WAIT` and leaves a deficit
      mark that lets the next check start without waiting; an unreadable signal starts with
      "pressure not measured" — checked by: test_heavy.sh
- [x] [machine] The real readers parse this machine's output: macOS `sysctl` and Linux
      `/proc/pressure/memory` / `/proc/meminfo` fixtures — checked by: test_heavy.sh (Linux fixtures)
      and `bash plugins/cc-tuner/scripts/heavy.sh status` here
- [x] [machine] A slot held by the pre-change heavy.sh (origin/main 45795a7) blocks the new one.
      FIFO holds for queue-aware callers; a pre-change waiter shares the slot locks and may overtake,
      which the head's 0.1 s poll makes rare (the test: an old waiter polling every 5 s yields) — checked by: test_heavy.sh
- [x] [machine] Queue hygiene: a dead waiter's ticket does not block, and a waiter whose parent died
      leaves the queue — checked by: test_heavy.sh
- [x] [machine] The existing guarantees still hold (passthrough, keeper, nested, interrupt, kill) —
      checked by: test_heavy.sh existing cases
- [x] [machine] `heavy.sh status` shows capacity, the pressure reading, holders with their weight and
      the queued waiters with pid and age — checked by: test_heavy.sh
- [x] [machine] placement.md gives the call with weights (e2e 2; full suite, build and container start
      1, saying the slot does not bound running containers), tells the caller to carry a
      "started under memory pressure" line into its report, and says the outer call's weight governs
      a nested one; README and setup describe derived capacity, `CC_TUNER_HEAVY_SLOTS` as user-wide
      units and `CC_TUNER_HEAVY_MEM_WAIT` — checked by: `bash plugins/cc-tuner/tests/contract/test_contract.sh`
- [x] [machine] On this machine `bash plugins/cc-tuner/scripts/heavy.sh status` reports capacity 2 and
      a real memory-pressure reading — checked by: running it

## Test plan
- Regression test: new cases in `plugins/cc-tuner/tests/flow/test_heavy.sh`
- First failing check: `bash plugins/cc-tuner/tests/flow/test_heavy.sh`; expected failure:
  `FAIL weight-two-waits-for-both-slots` with `heavy.sh: usage: ...` (`--weight` unknown)
- Targeted checks: `bash plugins/cc-tuner/tests/flow/test_heavy.sh`
- Full regression: `bash tests/run.sh`
- Static/build checks: `bash -n plugins/cc-tuner/scripts/heavy.sh`; included in tests/run.sh
- Runtime/acceptance environment: local macOS 16 GB; CI ubuntu and macOS; no network, temp slot dirs;
  `tests/flow/test_heavy_owner.py` passes heavy.sh's argv layout and moves with it
- Negative/mutation proof: remove the "only the oldest live ticket may take slots" condition; the
  arrival-order case must fail saying the weight-1 check started before the waiting weight-2 check.

## Definition of Done
Recorded on the PR before merge, not ticked here.
- Regression check observed failing for the expected reason before the change
- Targeted and full checks pass; verify-feature's record is on the PR
- Complete diff read; one advisory review; Codex approved the exact candidate SHA
- PR head equals the reviewed SHA, CI green under `ci: any`

## Run config
branch: feat/heavy-capacity
target: main
host: github
merge: squash
auto_ready: yes
ci: any — `.github/workflows/validate.yml` runs `bash tests/run.sh` on ubuntu-latest and macos-latest
    for every pull request; observe with `gh pr checks <pr>`.
review: codex — cc-codex-triage is installed and reviews this repository.
target_test: bash plugins/cc-tuner/tests/flow/test_heavy.sh
full_test: bash tests/run.sh
full_test_cadence: per-candidate
tracker: gh
board: none
