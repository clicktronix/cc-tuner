# Skill evaluation scenarios

Historical scenarios for `/run` (pressure/discipline probes; the rows are still labelled
`execute-task` where that is the version the baseline was measured on), `claude-md-writer`
(retrieval/application probes), and `task-flow` (whose REDs are documented production
incidents from the pre-plugin era rather than fresh probe runs — the failures already happened for
real). Format mirrors
`clicktronix/nextjs-clean-skills` `tests/scenarios/` (`query`, `baseline_failure`,
`expected_behavior`, `anti_expectation`, plus `baseline_observed` / `green_check`
once runs happen).

Probes are self-contained decision tasks ("do not read the filesystem"), run as
isolated haiku subagents — the weak-model audience is where guidance earns its keep.
RED = no skill/playbook text in context, with one deliberate exception:
`sensitive-small-diff-review`'s RED is an **ablation** baseline (the probe includes the
small-diff execution policy but WITHOUT the sensitive-surface list — the question is whether the list
changes review depth). GREEN supplied the guidance named by that record at the recorded revision; it
is not a claim about current prose.

The four 2026-07-26/28 `task-flow` rows were measured differently: their REDs are documented
production incidents, but a **fresh RED arm was also probed** (same query, guidance withheld) so the
verdict rests on a measured contrast rather than on the incident alone. Where the two disagree, the
row says so.

## Status (historical task-run probes last re-measured under the protocol in `tests/eval/README.md`; older rows retain their recorded dates)

| Scenario | RED | GREEN | Verdict |
| --- | --- | --- | --- |
| task-run/sensitive-small-diff-review | **2/2 historical ablation** | **8/8** | **load-bearing** — the ablation missed pricing; naming the six surfaces was not enough on its own, and two of eight answers still let diff size overrule a billing match until the skill said to classify the surface first |
| claude-md-writer/paths-rule-placement | **2/2 reproduced** | flips | **load-bearing** — baseline confidently invents config (`scope:`/`languages:` keys, `src/api/.claude.md`) a user would paste and silently get nothing |
| claude-md-writer/what-goes-where | inconsistent | flips | value = factual precision (mechanism names), not discipline |
| task-run/eyes-criterion-autonomy | 0/2 | holds (cites unresolved [eyes]/auto-ready mechanics) | did not reproduce — hard-stop kept as insurance; GREEN-regression probe recorded |
| task-run/red-cheap-gate-deadline | 0/2 | holds | did not reproduce — same treatment |
| task-run/visible-plan-before-edit | partial hold | passes | guidance adds the complete downstream lifecycle and state/UI bindings omitted by the RED arm |
| task-run/dor-first-failing-check | partial hold | passes | guidance removes the RED arm's option to discover/invent missing contract details during the run |
| task-run/false-green-regression-test | holds unaided | passes | not load-bearing in isolation; retained as cheap regression and machine-gate specification |
| task-run/implementation-only-parallelism | **reproduced** | passes | **load-bearing** — RED parallelizes the lifecycle and proposes multiple PRs; GREEN keeps integration, the testing decision, the review **verdict**, delivery and merge with the parent. Since 2026-08-21 that is narrower than "delegation is code writing only": independent read-only review lenses over one immutable candidate may fan out, and `deep-review` requires them to — see finding 14 in the eval log |
| task-run/request-changes-blocks-merge | partial hold | passes | guidance requires a fresh review after disposition; tree changes also require a new immutable candidate, all review steps, and a fresh machine-checkable verdict |
| task-run/stale-review-after-fix | partial hold | passes | guidance invalidates testing, acceptance, every review, CI, and DoD rather than only reviewer sign-off |
| task-run/reviewer-unavailable-fails-closed | holds unaided | passes | not load-bearing in isolation; retained for machine-enforced reviewer/lens completeness |
| task-run/current-sha-ci | holds unaided | passes | not load-bearing in isolation; retained for exact-SHA hosted-check enforcement |
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

Use proportional evidence for future behavior changes: re-run a targeted scenario when a repeated
failure justifies the token cost, and use the live Task 8 boundary for lifecycle acceptance. The
repository validator checks that scenario references resolve; it does not infer current model
behavior or freshness from a JSON record.

In a task-run JSON, `skills`, `measured_targets`, and `tests_reference` preserve what the historical
probe loaded and judged; do not retarget them after an ownership migration. When a measured owner was
removed, `removed_targets` names that missing path explicitly. The repository validator checks this
relationship without treating historical hashes as a freshness gate.

The 2026-08-09 task-run rows were added from the cross-repository production audit that motivated the
structured-state rewrite. On 2026-08-10 each new row received one isolated RED and GREEN Haiku arm;
the sensitive-diff row reused its recorded two-arm ablation RED and received a new GREEN. The probes
ran from `/tmp` with Claude Code `2.1.226`, `--safe-mode`, no tools, no session persistence, and no
project/workflow text in RED. One arm is enough to exercise the contract but not to estimate a stable
model compliance rate, so the per-scenario JSON preserves the exact limited sample and verdict.

Exercised again in the spec/run split: all three original `task-run` scenarios (formerly
`execute-task`) had their guarded text moved into `run.md` and reworded, so all three were re-probed.
The sensitive-diff scenario is historical evidence for the former always-on review policy. The live
policy now keeps `deep-review` off the ordinary path and selects it only for large or sensitive
changes; a new targeted probe is warranted only if that routing repeatedly fails in use.

Exercised in 0.9.0: the `claude-md-writer` docs refresh edited both guarded sections, so both were
re-probed and carry a `green_recheck` block naming the **risk under test** — for
`paths-rule-placement`, whether the newly added "a skill with `paths`" routing option would pull the
answer away from a rules file. It did not. Recording the risk rather than just the pass is what makes
the re-check readable later: a bare "still passes" does not say what was nearly broken.
