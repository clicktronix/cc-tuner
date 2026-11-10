# Candidate CI policy

Read when choosing the spec's `ci` mode or preparing delivery. Inspect repository policy, workflows
and the checks attached to the candidate; trigger type alone does not decide whether CI exists.

- `required` (default): the target defines required checks; all those checks must pass.
- `any`: no required checks are configured; every reported check must pass. Use this for applicable
  push or manual workflows too; dispatch an authorized non-deploy validation workflow when needed.
- `none:<reason>`: no hosted candidate checks are available. Record why and the local substitute in
  the spec; `merge.sh` prints the reason at merge and permits it only with zero reported checks and the
  exact-SHA comment below. Prefer `any` where a workflow can be dispatched by hand.

Pending, paused, failed and unreadable checks are not absent checks. Do not use `none` to bypass them.
Deployment previews that post statuses (Vercel, Netlify) are reported checks: a repository with
them and no required checks uses `any`.
If observation contradicts the spec, correct its mode before candidate review. Follow repository
policy about which workflows to run; CI dispatch does not authorize deployment or publishing.

For `none`, publish the actual local result before preflight/merge:

```bash
REC=$(mktemp) && cat > "$REC" <<'EOF'
cc-tuner-local-ci: <candidate-sha> <the command that ran, and what it returned>
EOF
gh pr comment <pr> --body-file "$REC"
```

Write the record to a file, with a quoted heredoc, and publish it with `--body-file`: the result text often
holds backticks or `$(...)`, which a double-quoted `--body "..."` would run. Use a comment: `gh pr edit --body`
replaces the description. The script checks the record but does not rerun its command.

On a host other than GitHub the `cc-tuner-local-ci` record goes where the host's route reference says
(`route-gitlab.md`: an MR note; `route-local.md`: a git note on the head commit), also published from a file;
with host `local`, `ci:` is always `none:<reason>`.
