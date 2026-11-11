# Delivery route: local

`/cc-tuner:run` follows this file at Delivery for a `host: local` spec: a repository with
no remote and no pull request. No script checks these steps for you, so run every one, in order: verify, review, verdict, CI,
merge. The candidate is a branch tip, and nothing here pushes, fetches or pulls: the target is
`refs/heads/<target>`.

A failing step is a stop: fix its cause or hand over to the user, never edit or skip this route to get past
it. A `.claude/execute-task-runs/*.state.json` in the repository is run state from a removed runtime: refuse
delivery, as `merge.sh` does, and tell the user to finish that run under the plugin version that created it
or to delete the directory.

**Records.** A record is a paragraph of a git note in the `cc-tuner` notes ref, on the commit it judges. Its
first line is one of these, naming the full 40-character SHA of that commit:

```text
cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <full sha>
cc-tuner-verified: <full sha>
cc-tuner-local-ci: <full sha> <command and result>
cc-tuner-accepted: <head sha> <who>: <what>
```

A `cc-tuner-verified` record continues, in the same paragraph, with verify-feature's criterion lines, one per
criterion, tagged `[browser]`, `[api]`, `[test]` or `[cli]`, or marked `NOT PROVED`. `cc-tuner-accepted` is
the user's decision to merge without an approval, recorded only after they gave it in this session, and
counts only under `review: none:<reason>`.

Write each record to a file with a quoted heredoc, so backticks and `$(...)` in it stay text, and append it
from the file:

```bash
REC=$(mktemp) && cat > "$REC" <<'EOF'
cc-tuner-verdict: APPROVE <full sha>
EOF
git notes --ref cc-tuner append -F "$REC" <judged sha>
```

A commit has one note, and each `append` adds a paragraph to it: read it with
`git notes --ref cc-tuner show <sha>` and treat each paragraph as one record. The last matching paragraph
wins, whatever it says. A verdict belongs to the commit it judged: when the head moved, review the
difference, and never relabel a `REQUEST_CHANGES` as `APPROVE`.

The notes are the audit trail, not the decision. The merge decision is the verdict you made in this session;
an `APPROVE` note you did not write here is not one, since tests and anyone with the clone can write notes.
Notes live in this clone only: say so when handing the result over.

1. **Candidate.** The branch's exact head SHA (`git rev-parse HEAD` in the candidate worktree), with a clean
   working tree.
2. **Verify.** Run `cc-tuner:verify-feature` and record its hand-back as `cc-tuner-verified: <full sha>` on
   the commit it verified. Find the records on the candidate's commits with
   `git log --notes=cc-tuner --format='%H%n%N' <target>..<candidate>`: the verified SHA must be one of them,
   which makes `git merge-base --is-ancestor <verified sha> <candidate>` hold. Otherwise verify the current
   candidate. Print every `NOT PROVED` line in the merge report.
3. **Review and verdict.** Under `review: codex`, take the cc-codex-triage install directory from the first
   field of `bash "<plugin root>/scripts/setup/plugin-here.sh" cc-codex-triage@cc-codex-triage` and
   run `bash <install>/scripts/review-state.sh check <thread>` in the candidate worktree. Only the 7-field
   marker `CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<head> tree=… base_sha=… spec_path=…`,
   with `head` equal to the candidate and to the worktree's `git rev-parse HEAD`, is an approval. Under
   `review: none:<reason>`, you judge the candidate once the findings are fixed or refuted. Either way,
   record the `cc-tuner-verdict` for the judged commit at once. The latest record about the head must be an
   `APPROVE`, or, under `none`, a `cc-tuner-accepted` record.
4. **CI.** There is none: the CI mode is always `ci: none:<reason>`. Run the spec's local checks on the
   candidate and record `cc-tuner-local-ci: <full sha> <command and result>` on the head, truthful about
   what ran and what it returned. No record means unproven CI.
5. **Target.** Read the target tip (`git rev-parse refs/heads/<target>`) and require
   `git merge-base --is-ancestor <target tip> <candidate>`. When it fails, the target advanced: integrate it
   into the branch, re-verify the affected evidence, get approval for the new candidate and restart from
   step 2.
6. **Merge, fast-forward only.** This route only fast-forwards, so `merge: squash` cannot apply: stop and say
   that `/spec` writes `merge: ff` for a `local` host; the user changes the spec, or squashes the branch and
   runs steps 2 to 5 for the squashed commit. Right before merging, re-read the candidate, the target tip
   and the records; when any changed, restart from the step that covers it. Find the worktree that has the
   target checked out (`git worktree list --porcelain`):
   - a clean worktree has it: run `git merge --ff-only <candidate>` there;
   - no worktree has it: run `git update-ref refs/heads/<target> <candidate> <old target tip>` with the tip
     step 5 checked. Git refuses when the target moved; then restart from step 5;
   - a dirty worktree has it: leave it alone. Hand the merge to the user with the exact command,
     `git -C <that worktree> merge --ff-only <candidate>`, and keep delivery pending until it is observed.

   Never create a squash or merge commit on the target. Under `--auto`, run the merge. Without `--auto`,
   the hand-over is this whole step: the re-read (candidate, target tip, latest records) with the merge
   command, never the merge line alone. Delivery stays pending until the merge is observed. `--check-only`
   stops here, after step 5.
7. **After the merge.** Confirm `git rev-parse refs/heads/<target>` equals the candidate, then clean up
   through `cc-tuner:task-flow`, keyed on the merged head: delete the task branch or worktree only while its
   tip is still that head.
