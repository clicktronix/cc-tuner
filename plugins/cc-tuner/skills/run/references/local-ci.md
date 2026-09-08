# Candidate CI policy

Read when choosing the spec's `ci` mode or preparing delivery. Inspect repository policy, workflows
and the checks attached to the candidate; trigger type alone does not decide whether CI exists.

- `required` (default): the target defines required checks; all those checks must pass.
- `any`: no required checks are configured; every reported check must pass. Use this for applicable
  push or manual workflows too; dispatch an authorized non-deploy validation workflow when needed.
- `none:<reason>`: no hosted candidate checks are available. Record why and the local substitute in
  the spec. `merge.sh` permits it only with zero reported checks and the exact-SHA comment below.

Pending, paused, failed and unreadable checks are not absent checks. Do not use `none` to bypass them.
If observation contradicts the spec, correct its mode before candidate review. Follow repository
policy about which workflows to run; CI dispatch does not authorize deployment or publishing.

For `none`, publish the actual local result before preflight/merge:

```bash
gh pr comment <pr> --body "cc-tuner-local-ci: <candidate-sha> <the command that ran, and what it returned>"
```

Use a comment: `gh pr edit --body` replaces the description. This is an attributable claim, not
independent execution evidence: the script checks the record, but does not rerun its command.
