# Field-audit fixes: one continuous flow, fewer dead stops, bounded machine load

Source: personal-os `docs/2026-09-27-cc-tuner-audit.md` (code audit, 19 field sessions, the
deep-review/code-review comparison, and the contradiction/over-restriction appendix). Built on top of
the uncommitted `fix/workflow-review` changes from 2026-09-21 in this worktree.

Goal: the agent enters the flow itself, keeps implementing without dead stops on reversible steps,
keeps the machine usable with several sessions running, and every refusal names the next action.
Gates that protect irreversible outcomes stay (exact-SHA merge, head pin, read-only lenses, the git
invariants).

## Wave 1 — scripts (each with a flow test that fails before the change)

1. `merge.sh`
   - Scope follows the caller: a review thread or `--review` makes the PR in scope; a PR with
     neither a plan nor intent is refused unless `--unmanaged` is passed (P1-1, K1).
   - `--review none:<reason>` makes cc-codex-triage optional per spec; the public verdict and CI
     still decide. Default stays the Codex required review (user: optional, used on most features).
   - The public verdict is read from the latest review **or** PR comment by the account at the head
     SHA (field: verdict posted as a comment was invisible).
   - Requires a `cc-tuner-verified: <sha>` record whose SHA is contained in the head (P1-2a); it
     does not force a re-verify for every fix commit.
   - Narrative history comments removed; behaviour comments kept short.
2. `heavy.sh` — machine-wide slots for heavy checks (full suites, e2e, builds) shared by every
   session on the machine; `CC_TUNER_HEAVY_SLOTS` (default 1); stale-slot recovery by pid.
   Five concurrent sessions each running e2e is what froze the laptop; prose cannot coordinate
   independent sessions, a lock can.
3. `plan-lint.sh` — literal Owned paths may contain `[ ] ( ) @ + =` (Next.js App Router);
   `check` accepts a spec that exists in the worktree even before it is committed (K2).
4. `session-start.sh` — silent when the plan's spec is archived; advisory wording, no
   "before doing anything else" (P2-10).
5. `prereq-check.sh` — find companion skills by skill directory name, not by internal path.

## Wave 2 — instructions

- `disable-model-invocation` removed from `/spec` and `/run`; `--auto` only when the user asked.
- `/run`: spec taken from the plan header when the argument is the plan or missing (O4); push and a
  draft PR are allowed without asking, the only attended stop is merge (O2); waiting for units/CI is
  not a reason to end the turn with a promise (P2-6); test cadence: slices run targeted checks,
  full regression once on the assembled candidate and once per batch of review fixes, e2e only in
  verify-feature — all through `heavy.sh` (P2-7, the RAM report); built-in `/code-review` facts
  corrected (appendix 1).
- `slice-unit`: `maxTurns: 300` (field: 69 units, median 159, 23 over 200, 12 over 300); commit after
  every green step (K9); mechanical changes outside Owned paths allowed when listed in the return,
  anything else returned as a need (O7); heavy checks only through `heavy.sh`, never full suite/e2e.
- Partial return: redispatch fresh with landed state; `SendMessage` continuation named as the
  expensive path it is (P1-3).
- `deep-review`: lens brief gets the reading angles "removed behaviour" and "cross-file trace";
  owner writes `toolchain.txt` next to the diff (P2-8); owner settles P0/P1 claims a command can
  decide before the verdict; incomplete lens → one redispatch, then carry the gap into required
  review instead of a dead `REQUEST_CHANGES` (K4); P3 are listed on the PR, issues only for
  independent work (K5).
- `spec`: size the contract to the task (O5); spike slice for an unknown test command (O6); commit
  order matches `plan-lint` (K2); DoD/Completion become PR-recorded bullets, not spec checkboxes (K7);
  review mode `review: codex|none:<reason>` in Run config.
- `task-flow`: attribution answer lives in `task-flow.local.md` (K3); plans never move out of
  `task-plans/` (K8); DoD wording allows one escalation (K6).
- `setup`: spawn depth `2` recommended, `1` explained as forbidding lookups (K11); forwarders
  `/task-flow-setup` and `/statusline-setup` removed with README/manifest/template references (K12);
  required-review cap named as cc-codex-triage `--cap` (K13).
- statusline: native `rate_limits` from stdin first, OAuth endpoint only as fallback (P2-11).

## Deferred, needs cc-codex-triage

- Approval carry-over when the only new commit integrates the target without touching candidate
  files (O8). Needs the required-review state in cc-codex-triage to accept it; cc-tuner cannot.

## Verification

- Every script change: a flow test red before, green after.
- `bash tests/run.sh` PASS; `claude plugin validate ./plugins/cc-tuner` PASS; `git diff --check`.
- Read the complete diff before handing over. No commit, push, release or installed-plugin update.

## Release order

Release cc-codex-triage (`fix/field-audit`, integration rounds, `renew`, header preflight) before
this cc-tuner release. cc-tuner still works with cc-codex-triage 0.13.1: prereq-check prints a NOTE
and `/run` falls back to a normal round and the documented reset.
