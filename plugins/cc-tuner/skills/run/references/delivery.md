# Delivery

Read from `/cc-tuner:run` when the candidate is verified, and again on resume before any delivery
step. `/run` owns merge authorization (Who may stop the run), the reuse rule for local checks (Proving
a slice) and target synchronisation (Prepare the candidate); this file owns everything from the first
push to the reconcile after the merge.

**The route.** Repeat the [host preflight](hosts.md) for every checkout. Publish only after it
passes and the task permits the write. If publication is pending, complete the available local
review from step 2 and follow the local handoff in `/run`.

A new commit needs fresh authoritative approval and CI, with acceptance and DoD evidence covering
the resulting candidate. Local checks follow the reuse rule in `/run`'s Proving a slice; a new SHA
does not restart findings already read or advisory passes already completed. Shared-task delivery
also covers the complete repository/SHA set defined in [shared-task.md](shared-task.md).

1. **Push and open or locate the PR.** Push the task branch to the selected remote and pass the explicit
   `--head <branch>` and `--repo` when creating its PR. Verify its repository, base and full head SHA against the
   clean candidate. Use `mattpocock-skills:pr` when available; otherwise describe the change and
   its evidence. A small fix fits in a paragraph. Add a risk section when a concrete risk needs it.
   Pass the verifier-owned file directly to `gh pr comment <pr> --body-file "$VERIFY_FILE" --repo "$DELIVERY_HOST/$DELIVERY_PROJECT"`.
   On resume reuse the matching record. When a board is named, move the card to In review if available.
2. **Choose one advisory workflow for the first clean candidate.**
   - `deep-review` for a sensitive surface, at least 15 production files or 500 production lines,
     multiple repositories/services, or a major architectural boundary. Sensitive surfaces are
     authentication/authorization/secrets/cryptography; migrations or destructive data operations;
     public APIs, persisted schemas or cross-service contracts; money/pricing/billing;
     infrastructure/CI/deployment/release; and security-relevant input handling. Values, defaults,
     fixtures and configuration count when they decide behaviour on these surfaces. Deep-review owns
     packet preparation, sharding, the lens limit and the line it prints before dispatch.
   - Otherwise `mattpocock-skills:code-review`: give it the review base SHA as its fixed point, the
     spec path as its spec and the rule files `cc-tuner:agent-rules` resolved as its standards, so it
     neither asks for them nor guesses from issue links. Dispatch exactly its two subagents, Standards
     and Spec, with placement’s model and effort for ordinary review,
     and keep their reports separate. Fix a documented-standard or
     spec finding once validated, and a code smell only when you agree it costs something here; list
     the smells you declined.
   - Claude Code's built-in `/code-review <level> <target>` only when the user asks for it. Put the
     level first: a level written after the target is read as part of the target. It has no Spec
     axis, so the spec's acceptance stays yours to check, and `max` dispatches a verifier per
     candidate finding, which is costly on a large candidate. Pass base, candidate and spec; run
     without publishing findings automatically.

   Deep review already covers Spec and Standards, so do not stack workflows. If fixes newly meet a
   deep-review trigger, escalate once. These are not merge gates. A deep-review `INCOMPLETE` names the
   lenses/paths nobody read; the table below says who closes that gap.

   Triage findings per `.claude/rules/task-flow.md`: validate them against the agreed outcome,
   repository rules and evidence; refute speculative extensions outside the spec or rules (style
   notes with no violation do not move the candidate); fix the rest grouped by cause, update the
   plan, then verify the affected findings and continue to required review. Record independent
   future work through `cc-tuner:task-flow`.
