# Delivery route: GitLab

`/cc-tuner:run` reads this file from the plugin at Delivery for a `host: gitlab` spec, in place of `merge.sh`. The repository holds only the key block that `route.sh check` verifies, so a candidate cannot edit its own gate. These are steps you perform and no script refuses on your behalf: a skipped step merges an unchecked candidate, so run them in order. The order is the GitHub gate's: verify, review, verdict, CI, pinned merge.

A failing step is a stop. Fix its cause or hand over to the user; never edit, reword or skip this route to get past it. Never merge from the web button, with `glab mr merge` without the pin below, or by pushing to the target. A `.claude/execute-task-runs/*.state.json` in the repository is run state from a removed runtime: refuse delivery, as `merge.sh` does, and tell the user to finish that run under the plugin version that created it or to delete the directory.

**Records.** A record is an MR note whose first line is one of these, naming the full 40-character SHA it judged (an abbreviated SHA never matches):

```text
cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <full sha>
cc-tuner-verified: <full sha>
cc-tuner-local-ci: <full sha> <command and result>
cc-tuner-accepted: <head sha> <who>: <what>
```

A `cc-tuner-verified` note continues, in the same note, with verify-feature's criterion lines, one per criterion, tagged `[browser]`, `[api]`, `[test]` or `[cli]`, or marked `NOT PROVED`. `cc-tuner-accepted` is the user's decision to merge without an approval, published only after they gave it in this session, and counts only under `review: none:<reason>`.

Write a record to a file first, with a quoted heredoc so that backticks and `$(...)` in a criterion line stay text, then publish it from the file:

```bash
REC=$(mktemp) && cat > "$REC" <<'EOF'
cc-tuner-verdict: APPROVE <full sha>
EOF
glab mr note create <iid> --resolvable=false --message "$(cat "$REC")"
```

Never put a record inline in a double-quoted `--message`. `--resolvable=false` keeps the note from becoming an unresolved thread that blocks a project requiring every thread resolved.

Read records with the notes API in ascending order, system notes excluded, and only the authenticated account's:

```bash
ME=$(glab api user | jq -r .username)
glab api "projects/:id/merge_requests/<iid>/notes?sort=asc&order_by=created_at" --paginate \
  | jq -s --arg me "$ME" 'add | map(select(.system == false and .author.username == $me))'
```

Anyone with access can comment, so another person's marker is not this run's evidence. A note's record is its first line. Decide by the greatest `created_at`, never by position in the list: the API returns newest first unless `sort=asc` is given. The latest record about the head wins, in both directions: a later `REQUEST_CHANGES` overrides an earlier approval, and a later decision overrides an earlier `REQUEST_CHANGES`. Never relabel a `REQUEST_CHANGES` as `APPROVE`; a verdict belongs to the SHA it judged, and when the head moved, review the difference instead.

1. **Open.** Push the branch, then open a draft against the spec's target:

   ```bash
   glab mr create --draft --yes --target-branch <target> --source-branch <branch> --title "$(cat <title file>)" --description "$(cat <description file>)"
   ```

   Read `glab api projects/:id/merge_requests/<iid>` and require `target_branch` equal to `<target>`, `source_branch` equal to `<branch>` and `source_project_id` equal to `target_project_id`. Anything else, a fork MR included, is not this route: stop and hand over. The candidate is the MR's `sha`, equal to `git rev-parse HEAD` in a clean working tree.
