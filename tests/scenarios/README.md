# Skill evaluation scenarios

Eval scenarios for `/execute-task` (pressure/discipline probes), `claude-md-writer`
(retrieval/application probes), and `task-flow` (whose REDs are documented production
incidents from the pre-plugin era rather than fresh probe runs — the failures already
happened for real), following Anthropic's evaluation-driven development and
the superpowers `writing-skills` RED-GREEN loop. Format mirrors
`clicktronix/nextjs-clean-skills` `tests/scenarios/` (`query`, `baseline_failure`,
`expected_behavior`, `anti_expectation`, plus `baseline_observed` / `green_check`
once runs happen).

Probes are self-contained decision tasks ("do not read the filesystem"), run as
isolated haiku subagents — the weak-model audience is where guidance earns its keep.
RED = no skill/playbook text in context, with one deliberate exception:
`sensitive-small-diff-skip`'s RED is an **ablation** baseline (the probe includes the
skip policy but WITHOUT the sensitive-surface list — the question being whether the
list itself is load-bearing, not whether a skip policy exists). GREEN = the relevant
guidance verbatim, as it appears in production.

The four 2026-07-26/28 `task-flow` rows were measured differently: their REDs are documented
production incidents, but a **fresh RED arm was also probed** (same query, guidance withheld) so the
verdict rests on a measured contrast rather than on the incident alone. Where the two disagree, the
row says so.

## Status (2026-07-08 baselines; task-flow rows 2026-07-16 and 2026-07-31)

| Scenario | RED | GREEN | Verdict |
| --- | --- | --- | --- |
| execute-task/sensitive-small-diff-skip | **2/2 reproduced** (ablation) | flips + ANTI clean | **load-bearing** — without the sensitive-surface list, size arithmetic always wins over surface risk |
| claude-md-writer/paths-rule-placement | **2/2 reproduced** | flips | **load-bearing** — baseline confidently invents config (`scope:`/`languages:` keys, `src/api/.claude.md`) a user would paste and silently get nothing |
| claude-md-writer/what-goes-where | inconsistent | flips | value = factual precision (mechanism names), not discipline |
| execute-task/eyes-criterion-autonomy | 0/2 | holds (cites [eyes]/merge:auto mechanics) | did not reproduce — hard-stop kept as insurance; GREEN-regression probe recorded |
| execute-task/red-cheap-gate-deadline | 0/2 | holds | did not reproduce — same treatment |
| task-flow/tiny-doc-pr-batching | historical incident 2026-06-05 (RED in production) | flips 2/2 + ANTI clean | **load-bearing** — policy encodes direct user feedback |
| task-flow/issue-without-board-status | historical incident 2026-06-05 (RED in production) | flips 2/2 + ANTI clean | **load-bearing** — recipes + field-ID caching are the fix |
| task-flow/autofix-trusted-blindly | **2/2 reproduced** — both arms run lint, neither runs typecheck | 2/2 + ANTI clean | **load-bearing in both framings** — the conjunction "typecheck AND lint" is the payload, not the call to verify |
| task-flow/regression-test-never-red | partial hold neutral, **reproduced under deadline** | 2/2 + ANTI clean | **load-bearing under pressure** |
| task-flow/pre-existing-scope-rebuttal | partial hold neutral, **reproduced under deadline** (offers to land with a known issue) | 2/2 + ANTI clean | **load-bearing under pressure** |
| task-flow/branch-continued-after-merge | 0/2 — correct action unaided | 2/2 + ANTI clean | did not reproduce; kept as insurance — the query telegraphs the diagnosis the production agent had to derive |

Honest read: the execute-task **hard-stops** are not load-bearing for isolated haiku
probes (the model holds the gates unaided); the **fail-closed review-skip rule** and the
claude-md-writer **mechanism facts** are. Production pressures a probe can't simulate
(long context, sunk cost, mid-task fatigue) are the remaining argument for the
hard-stop text — cheap insurance, kept.

The 2026-07-31 batch sharpened two things worth carrying forward. First, **deadline framing is where
these rules earn their keep**: two of the four held unaided when unhurried and failed when rushed,
which is the condition all three production incidents occurred under — a single neutral probe would
have scored them "not load-bearing" and thrown away working guidance. Second, `autofix-trusted-blindly`
was predicted not to reproduce, on the theory that a model asked point-blank says "run the checks". It
does say that — and means **lint**. The prediction was right about the words and wrong about the
content, which is the argument for probing rather than reasoning about probes.

Method caveat for that batch: the probe subagents inherited the host project's `AGENTS.md` and memory,
so the RED arm is a stronger-than-neutral control. That corpus supplies none of the four behaviours
under test, so the measured effects are lower bounds — but a clean-room harness would make the next
batch trustworthy without the asterisk.

Per the Iron Law, a future edit to the guarded sections needs its own RED→GREEN before
shipping; the GREEN-regression probes here make that cheap.