3. **Finish each required review round before acting on its findings.** Include the publication
   command below in the required-review brief, including rounds after fixes. The round ends with
   its recorded verdict on the PR when publication is authorized. Then triage findings, including
   optional notes accompanying an APPROVE, and push any fix.

   Give each round its own receipt in the run’s private scratch directory. Use the companion claim
   as its filename for Codex, or a fresh UUID for your own judgement. Keep the filename and contents
   for retries. Under `review: codex`, finish a recorded approval in one Bash call from the candidate:

   ```bash
   bash "$COMPANION/scripts/review-state.sh" check "$THREAD" > "$ROUND_FILE" &&
     python3 "${CLAUDE_PLUGIN_ROOT}/scripts/finish-review.py" "$ROUND_FILE" --pr "$PR"
   ```

   Here `COMPANION` is the cc-codex-triage install and the helper belongs to cc-tuner. Pass the
   expanded absolute helper path into the companion skill. For a validated REQUEST_CHANGES, including
   blocking findings at the cap, use the SHA pinned at begin. For `review: none:<reason>`, use the
   SHA and decision you judged. In either case write the one-line receipt
   `cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <judged-sha>` and call the same helper.
   An incomplete round has no verdict to publish.

   Without publication authority, omit `--pr` and retain the receipt. If GitHub is unavailable,
   continue safe local fixes. Retry the saved receipt on the same PR before the next push or
   review round. On resume pass the existing file directly to the helper. The helper reuses the
   authenticated author’s review for that round and pins GitHub's `commit_id` to the reviewed SHA. A
   moved head needs its own review.

   | | `codex` (default) | `none:<reason>` |
   |---|---|---|
   | verdict owner | cc-codex-triage `--required` at the exact SHA, one task-specific `--thread` for all rounds and `merge.sh`, in the candidate worktree | you: after step 2's findings are fixed or refuted with `file:line` evidence, you judge the candidate |
   | after a fix commit | a new required round on the new SHA | re-check the affected findings on the new SHA, not a new fan-out, then judge again |
   | deep-review `INCOMPLETE` | name the unread lenses/paths in the round's brief | read those paths yourself before judging, or ask the user to accept the gap |
   | review cap (`--cap`; cc-codex-triage owns the default) | stop review rounds, keep fixing what is safe, ask the user once: more rounds (`review-state.sh renew <thread> --by <who> [--rounds N]`, same thread) or merge on their decision. `--by` names who agreed, in this conversation, to more rounds of this thread; one yes covers one renew. Pass `--rounds N` when they named a number, since without it the renewal is the whole cap; cc-codex-triage before 0.20.0 answers it with a usage error, then renew without it and say the renewal is the whole cap | — |
   | user decides to merge without an approval | merge under `--review 'none:<who> decided at the cap'` with a decision record (step 4) | decision record (step 4) |

   An advisory review that returns reports rather than a verdict (Standards and Spec) is input to the
   owner, never a verdict to copy. A finding refuted with evidence or deferred by the user needs no
   code change: re-judge the same SHA. Do not manufacture an empty commit to move the candidate, and
   do not reset a thread to seek a more favourable verdict.
4. **Record a user decision to merge without approval** only after the user gave
   it in this session, naming them and what they accepted:

   ```bash
   REC=$(mktemp) && cat > "$REC" <<'EOF'
   cc-tuner-accepted: <head-sha> <who>: <what was accepted>
   EOF
   gh pr comment <pr> --body-file "$REC" --repo "$DELIVERY_HOST/$DELIVERY_PROJECT"
   ```

   `merge.sh` honours it only under `--review none:<reason>` and only for that exact head.
5. **Record the spec's DoD before merge.** Name each item and its evidence in a PR comment or body
   section. Do not commit it to the spec (that moves the reviewed SHA) or to the integration target.
6. **Mark the PR ready and deliver through the checked script.** When the candidate is verified,
   judged and its DoD recorded, run `gh pr ready <pr> --repo "$DELIVERY_HOST/$DELIVERY_PROJECT"` if
   it is a draft and wait for the checks that start then. Recheck target advancement as `/run`'s
   Prepare the candidate describes. When
   [Merge authorization](../SKILL.md#who-may-stop-the-run) permits delivery, merge with the spec's
   strategy, CI mode, pinned head and same review thread:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" [--ci <mode>] [--review none:<reason>] <pr> <squash|merge> <candidate-sha> [<review-thread>]
   ```

   Omit `--ci` for `required`. The thread is required under `review: codex`.
   If any participating spec declares `none:<reason>`, read [local-ci.md](local-ci.md)
   before this step and record the exact candidate's local evidence as it requires.
   For a shared task, complete the reference's preflight of **all** candidates before any merge,
   then follow its declared-order and partial-delivery recovery instructions.

   Without merge authorization, run this command with `--check-only` and hand the passing candidate and merge
   command to the user. `--check-only` requires everything a merge does; it only skips the final
   merge action. Keep deliver pending until the merge is observed.

   The script rechecks required review, public verdict, the verify-feature record, the selected CI
   checks and PR head. Fix any refusal; do not substitute raw CLI/web/API merge or direct push.
7. **Reconcile after merge.** Sync targets and clean up task branches/worktrees through
   `cc-tuner:task-flow`. If tracker writes are authorized, use the tracker named by
   `docs/agents/issue-tracker.md`. Close only a fully delivered issue and set its card to Done.
   For `tracker: local`, follow [local-issues.md](../../task-flow/references/local-issues.md).
   Close an epic and move its card to Done only after its last sub-issue closes. A partial `Refs`
   merge keeps both open; return the card to In Progress. Report reserved tracker updates in the
   handoff. Keep completion records off the integration target.
