# Optional opinions from a second provider

Reference for `/cc-tuner:spec`. Read when `cc-codex-triage` is installed and the task has an
unfamiliar dependency, a current-facts question, or two defensible designs. Nothing here is a
mandatory step, and no chain of `ask` → `research` → `debate` exists: each method answers a
different question, `debate` is considered only when two positions survive `research`, and most
specs need none of them.

| method | the question it answers | what comes back |
|---|---|---|
| `/cc-codex-triage:research` | facts that are not in the repository — current docs, a comparison of approaches, versions and dates | cited conclusions with stated limits; a repository is optional context |
| `/cc-codex-triage:ask` | one narrow uncertainty about a mechanism or an idiom | one answer with its basis and its uncertainty |
| `/cc-codex-triage:debate` | two positions that both survived research and carry a real trade-off | what held, what stayed contested, a recommendation |

## When to ask, and when not to

Section 1 of `/spec` owns the decision and its timing: once, before discovery starts. Never ask per
call, and never ask again once the answer is on record.

Run `research` alongside the internal read-only fan-out, in the same turn. Wait for it only before a
decision that depends on its findings. Do not dispatch
the same call twice; if the bridge hands off a long dispatch (exit 20), watch the printed command as
a background task.

`debate` is available to the owning agent within the authorised task and budget, without a fresh
user request per call. Use it only when two defensible positions remain after research; the round
ceiling is a bound, not a target. Grilling and the decisions stay with the owner because the owner
holds the requirements — hand the adviser the relevant draft text or path rather than claiming it
cannot see the draft.

## What the answer is

Evidence. It enters the spec's **Sources** with its citations and enters a decision only after the
owner has validated the consequential claims. An external opinion is never an approval and never
resolves a product decision on the user's behalf. Record what was adopted and why in the spec.

## Boundaries

- No bridge → discovery proceeds unchanged.
- Advisory threads never share a name with a required-review thread; the bridge refuses that, and
  `/spec` never needs a required thread.
- Cost: one dispatch per method per spec, concurrent with owner work. Report the requested
  model/effort and the observed usage the bridge records; do not guess a dollar figure.
