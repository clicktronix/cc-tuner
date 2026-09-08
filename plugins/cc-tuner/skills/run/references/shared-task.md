# One task across repositories

Read when the work spans repositories or a spec names `second-repo` or `shared-task`. These are
instructions for the invoking skill's stage; they do not start another lifecycle or authorise
deployment, migration or work outside the approved scope. `/run` remains the orchestrator.

## Spec and plans

Keep one shared outcome and issue for coupled work. Each repository needs its own branch, PR,
local spec and committed plan for the existing resolver and review gates.

The **primary spec** owns the shared outcome, cross-repository prerequisites, combined acceptance
checks and merge order. Its `second-repo` entry identifies the companion checkout, branch and local
spec path. The companion's `shared-task` links back to the primary spec; its local spec records its
contribution, target, merge strategy and CI policy. It is not an independently shippable task.

Prepare and validate all local specs and plans under the same contract approval. Every local spec
must meet the normal readiness requirements before unattended execution. Run `plan-path.sh` and
`plan-lint.sh` in each task checkout with that repository's local spec. Keep Owned paths relative to
the local repository, never `../...` into another checkout. Put cross-repository prerequisites in
the primary spec's test plan and the affected slice's deciding check.

Distinguish merge order from rollout prerequisites: a merged migration is not an applied migration.
Name the environment evidence required before dependent work can ship.

## One execution loop and task list

If invoked from a companion, resolve its `shared-task` to the primary spec and coordinate the whole
task there. Read every local spec and validate every plan before implementation. Execute commands,
commits and reviews in their named checkout; do not launch independent `/run` lifecycles.

Publish one combined task list after preparing the plans. Qualify slice names by repository, carry
the local plan edges and add cross-repository edges from the primary spec. Reconcile missing tasks
and completed slices on resume. Use one verify → review → deliver chain for the shared result.

Read each local frontier and select work whose shared prerequisites are satisfied. Local
`ready-batches` establishes only local readiness. Update the prerequisites when review changes the
plan; a ready local batch does not discharge an external dependency.

## Combined verification

For `verify-feature`, read the primary spec, all local specs and each participating diff. Exercise
the combined acceptance checks and record the repository/SHA set tested together. Local checks alone
do not prove the pair. Return unproved criteria and missing environment evidence to the caller;
standalone verification does not initiate review, merge or deployment.

## Review and delivery

Perform `/run` Delivery steps 1–7 for each repository before the first merge. Give each required
review its local spec, the primary spec, companion diffs and SHAs. Record each repository's PR,
candidate SHA, review thread and CI policy in the primary PR. A changed participant requires
rechecking combined acceptance and refreshing affected reviews against the new set of commits.

Before merging any participant, run the normal `merge.sh` invocation with `--check-only` in every
candidate's checkout, using its own PR, SHA, strategy, CI mode and review thread. All must pass.
A PR without a committed plan is refused: prepare its local plan and re-earn candidate evidence;
never use the unchecked path for unrelated PRs to deliver a companion.

Then merge in the primary spec's declared order with the checked command in each repository.
Confirm each merge and its stated rollout prerequisites before the dependent merge. If a necessary
deploy or migration is not authorised, report the blocker and continue independent work without
claiming delivery. After a partial merge, retain its record and resume only the remaining work;
do not re-merge or reset history.

Partial PRs use `Refs`, not `Closes`. Reconcile targets, branches and worktrees in every repository;
close the shared issue only when combined acceptance and all delivery prerequisites are satisfied.
