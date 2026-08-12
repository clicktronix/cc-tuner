# cc-tuner owns its planning contract

**Date:** 2026-08-12
**Status:** accepted

## Context

`/cc-tuner:run` used to plan inside its own delivery phase: Phase 1 read the spec's `Implementation
tasks` list and created visible Claude tasks from it, with a one-sentence rule for how to cut the work
("one task for every independently verifiable implementation unit"). Dependencies existed only between
lifecycle phases, never between implementation units, so nothing stopped a task from starting while the
work it depended on was still open, and a resume re-derived the whole plan from prose every time.

Matt Pocock's `to-tickets` skill states the decomposition discipline we wanted: vertical tracer-bullet
slices, each demoable on its own, each sized to one fresh context window, each declaring the tickets
that block it, with wide refactors sequenced expand → migrate → contract instead of forced into a
slice. `to-spec` and `to-tickets` are MIT-licensed and installed here already.

## Decision

cc-tuner implements its own planning contract, enforced in `runctl`:

- a task graph in run state with `blocked_by`, `owned_paths`, `delivers`, `title`, `acceptance` and
  `checks`;
- validation of that graph — unknown blockers, self-references, duplicates, cycles, path escapes,
  lifecycle completeness — reported per id at import and re-checked on every state write;
- `plan frontier`, which answers what may start now, and `task start`, which refuses anything else;
- `plan import`, which writes the whole graph in one update or none of it;
- a new model-invocable `/cc-tuner:plan` that authors the graph and stops before implementation.

The shape of the decomposition rules is taken from `to-tickets`. Its **text is neither read at runtime
nor copied into this repository.**

## Consequences

An upstream release of `mattpocock-skills` cannot change this workflow. That is the point: `to-spec`
and `to-tickets` carry `disable-model-invocation: true`, so a cc-tuner command cannot invoke them, and
the two ways to use them anyway were both worse — reading another plugin's `SKILL.md` during a run
makes our lifecycle depend on the wording of a file we do not version, and copying the text creates a
second copy of a rule that drifts from the original.

What we give up is automatic inheritance of upstream improvements to the slicing rules. The rules now
live in `commands/plan.md` and are enforced by `runctl`; keeping them current is a deliberate act.

The model-invocable skills that remain usable directly are used directly, by id:
`mattpocock-skills:codebase-design` places the seams `/cc-tuner:plan` slices along, and `/spec` and
`/run` invoke `grilling`, `domain-modeling`, `diagnosing-bugs`, `research`, `prototype`, `tdd` and
`code-review` the same way.

## Attribution

Decomposition model influenced by [Matt Pocock's `to-tickets` skill](https://github.com/mattpocock/skills)
(MIT). No code or prose from that repository is included here.
