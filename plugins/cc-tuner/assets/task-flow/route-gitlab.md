<!-- cc-tuner:delivery-route gitlab v0.23.0 -->
Delivery route for this GitLab repository, followed by `/cc-tuner:run` in place of `merge.sh`. These are steps you perform, and no script refuses on your behalf: a skipped step merges an unchecked candidate, so run them in order and stop at the first that fails. The order is the GitHub gate's: verify, review, verdict, CI, pinned merge. Never merge from the web button, with `glab mr merge` without the pin below, or by pushing to the target.

**Records.** A record is an MR note whose first line is one of these, naming the full 40-character SHA it judged (an abbreviated SHA never matches):

```text
cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <full sha>
cc-tuner-verified: <full sha>
cc-tuner-local-ci: <full sha> <command and result>
cc-tuner-accepted: <head sha> <who>: <what>
```

Publish one with `glab mr note <iid> --message "<record>"`. A `cc-tuner-verified` note continues with verify-feature's criterion lines, one per criterion, tagged `[browser]`, `[api]`, `[test]` or `[cli]`, or marked `NOT PROVED`. `cc-tuner-accepted` is the user's decision to merge without an approval, published only after they gave it in this session, and counts only under `review: none:<reason>`.

Read records with `glab api projects/:id/merge_requests/<iid>/notes --paginate`. Only notes whose author is the authenticated account count, so compare each note's `author.username` with `glab api user` (`username`): anyone with access can comment, and another person's marker is not this run's evidence. The latest record about the head wins, in both directions: a later `REQUEST_CHANGES` overrides an earlier approval, and a later decision overrides an earlier `REQUEST_CHANGES`. Never relabel a `REQUEST_CHANGES` as `APPROVE`; a verdict belongs to the SHA it judged, and when the head moved, review the difference instead.

1. **Open.** Push the branch and run `glab mr create --draft` against the target. The candidate is the MR's exact head SHA (`glab api projects/:id/merge_requests/<iid>`, field `sha`) with a clean working tree.
2. **Verify.** Run `cc-tuner:verify-feature` and publish its hand-back as the `cc-tuner-verified: <full sha>` note. Before merging, the verified SHA must be an ancestor of the head: `git merge-base --is-ancestor <verified sha> <head>`. When it is not, verify the current candidate. Fix commits after verification need no new record when `/run`'s evidence-reuse rule says the evidence still covers them. Print every `NOT PROVED` line in the merge report.
3. **Review and verdict.** Under `review: codex`, run `bash <cc-codex-triage install>/scripts/review-state.sh check <thread>` in the candidate worktree; it must print `CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<head> …` with the current head. The install directory is the first field of `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/plugin-here.sh" 'cc-codex-triage@cc-codex-triage' "$(git rev-parse --show-toplevel)"`. Under `review: none:<reason>`, you judge the candidate after the findings are fixed or refuted. Either way, publish the `cc-tuner-verdict` note for the SHA that was judged, immediately. The latest record about the head must be an `APPROVE`, or, under `none`, a `cc-tuner-accepted` note.
4. **Record the spec's DoD** in an MR note, not in a commit: a commit moves the reviewed SHA.
5. **CI.** Run `glab mr update <iid> --ready` when the MR is a draft, then wait for the pipeline that starts. Read `head_pipeline` from `glab api projects/:id/merge_requests/<iid>`. Green means all of: `head_pipeline` exists; it belongs to the current head (`head_pipeline.sha` equals the head, or, for a merged-results pipeline whose `ref` is `refs/merge-requests/<iid>/merge`, the second parent of that merge-result commit, `git rev-parse <pipeline sha>^2` after fetching the ref, equals the head); and it has status `success`. Pending, running, manual, canceled, failed, skipped and absent are not green: an absent pipeline is unproven CI, not passing CI. Under `ci: none:<reason>` there must be no pipeline on the head at all (a waiver covers CI that does not exist, never CI that ran) and a `cc-tuner-local-ci: <full sha> <command and result>` note for the head, written by you and truthful about what ran.
6. **Target.** `git fetch origin <target>`, then `git merge-base --is-ancestor <target tip> <head>`, with the tip read from `origin/<target>`. When it is not an ancestor, the target advanced past the candidate: integrate it, re-verify the affected evidence, obtain approval for the new candidate, and restart from step 2 for the new head.
7. **Merge, pinned.** Right before merging, re-read the head and the target tip. When either differs from what steps 2 to 6 judged, restart from the step that covers it. Then:

   ```bash
   glab mr merge <iid> --sha <head> --auto-merge=false --yes
   ```

   Add `--squash` when the spec says `merge: squash`. `--sha` makes GitLab refuse a head that moved; `--auto-merge=false` stops it queuing a merge on a pipeline nobody checked. Do not pass `--remove-source-branch`: cleanup is keyed on the merged head below.
8. **After the merge.** Confirm with `glab mr view <iid>` that the state is `merged`, then sync the target and clean up through `cc-tuner:task-flow`, keyed on the merged head: delete a task branch or worktree only while its tip is still that head.
