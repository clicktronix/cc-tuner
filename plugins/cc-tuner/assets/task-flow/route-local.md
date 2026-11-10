<!-- cc-tuner:delivery-route local v0.23.0 -->
Delivery route for this repository, which has no remote and no pull request, followed by `/cc-tuner:run` in place of `merge.sh`. These are steps you perform, and no script refuses on your behalf: a skipped step merges an unchecked candidate, so run them in order and stop at the first that fails. The order is the GitHub gate's: verify, review, verdict, CI, merge. The candidate is a branch tip; nothing here pushes.

**Records.** A record is a git note in the `cc-tuner` notes ref on the commit it judges. Its first line is one of these, naming the full 40-character SHA of the commit the note sits on:

```text
cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <full sha>
cc-tuner-verified: <full sha>
cc-tuner-local-ci: <full sha> <command and result>
cc-tuner-accepted: <head sha> <who>: <what>
```

Publish one with `git notes --ref cc-tuner append -m "<record>" <judged sha>`, and read the records on a commit with `git notes --ref cc-tuner show <sha>`. A `cc-tuner-verified` record continues with verify-feature's criterion lines, one per criterion, tagged `[browser]`, `[api]`, `[test]` or `[cli]`, or marked `NOT PROVED`. `cc-tuner-accepted` is the user's decision to merge without an approval, recorded only after they gave it in this session, and counts only under `review: none:<reason>`. Notes live in this clone only: say so when handing the result over. The latest record about the head wins, in both directions: a later `REQUEST_CHANGES` overrides an earlier approval, and a later decision overrides an earlier `REQUEST_CHANGES`. Never relabel a `REQUEST_CHANGES` as `APPROVE`; a verdict belongs to the commit it judged, and when the head moved, review the difference instead.

1. **Candidate.** The candidate is the branch's exact head SHA (`git rev-parse HEAD`) with a clean working tree.
2. **Verify.** Run `cc-tuner:verify-feature` and record its hand-back as `cc-tuner-verified: <full sha>` on the commit it verified. Before merging, the verified SHA must be an ancestor of the candidate: `git merge-base --is-ancestor <verified sha> <candidate>`. When it is not, verify the current candidate. Print every `NOT PROVED` line in the merge report.
3. **Review and verdict.** Under `review: codex`, run `bash <cc-codex-triage install>/scripts/review-state.sh check <thread>` in the candidate worktree; it must print `CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<head> …` with the current head. The install directory is the first field of `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/plugin-here.sh" 'cc-codex-triage@cc-codex-triage' "$(git rev-parse --show-toplevel)"`. Under `review: none:<reason>`, you judge the candidate after the findings are fixed or refuted. Either way, record the `cc-tuner-verdict` for the commit that was judged, immediately. The latest record about the head must be an `APPROVE`, or, under `none`, a `cc-tuner-accepted` record.
4. **CI.** There is none: the CI mode is always `ci: none:<reason>`. Run the spec's local checks on the candidate and record `cc-tuner-local-ci: <full sha> <command and result>` on the head, truthful about what ran and what it returned. An absent record is unproven CI.
5. **Target.** Read the target tip (`git rev-parse refs/heads/<target>`) and require `git merge-base --is-ancestor <target tip> <candidate>`. When it is not an ancestor, the target advanced past the candidate: integrate it into the branch, re-verify the affected evidence, obtain approval for the new candidate, and restart from step 2 for the new head.
6. **Merge, fast-forward only.** Right before merging, re-read the candidate and the target tip; when either differs from what steps 2 to 5 judged, restart from the step that covers it. Find the worktree that has the target checked out (`git worktree list --porcelain`).
   - A clean worktree has it: run `git merge --ff-only <candidate>` there.
   - No worktree has it: run `git update-ref refs/heads/<target> <candidate> <old target tip>`, where the old tip is the one step 5 checked. It is a compare-and-swap: git refuses when the target moved, and then you restart from step 5.
   - A dirty worktree has it: do not touch it. Hand the merge to the user with the exact command, `git -C <that worktree> merge --ff-only <candidate>`, and keep delivery pending until the merge is observed.

   Never create a squash or merge commit on the target: a spec that says `merge: squash` is delivered as the candidate's own commits, or the user squashes the branch first and the squashed commit becomes the candidate for a new run of steps 2 to 5.
7. **After the merge.** Confirm `git rev-parse refs/heads/<target>` equals the candidate, then clean up through `cc-tuner:task-flow`, keyed on the merged head: delete the task branch or worktree only while its tip is still that head.