2. **Verify.** Run `cc-tuner:verify-feature` and publish its hand-back as the `cc-tuner-verified: <full sha>` note. Before merging, the verified SHA must be an ancestor of the head: `git merge-base --is-ancestor <verified sha> <head>`. When it is not, verify the current candidate. Fix commits after verification need no new record when `/run`'s evidence-reuse rule says the evidence still covers them. Print every `NOT PROVED` line in the merge report.
3. **Review and verdict.** Under `review: codex`, find the cc-codex-triage install with the `plugin-here.sh` path that `/run`'s Delivery paragraph names (the install directory is the first field of its row), then run `bash <install>/scripts/review-state.sh check <thread>` in the candidate worktree. Require the 7-field marker `CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<head> tree=… base_sha=… spec_path=…` with `head` equal to the MR's `sha` and to `git rev-parse HEAD` of the candidate worktree; anything else is not an approval. Under `review: none:<reason>`, you judge the candidate after the findings are fixed or refuted. Either way, publish the `cc-tuner-verdict` note for the SHA that was judged, immediately. The latest record about the head must be an `APPROVE`, or, under `none`, a `cc-tuner-accepted` note.
4. **Record the spec's DoD** in an MR note published from a file, not in a commit: a commit moves the reviewed SHA.
5. **Approvals.** Read `glab api projects/:id/merge_requests/<iid>/approvals`: `approved` must be true, or `approvals_left` 0. Otherwise stop and ask a human to approve in GitLab, under `--auto` too: a required approval is a person's decision, and no note of yours stands in for it.
6. **CI.** Run `glab mr update <iid> --ready` when the MR is a draft, then wait for the pipeline that starts. Read `head_pipeline` from `glab api projects/:id/merge_requests/<iid>`. Green means all of: `head_pipeline` exists; `head_pipeline.project_id` equals `target_project_id`; it belongs to the current head (`head_pipeline.sha` equals the head, or, for a merged-results pipeline whose `ref` is `refs/merge-requests/<iid>/merge`, the second parent of that merge-result commit, `git rev-parse <pipeline sha>^2` after fetching the ref, equals the head); and it has status `success`. Pending, running, manual, canceled, failed, skipped and absent are not green: an absent pipeline is unproven CI, not passing CI. Under `ci: none:<reason>` there must be no pipeline on the head at all (a waiver covers CI that does not exist, never CI that ran) and a `cc-tuner-local-ci: <full sha> <command and result>` note for the head, written by you and truthful about what ran.
7. **Target.** The target is the MR's `target_branch`. Run `git fetch <remote> <target>`, where `<remote>` is the one `host.sh` named, then `git merge-base --is-ancestor <target tip> <head>`, with the tip read from `<remote>/<target>`. When it is not an ancestor, the target advanced past the candidate: integrate it, re-verify the affected evidence, obtain approval for the new candidate, and restart from step 2 for the new head.
8. **Merge, pinned.** Right before merging, re-read the head, the target tip and the records. When any differs from what steps 2 to 7 judged, restart from the step that covers it. Then:

   ```bash
   glab mr merge <iid> --sha <head> --auto-merge=false --yes
   ```

   The strategy is set, never left to the MR's or the project's default: glab sends `squash` only when it
   is true, so an MR whose squash setting is on would squash a `merge: merge` candidate. Before the merge,
   read the project's `squash_option` (`glab api projects/:id`): `always` with `merge: merge`, or `never`
   with `merge: squash`, stops and goes to the user. Otherwise set it on the MR and read it back —
   `glab api --method PUT "projects/:id/merge_requests/<iid>" -F squash=<true for squash, false for merge>`,
   then `squash` in `glab api projects/:id/merge_requests/<iid>` must equal it. Add `--squash` to the
   merge command when the spec says `merge: squash`. `--sha` makes GitLab refuse a head that moved; `--auto-merge=false` stops it queuing a merge on a pipeline nobody checked. Do not pass `--remove-source-branch`: cleanup is keyed on the merged head below.

   Under `--auto`, run it. Without `--auto`, the hand-over is this whole step: give the user the re-read (head, target tip, the latest records, approvals, the pipeline) together with the pinned merge command, never the merge line alone, and keep delivery pending until the merge is observed. `--check-only` runs steps 1 to 7 and stops here.
9. **After the merge.** Confirm with `glab mr view <iid>` that the state is `merged`, then sync the target and clean up through `cc-tuner:task-flow`, keyed on the merged head: delete a task branch or worktree only while its tip is still that head.
