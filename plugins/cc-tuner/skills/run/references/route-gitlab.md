# Delivery route: GitLab

`/cc-tuner:run` follows this file at Delivery for a `host: gitlab` spec, in place of `merge.sh`.
No script checks these steps for you, so run every one, in order: verify, review, verdict, CI, pinned merge.

A failing step is a stop: fix its cause or hand over to the user, never edit or skip this route to get past
it. Merge only with the pinned command of step 8, never from the web button or by pushing to the target. A
`.claude/execute-task-runs/*.state.json` in the repository is run state from a removed runtime: refuse
delivery, as `merge.sh` does, and tell the user to finish that run under the plugin version that created it
or to delete the directory.

**Records.** A record is an MR note whose first line is one of these, naming the full 40-character SHA it
judged (an abbreviated SHA never matches):

```text
cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <full sha>
cc-tuner-verified: <full sha>
cc-tuner-local-ci: <full sha> <command and result>
cc-tuner-accepted: <head sha> <who>: <what>
```

A `cc-tuner-verified` note continues with verify-feature's criterion lines, one per criterion, tagged
`[browser]`, `[api]`, `[test]` or `[cli]`, or marked `NOT PROVED`. `cc-tuner-accepted` is the user's
decision to merge without an approval, published only after they gave it in this session, and counts only
under `review: none:<reason>`.

Write each record to a file with a quoted heredoc, so backticks and `$(...)` in it stay text, and publish
it from the file. `--resolvable=false` keeps the note from opening a thread that blocks a project requiring
resolved threads:

```bash
REC=$(mktemp) && cat > "$REC" <<'EOF'
cc-tuner-verdict: APPROVE <full sha>
EOF
glab mr note create <iid> --resolvable=false --message "$(cat "$REC")"
```

Read records in ascending order, without system notes, and only from the authenticated account, since
anyone with access can comment:

```bash
ME=$(glab api user | jq -r .username)
glab api "projects/:id/merge_requests/<iid>/notes?sort=asc&order_by=created_at" --paginate \
  | jq -s --arg me "$ME" 'add | map(select(.system == false and .author.username == $me))'
```

A note's record is its first line. Order by the greatest `created_at`, never by position: without
`sort=asc` the API returns newest first. The latest record about the head wins, whatever it says. A
verdict belongs to the SHA it judged: when the head moved, review the difference,
and never relabel a `REQUEST_CHANGES` as `APPROVE`.

1. **Open.** Push the branch and open a draft against the spec's target:

   ```bash
   glab mr create --draft --yes --target-branch <target> --source-branch <branch> --title "$(cat <title file>)" --description "$(cat <description file>)"
   ```

   Read `glab api projects/:id/merge_requests/<iid>` and require `target_branch` equal to `<target>`,
   `source_branch` equal to `<branch>` and `source_project_id` equal to `target_project_id`. Anything
   else, a fork MR included, is not this route: stop and hand over. The candidate is the MR's `sha`, equal
   to `git rev-parse HEAD` in a clean working tree.
2. **Verify.** Run `cc-tuner:verify-feature` and publish its hand-back as the `cc-tuner-verified: <full sha>`
   note. Before merging, require `git merge-base --is-ancestor <verified sha> <head>`; otherwise verify the
   current candidate. A fix commit after verification needs no new record while `/run`'s evidence-reuse
   rule says the evidence still covers it. Print every `NOT PROVED` line in the merge report.
3. **Review and verdict.** Under `review: codex`, take the cc-codex-triage install directory from the first
   field of `bash "<plugin root>/scripts/setup/plugin-here.sh" cc-codex-triage@cc-codex-triage` and
   run `bash <install>/scripts/review-state.sh check <thread>` in the candidate worktree. Only the 7-field
   marker `CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<head> tree=… base_sha=… spec_path=…`,
   with `head` equal to the MR's `sha` and to the worktree's `git rev-parse HEAD`, is an approval. Under
   `review: none:<reason>`, you judge the candidate once the findings are fixed or refuted. Either way,
   publish the `cc-tuner-verdict` note for the judged SHA at once. The latest record about the head must be
   an `APPROVE`, or, under `none`, a `cc-tuner-accepted` note.
4. **DoD.** Record the spec's DoD in an MR note published from a file, not in a commit: a commit moves the
   reviewed SHA.
5. **Approvals.** Read `glab api projects/:id/merge_requests/<iid>/approvals`: `approved` must be true, or
   `approvals_left` 0. Otherwise stop and ask a human to approve in GitLab, under `--auto` too: a required
   approval is a person's decision, and no note of yours stands in for it.
6. **CI.** Run `glab mr update <iid> --ready` when the MR is a draft and wait for the pipeline that starts.
   Read `head_pipeline` from `glab api projects/:id/merge_requests/<iid>`. Green means all of:
   - `head_pipeline` exists and `head_pipeline.project_id` equals `target_project_id`;
   - it ran on the head: `head_pipeline.sha` equals the head, or, for a merged-results pipeline (`ref`
     `refs/merge-requests/<iid>/merge`), `git rev-parse <pipeline sha>^2` equals the head after fetching
     that ref;
   - it has status `success`. Any other status, or no pipeline, is unproven CI, not passing CI.

   Under `ci: none:<reason>` the head must have no pipeline at all (a waiver covers CI that does not exist,
   never CI that ran) and a `cc-tuner-local-ci: <full sha> <command and result>` note, truthful about what
   ran.
7. **Target and strategy.** The target is the MR's `target_branch`. Run `git fetch <remote> <target>` with
   the remote `host.sh` printed, take `TIP=$(git rev-parse FETCH_HEAD)` (a single-branch clone has no
   `<remote>/<target>` ref) and require `git merge-base --is-ancestor "$TIP" <head>`. When it fails, the
   target advanced: integrate it, re-verify the affected evidence, get approval for the new candidate and
   restart from step 2.

   Set the strategy explicitly: glab sends `squash` only when it is true, so an MR with squash on would
   squash a `merge: merge` candidate. Read the project's `squash_option` (`glab api projects/:id`):
   `always` with `merge: merge`, or `never` with `merge: squash`, goes to the user. Otherwise run
   `glab api --method PUT "projects/:id/merge_requests/<iid>" -F squash=<true for squash, false for merge>`
   and read `squash` back from the MR.
8. **Merge, pinned.** Right before merging, re-read the head, the target tip, the MR's `squash` and the
   records; when any changed, restart from the step that covers it. Then merge, adding `--squash` for
   `merge: squash`:

   ```bash
   glab mr merge <iid> --sha <head> --auto-merge=false --yes
   ```

   `--sha` makes GitLab refuse a moved head; `--auto-merge=false` stops it queueing a merge on a pipeline
   nobody checked. Leave out `--remove-source-branch`: step 9 cleans up by the merged head.

   Under `--auto`, run it. Without `--auto`, the hand-over is this whole step: the re-read (head, target
   tip, latest records, approvals, pipeline) with the pinned command, never the merge line alone. Delivery
   stays pending until the merge is observed. `--check-only` stops here, after step 7.
9. **After the merge.** Confirm with `glab mr view <iid>` that the state is `merged`, then sync the target and
   clean up through `cc-tuner:task-flow`, keyed on the merged head: delete a task branch or worktree only
   while its tip is still that head.
