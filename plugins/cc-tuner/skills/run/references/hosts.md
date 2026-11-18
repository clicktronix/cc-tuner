# Delivery host and route

For a delivery run, use the same check in each participating checkout at startup and before publishing.
An explicitly local-only run needs only its local base and plan.
`host.sh` reports the host, detection method, remote and login hostname. The preflight uses
`host.sh --delivery` to resolve the effective fetch and push URLs. It checks that the remote points to
one repository for both operations, then checks the spec's host, route block and CLI login:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/route.sh" preflight <spec-host>
```

A missing `host:` in an older spec means `github`. A nonzero result blocks delivery. Report it
once and continue local implementation and verification with the known base. Recheck before any
dependent host operation. Resolve an unknown base first if it affects what should be built.

The final line of a successful preflight is tab-separated: `destination <remote> <hostname> <project>`.
Use those fields as `DELIVERY_REMOTE`, `DELIVERY_HOST` and `DELIVERY_PROJECT` for the current checkout.
Use `"$DELIVERY_REMOTE"` explicitly in Git fetch and push commands, and push only the candidate branch. When the remote has multiple push
URLs or one that points to a different repository, select a remote whose fetch and push URLs reach
the same project. Different protocols or a resolved SSH alias work when they identify the same
forge repository.

For GitHub, pass `--repo "$DELIVERY_HOST/$DELIVERY_PROJECT"` to every `gh pr` command during delivery,
including PR creation, verdict and verification comments, ready and post-merge confirmation. Use
the PR number from that repository. For REST calls, pass `--hostname "$DELIVERY_HOST"` and use explicit
`repos/$DELIVERY_PROJECT/…` paths for repo endpoints. Keep the selected remote in
`CC_TUNER_REMOTE` for `merge.sh` and when handing over a checked merge command.

- `ambiguous`: use the remote the task identifies (`CC_TUNER_REMOTE=<name>` for host detection and
  delivery commands). Git's `branch.<name>.pushRemote` and `remote.pushDefault` also select it.
  Ask for the destination only when it is still unknown and needed.
- A host mismatch needs the agreed destination reconciled with the spec. If the self-hosted forge
  login is missing, authenticate to its known hostname and detect again.
- For a missing login, report the printed `gh auth login --hostname` or `glab auth login --hostname`
  command. For a missing route, use `/cc-tuner:setup install delivery-route`. For a stale or malformed
  block, have the repository owner repair it on the target; rerun the preflight.
- `github`: after `none-needed` and a successful login, follow [delivery.md](delivery.md).
- `gitlab`: follow [route-gitlab.md](route-gitlab.md). `local`: follow [route-local.md](route-local.md).
  Read the plugin's copy, never the repository's. Wherever [delivery.md](delivery.md) names a GitHub command
  (open the PR; publish the verdict, accepted, verified, DoD and local-ci records; mark ready;
  `merge.sh`), do the route's step instead, with the same gates, order and record lines.
- `other`: the route is the block's body as committed on the target: `git fetch <remote> <target>`
  with the remote host.sh printed, then `git show FETCH_HEAD:.claude/rules/task-flow.local.md`. Stop
  when the candidate's copy differs, since a candidate never edits its own gate, and when a step
  reads "not described".

`--check-only` means running every route step up to the merge and handing over the merge command.
`--auto` is allowed on every host.

## Host `local`

There is no remote: no push, fetch or pull, and the target is `refs/heads/<target>`. Fetching the
target in Prepare the candidate, and the push and PR of delivery.md step 1, do not apply. The spec says
`ci: none:<reason>` (there is no pipeline) and `merge: ff`, since the local route only fast-forwards.

## Writing the spec

Record the detected host in the spec. If the destination is unresolved but the local base is known,
record `host: pending` and `auto_ready: no`. Resolve it before delivery. On `other`,
`/cc-tuner:setup install delivery-route` records the owner's route. Use `board: none` outside GitHub.
