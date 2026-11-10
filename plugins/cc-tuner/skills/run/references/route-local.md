# Delivery route: local

`/cc-tuner:run` reads this file from the plugin at Delivery for a `host: local` spec: a repository with no remote and no pull request, delivered in place of `merge.sh`. The repository holds only the key block that `route.sh check` verifies, so a candidate cannot edit its own gate. These are steps you perform and no script refuses on your behalf: a skipped step merges an unchecked candidate, so run them in order. The order is the GitHub gate's: verify, review, verdict, CI, merge. The candidate is a branch tip, and nothing here pushes, fetches or pulls: the target is read as `refs/heads/<target>`.

A failing step is a stop. Fix its cause or hand over to the user; never edit, reword or skip this route to get past it. A `.claude/execute-task-runs/*.state.json` in the repository is run state from a removed runtime: refuse delivery, as `merge.sh` does, and tell the user to finish that run under the plugin version that created it or to delete the directory.

**Records.** A record is a paragraph of a git note in the `cc-tuner` notes ref, on the commit it judges. Its first line is one of these, naming the full 40-character SHA of the commit the note sits on:

```text
cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <full sha>
cc-tuner-verified: <full sha>
cc-tuner-local-ci: <full sha> <command and result>
cc-tuner-accepted: <head sha> <who>: <what>
```

A `cc-tuner-verified` record continues, in the same paragraph, with verify-feature's criterion lines, one per criterion, tagged `[browser]`, `[api]`, `[test]` or `[cli]`, or marked `NOT PROVED`. `cc-tuner-accepted` is the user's decision to merge without an approval, recorded only after they gave it in this session, and counts only under `review: none:<reason>`.

Write a record to a file first, with a quoted heredoc so that backticks and `$(...)` in a criterion line stay text, then append it from the file:

```bash
REC=$(mktemp) && cat > "$REC" <<'EOF'
cc-tuner-verdict: APPROVE <full sha>
EOF
git notes --ref cc-tuner append -F "$REC" <judged sha>
```

Never put a record inline in a double-quoted `-m`. A commit has one note, and each `append` adds a blank-line-separated paragraph to it, so a note holds several records: read them with `git notes --ref cc-tuner show <sha>` and treat each paragraph as one record. The last paragraph that matches wins, in both directions: a later `REQUEST_CHANGES` overrides an earlier approval, and a later decision overrides an earlier `REQUEST_CHANGES`. Never relabel a `REQUEST_CHANGES` as `APPROVE`; a verdict belongs to the commit it judged, and when the head moved, review the difference instead.

The notes are the audit trail, not the decision. The merge decision is the verdict you made in this session; a note that says `APPROVE` and that you did not write here (a test can write notes, and so can anyone with the clone) is not one. Notes live in this clone only: say so when handing the result over.

1. **Candidate.** The candidate is the branch's exact head SHA (`git rev-parse HEAD` in the candidate worktree) with a clean working tree.
2. **Verify.** Run `cc-tuner:verify-feature` and record its hand-back as `cc-tuner-verified: <full sha>` on the commit it verified. Find the records on the commits the candidate adds with `git log --notes=cc-tuner --format='%H%n%N' <target>..<candidate>`. Before merging, the verified SHA must be one of them, which makes it an ancestor of the candidate (`git merge-base --is-ancestor <verified sha> <candidate>`). When it is not, verify the current candidate. Print every `NOT PROVED` line in the merge report.
3. **Review and verdict.** Under `review: codex`, find the cc-codex-triage install with the `plugin-here.sh` path that `/run`'s Delivery paragraph names (the install directory is the first field of its row), then run `bash <install>/scripts/review-state.sh check <thread>` in the candidate worktree. Require the 7-field marker `CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<head> tree=… base_sha=… spec_path=…` with `head` equal to the candidate and to `git rev-parse HEAD` of the candidate worktree; anything else is not an approval. Under `review: none:<reason>`, you judge the candidate after the findings are fixed or refuted. Either way, record the `cc-tuner-verdict` for the commit that was judged, immediately. The latest record about the head must be an `APPROVE`, or, under `none`, a `cc-tuner-accepted` record.
4. **CI.** There is none: the CI mode is always `ci: none:<reason>`. Run the spec's local checks on the candidate and record `cc-tuner-local-ci: <full sha> <command and result>` on the head, truthful about what ran and what it returned. An absent record is unproven CI.
5. **Target.** Read the target tip (`git rev-parse refs/heads/<target>`) and require `git merge-base --is-ancestor <target tip> <candidate>`. When it is not an ancestor, the target advanced past the candidate: integrate it into the branch, re-verify the affected evidence, obtain approval for the new candidate, and restart from step 2 for the new head.
6. **Merge, fast-forward only.** This route only fast-forwards, so `merge: squash` cannot apply: stop and say that `/spec` writes `merge: ff` for a `local` host, and that the user either changes the spec or squashes the branch first, the squashed commit becoming the candidate for a new run of steps 2 to 5. Right before merging, re-read the candidate, the target tip and the records; when any differs from what steps 2 to 5 judged, restart from the step that covers it. Find the worktree that has the target checked out (`git worktree list --porcelain`).
   - A clean worktree has it: run `git merge --ff-only <candidate>` there.
   - No worktree has it: run `git update-ref refs/heads/<target> <candidate> <old target tip>`, where the old tip is the one step 5 checked. It is a compare-and-swap: git refuses when the target moved, and then you restart from step 5.
   - A dirty worktree has it: do not touch it. Hand the merge to the user with the exact command, `git -C <that worktree> merge --ff-only <candidate>`, and keep delivery pending until the merge is observed.

   Under `--auto`, run the merge. Without `--auto`, the hand-over is this whole step: the re-read (candidate, target tip, the latest records) together with the merge command, never the merge line alone, and delivery stays pending until the merge is observed. Never create a squash or merge commit on the target. `--check-only` runs steps 1 to 5 and stops before this one.
7. **After the merge.** Confirm `git rev-parse refs/heads/<target>` equals the candidate, then clean up through `cc-tuner:task-flow`, keyed on the merged head: delete the task branch or worktree only while its tip is still that head.
