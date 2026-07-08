# Skill evaluation scenarios

Eval scenarios for `/execute-task` (pressure/discipline probes) and `claude-md-writer`
(retrieval/application probes), following Anthropic's evaluation-driven development and
the superpowers `writing-skills` RED-GREEN loop. Format mirrors
`clicktronix/nextjs-clean-skills` `tests/scenarios/` (`query`, `baseline_failure`,
`expected_behavior`, `anti_expectation`, plus `baseline_observed` / `green_check`
once runs happen).

Probes are self-contained decision tasks ("do not read the filesystem"), run as
isolated haiku subagents — the weak-model audience is where guidance earns its keep.
RED = no skill/playbook text in context; GREEN = the relevant guidance verbatim, as it
appears in production.

## Status (2026-07-08 baselines)

| Scenario | RED | GREEN | Verdict |
| --- | --- | --- | --- |
| execute-task/sensitive-small-diff-skip | **2/2 reproduced** | flips + ANTI clean | **load-bearing** — without the sensitive-surface list, size arithmetic always wins over surface risk |
| claude-md-writer/paths-rule-placement | **2/2 reproduced** | flips | **load-bearing** — baseline confidently invents config (`scope:`/`languages:` keys, `src/api/.claude.md`) a user would paste and silently get nothing |
| claude-md-writer/what-goes-where | inconsistent | flips | value = factual precision (mechanism names), not discipline |
| execute-task/eyes-criterion-autonomy | 0/2 | not run | did not reproduce — hard-stop kept as insurance; scenario retained as GREEN-regression probe |
| execute-task/red-cheap-gate-deadline | 0/2 | not run | did not reproduce — same treatment |

Honest read: the execute-task **hard-stops** are not load-bearing for isolated haiku
probes (the model holds the gates unaided); the **fail-closed review-skip rule** and the
claude-md-writer **mechanism facts** are. Production pressures a probe can't simulate
(long context, sunk cost, mid-task fatigue) are the remaining argument for the
hard-stop text — cheap insurance, kept.

Per the Iron Law, a future edit to the guarded sections needs its own RED→GREEN before
shipping; the GREEN-regression probes here make that cheap.
