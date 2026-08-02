# Effort tiering

Read `../workflow-contract.json` first. Its thresholds, sensitive surfaces, delivery order, and
invariants are normative.

Choose the higher tier when uncertain:

| Tier | Effort | Use when |
| --- | --- | --- |
| mechanical | `low` | The complete edit is prescribed: moves, renames, generated updates, codemods, or named scaffolding. |
| standard | `medium` | An ordinary feature or fix follows established patterns inside one module. |
| hard | `high` | Design freedom remains: new abstractions, concurrency, cross-cutting contracts, or data-model changes. |
| sensitive | `xhigh` | The diff touches any contract-defined sensitive surface. Never delegate it without owner review. |

For every delegated unit, the owning agent reads the complete diff, runs the scoped cheap gate, and
checks the dispatched acceptance criteria. Retry once with concrete feedback; after a second failure,
escalate one tier. Use isolated worktrees for concurrent edits.

Decomposition, acceptance judgement, delegated-output review, merge/deploy decisions, and user-facing
communication stay with the owning agent.
