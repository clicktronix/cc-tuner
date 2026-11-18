# <Feature> — plan

**Spec:** <replace with the repository-relative spec path>
**Branch:** <replace with the task branch>

Replace both headers and every slice below. `Owned paths: <REPLACE_ME>` is required: fill it using
the grammar from `plan-lint.sh --help`, then run `plan-lint.sh check`.
Use `Owned paths: .` by itself when a filename cannot be represented as a literal entry, such as
`a,b.md` at the repository root. The slice claims the entire repository and runs on its own.
A slice whose work is one of the Opus cases in `/run`'s placement reference (a sensitive surface,
performance by measurement, concurrency or data integrity, a cross-module invariant) gets one more
line under `Delivers:`, `Model: opus — <why: which case>`; every other slice runs on Sonnet.

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
