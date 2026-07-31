# Effort tiering and the sensitive-surface list

Read by `/cc-tuner:run` — phase 1 to pick each unit's reasoning effort, phase 4 to decide whether a
diff can skip the deep review. **This file is the single source of the sensitive-surface list.** Nothing
else should keep a copy: two copies of a security-relevant list is one copy that is quietly out of date.

This used to be a *model* tier table (mechanical → sonnet, standard → opus). That framing was written
when picking a cheaper model was the lever available, and it has aged badly: on Opus 5 the useful dial
is **reasoning effort**, not model identity, and a `sonnet` override buys less than dropping effort on
work that needs none. Effort also composes with forked subagents in a way a model override does not —
five low-effort units can run in parallel without giving up the main model's judgement anywhere.

When in doubt between two tiers, pick the **higher** one. Misclassifying down costs a failed round plus
a redispatch, which is more expensive than having run the higher tier in the first place.

## Tiers

| Tier | `effort` | A unit qualifies when… |
|---|---|---|
| **mechanical** | `low` | The full solution is already spelled out and the subagent only types it: renames and moves, dependency or config bumps, applying a diff the plan already designed, a codemod with one clear pattern, doc sync, test scaffolding copied from a named sibling, i18n string additions. |
| **standard** | `medium` | Ordinary feature or bugfix code inside one module, with existing conventions to copy and acceptance criteria checkable from the unit itself. Includes writing tests for behaviour the plan already designed. |
| **hard** | `high` | Design freedom is left in it: new abstractions or protocols, cross-cutting changes, concurrency, data-model shape. Anything where the *approach* is still a decision. |
| **sensitive** | `xhigh`, never delegated blind | Any touch of the surfaces below. Effort is the floor here, not the fix — the dispatching agent reads the whole diff itself regardless. |

## Sensitive surfaces

A touch of any of these is sensitive regardless of how small the diff is. **Diff size is not a risk
measure** — a five-line change to a fee constant carries more risk than a two-hundred-line copy edit.

- auth, secrets, crypto
- DB migrations, destructive data ops (`DELETE`, `DROP`, `rm`)
- public API surface
- money, payments, pricing
- infra, CI, deploy config
- security-relevant input handling — injection, SSRF, path-traversal guards, server-side allowlists.
  *Not* ordinary client-side form validation.

If you cannot confirm a surface is non-sensitive, treat it as sensitive. That is the fail-closed
direction and it is cheap: over-reviewing costs tokens, under-reviewing costs a payment bug in
production.

## Never tiered down at all

Decomposition and planning, acceptance judgement, review of a subagent's output, merge and deploy
decisions, and user-facing communication. Tiering saves effort on typing, never on judgement.

## Verification contract, per delegated unit

Before accepting a unit, the dispatching agent MUST:

1. **Read the full diff** the subagent produced — not its summary of it.
2. **Run the cheap gate** (the spec's `cheap_gate`, or the repo's obvious types/lint/unit equivalent)
   scoped to the change.
3. **Check the unit's acceptance criteria** as stated at dispatch time.

On failure: one redispatch at the same tier with concrete `file:line` feedback. On a second failure,
escalate one tier — never a third blind retry at the same tier, which is how a run burns its budget
without converging.

## Dispatch prompt requirements

A delegated unit's prompt has to be self-contained: the exact files in scope, the conventions to copy
(name a sibling file), the acceptance criteria, and what NOT to touch. Subagents get no conversation
history — anything not in the prompt does not exist for them. Parallel units editing files need
worktree isolation.
