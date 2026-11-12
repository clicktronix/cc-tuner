# heavy.sh starts heavy checks by machine capacity — plan

**Spec:** docs/PLANS/2026-11-12-heavy-capacity.md
**Branch:** feat/heavy-capacity

full_test_cadence: per-candidate

## Slice 1 — weighted slots, derived capacity and an arrival-order queue
Blocked by: none
Owned paths: plugins/cc-tuner/scripts/heavy.sh,plugins/cc-tuner/tests/flow/test_heavy.sh,plugins/cc-tuner/tests/flow/test_heavy_owner.py
Deciding check: bash plugins/cc-tuner/tests/flow/test_heavy.sh
Delivers: on a 16 GB machine two weight-1 checks run side by side, a weight-2 e2e runs alone, and checks start in the order they asked, with old heavy.sh copies still respected

- [x] `--weight w` holds w of the capacity's slots; capacity 2 runs two weight-1 checks together and a weight-2 check only when both slots are free
- [x] unset `CC_TUNER_HEAVY_SLOTS` gives max(1, floor(total/8 GB)) (16 GB -> 2, 7 GB -> 1, 64 GB -> 8 via `CC_TUNER_HEAVY_TOTAL_MB`; Linux MemTotal rounded up to a GiB); a set value wins; `--slots` is a synonym; an overweight check is clamped with a note
- [x] a weight-1 arrival does not start before a waiting weight-2 head; the head keeps slots it took
- [x] a slot held by heavy.sh from 45795a7 blocks the new one, and a pre-change waiter does not overtake a weight-2 head
- [x] a dead waiter's ticket does not block; a waiter whose parent died leaves the queue
- [x] `heavy.sh status` shows capacity, holders with weight, and queued waiters with pid and age
- [x] the existing passthrough, keeper, nested, interrupt and kill cases still pass; test_heavy_owner.py follows the new argv

Evidence: bash plugins/cc-tuner/tests/flow/test_heavy.sh → 72 PASS, 0 FAIL, rc=0 (RED first: `FAIL capacity-16gb-is-2 (want /capacity 2/ in: heavy.sh: all slots free)`; the --weight cases hung to the wait helper's timeout instead of printing FAIL); mutation `oldest_live() == ticket` → `True` killed by head-starts-when-last-slot-frees and arrival-order-is-kept @ 6e1eca2

## Slice 2 — no heavy check starts into memory pressure
Blocked by: 1
Owned paths: plugins/cc-tuner/scripts/heavy.sh,plugins/cc-tuner/tests/flow/test_heavy.sh,plugins/cc-tuner/tests/flow/test_heavy_owner.py
Deciding check: bash plugins/cc-tuner/tests/flow/test_heavy.sh
Delivers: while macOS or Linux reports memory pressure the head of the queue waits (bounded), says so, and a forced start is visible and does not make the next checks wait again

- [ ] under warn/critical the head waits and says what it waits for; normal pressure starts it
- [ ] after `CC_TUNER_HEAVY_MEM_WAIT` it starts with `heavy.sh: started under memory pressure after <n>s` and writes a deficit mark that lets checks in the next 600 s start without waiting
- [ ] an unreadable signal starts with "pressure not measured"
- [ ] macOS `kern.memorystatus_vm_pressure_level` and Linux `/proc/pressure/memory` / `/proc/meminfo` readers parse fixtures, and `heavy.sh status` here shows a real pressure reading and capacity 2
- [ ] `status` shows the pressure reading and an active deficit mark

## Slice 3 — callers use weights and read the pressure warning
Blocked by: 1
Owned paths: plugins/cc-tuner/skills/run/references/placement.md,plugins/cc-tuner/agents/slice-unit.md,plugins/cc-tuner/README.md,plugins/cc-tuner/skills/setup/SKILL.md,plugins/cc-tuner/tests/contract/test_contract.sh
Deciding check: bash plugins/cc-tuner/tests/contract/test_contract.sh
Delivers: an agent following placement.md passes the right weight, carries a forced-start warning into its report, and a user reading README/setup knows how capacity is chosen and overridden

- [ ] placement.md gives the call with `--weight` (e2e 2; full suite, build, container start 1, saying the slot does not bound running containers), the outer call's weight governing a nested one, and the forced-start line to carry into the report
- [ ] README and setup describe derived capacity, `CC_TUNER_HEAVY_SLOTS` as user-wide units of weight, and `CC_TUNER_HEAVY_MEM_WAIT`
- [ ] contract pins name the weight call, the forced-start line and the user-wide override
