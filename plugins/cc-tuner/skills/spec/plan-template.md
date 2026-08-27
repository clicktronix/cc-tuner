# <Feature> — plan

**Spec:** <replace with the committed spec path>
**Branch:** <replace with the task branch>

Replace both headers and every slice below. Two slices are shown so the `Blocked by` edge is visible;
a real plan has as many as the work needs. `Owned paths: <REPLACE_ME>` is a required slot, not an
example: replace it using the grammar from `plan-lint.sh --help`, then run `plan-lint.sh check`.

## Slice 1 — <what this slice makes work>
Blocked by: none
Owned paths: <REPLACE_ME>
Deciding check: <the exact command that says whether this slice works>
Delivers: <the end-to-end behaviour, from the user's side — not a layer>

- [ ] <an observable condition, not an implementation step>
- [ ] <another one>

## Slice 2 — <what this slice makes work>
Blocked by: 1
Owned paths: <REPLACE_ME>
Deciding check: <command>
Delivers: <behaviour>

- [ ] <condition>
- [ ] <condition>
