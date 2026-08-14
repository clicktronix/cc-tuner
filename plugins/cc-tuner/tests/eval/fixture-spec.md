# Eval fixture: what to build in the scratch repository

Hand this description to `/cc-tuner:spec`. It is not a spec — `/spec` writes that. It is the raw
request the eval starts from, chosen so the run has something real to prove.

## The task to give `/cc-tuner:spec`

> Add a retry budget to the HTTP client. A request may be retried at most N times, N comes from
> config rather than a constant, and a request that exhausts its budget fails with one typed error
> that names how many attempts were made. Today the client retries forever on a 503.

## Why this one and not something smaller

Four properties, each load-bearing for a step of the eval. A fixture without them can pass while the
thing under test is broken.

**It splits into at least two slices with a real edge.** Reading the budget from config has to land
before anything can consume it. Step 1 asserts `TaskList` carries `blockedBy`, and a fixture whose
slices are independent cannot show an edge going missing — the exact failure a one-pass
implementation produces.

**It has a failing check that fails for the right reason.** "Retries forever on a 503" is observable
before the fix and observably different after, so `/spec`'s `First failing check` is a real command
with a real expected failure, not `not applicable`.

**It is small enough to finish twice.** Steps 1 and 2 run the whole flow in two separate
repositories. A fixture that takes an hour makes the eval something nobody repeats, and an eval
nobody repeats stops being evidence the first time the code changes.

**It needs no dependency the scratch repo will not have.** No database, no network service, no
credential. The one external requirement is GitHub itself, which steps 2b and 4 need anyway.

## What the scratch repository must already have

- **One required status check on the target branch.** `merge.sh` refuses when a repository has no
  required checks — absent CI is unproven CI — so a repo without branch protection fails step 2b for
  the wrong reason. Any check will do; a workflow that runs the repo's own test command is enough.
- **A remote on GitHub**, and `gh auth status` clean. Steps 2b and 4 read real reviews and real CI.
- **Something that runs as a test command.** The spec has to name `target_test` and `full_test`, and
  `/run` proves RED before GREEN by executing them.

Two repositories are needed, not one: step 2 must not inherit step 1's plan file or task list.
