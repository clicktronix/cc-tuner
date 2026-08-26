# <Feature> — plan

**Spec:** <path to the committed spec this plan implements>
**Branch:** <the task branch this plan belongs to>

Replace every slice below. Two are shown so the `Blocked by` edge is visible; a real plan has as many
as the work needs. Run `plan-lint.sh check` on the result — this template passes it as written, so a
failure is something you introduced.

## Slice 1 — <what this slice makes work>
Blocked by: none
Owned paths: <the directories this slice may touch>
Deciding check: <the exact command that says whether this slice works>
Delivers: <the end-to-end behaviour, from the user's side — not a layer>

- [ ] <an observable condition, not an implementation step>
- [ ] <another one>

## Slice 2 — <what this slice makes work>
Blocked by: 1
Owned paths: <directories>
Deciding check: <command>
Delivers: <behaviour>

- [ ] <condition>
- [ ] <condition>
