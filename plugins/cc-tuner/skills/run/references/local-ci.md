# Delivery when the spec declares `ci: none`

Use `none:<reason>` only for a repository with no hosted PR checks. If checks exist, correct the
spec and use the applicable mode; do not drop the CI flag. `merge.sh` refuses `none` when any check
exists, and also requires a PR comment recording the local result for the exact candidate:

```bash
gh pr comment <pr> --body "cc-tuner-local-ci: <candidate-sha> <the command that ran, and what it returned>"
```

Use a comment: `gh pr edit --body` replaces the description. Record real commands and results,
never placeholders. This is an attributable claim, not independent execution evidence: the merge
script checks the record, but does not rerun its command. It does not make `none` equivalent to CI.
