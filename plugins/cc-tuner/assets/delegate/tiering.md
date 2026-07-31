# Model tiering — shared classification table

Read by `/cc-tuner:delegate` and by `/cc-tuner:run` phase 4 (when the
config's `model_tiering` is on). Purpose: the main (expensive) model plans,
verifies, and reviews; implementation units run on the cheapest model that
can do them well. When in doubt between two tiers, pick the HIGHER one —
misclassifying down costs a failed round plus a redispatch, which is more
expensive than just running the higher tier.

## Tiers

| Tier | Agent `model` | A unit qualifies when… |
|---|---|---|
| **mechanical** | `sonnet` | The full solution is already spelled out — the subagent only types it. Renames/moves, dependency or config bumps, applying a diff designed in the plan, repetitive codemods with one clear pattern, doc sync, test scaffolding copied from a named sibling, i18n string additions. |
| **standard** | `opus` | Ordinary feature/bugfix code inside one module, with existing conventions to copy and acceptance criteria that are checkable from the unit itself. Includes writing tests for behavior the plan already designed. |
| **architectural / sensitive** | *(no override — main model)* | Anything with design freedom left in it (new abstractions, protocols, cross-cutting changes, concurrency, data-model shape), and ANY touch of the sensitive surfaces: auth / secrets / crypto, migrations or destructive data ops, public API, money / payments / pricing, infra / CI / deploy config, security-relevant input handling. |

Never delegated at all, regardless of tier: decomposition and planning,
acceptance judgment, review of a subagent's output, merge/deploy decisions,
and user-facing communication. Those stay with the main agent — tiering
saves tokens on typing, not on judgment.

## Verification contract (per delegated unit)

The dispatching agent MUST, before accepting a unit:

1. **Read the full diff** the subagent produced — not its summary of it.
2. **Run the cheap gate** (config's `cheap_gate`, or the repo's obvious
   types/lint/unit equivalent) scoped to the change.
3. **Check the unit's acceptance criteria** stated at dispatch time.

On failure: ONE redispatch to the same tier with concrete, file:line
feedback. On a second failure: escalate one tier (sonnet → opus → main
model does it itself) — never a third blind retry at the same tier.

## Dispatch prompt requirements

A delegated unit's prompt must be self-contained: the exact files in scope,
the conventions to copy (name a sibling file), the acceptance criteria, and
what NOT to touch. Subagents get no conversation history — anything not in
the prompt does not exist for them. Parallel units editing files must use
worktree isolation.
