---
description: Opt the current repo into (or out of) the smoke-verify Stop-hook gate that blocks changes nobody exercised. Rules are per-repo: a screen, a migration and an endpoint each declare what proves them. Modes: install, status, remove.
argument-hint: '[install|status|remove]'
allowed-tools: Bash, Read, Write, Edit
disable-model-invocation: true
---

# /cc-tuner:smoke-verify-setup

The smoke-verify gate is **per-repo opt-in**: the plugin's Stop hook only
engages where `.claude/smoke-verify.cfg` exists. This command installs,
inspects, or removes that opt-in. Mode from `$ARGUMENTS` (default `install`).

## install

1. Anchor: `cd "$(git rev-parse --show-toplevel)"`. Not a repo → tell the user and stop.
2. If `.claude/smoke-verify.cfg` already exists, show it and ask whether to keep or overwrite — never silently clobber a tuned `patterns=`.
3. Copy the template:
   ```bash
   mkdir -p .claude
   cp "${CLAUDE_PLUGIN_ROOT}/assets/smoke-verify/config.template.cfg" .claude/smoke-verify.cfg
   ```
4. Look at the repo's layout and **write its rules**. The template ships three (`ui`, `migration`, `api`) as shapes to edit, not as defaults to keep: delete the ones this repository has no such changes for, rename and re-pattern the rest, and add what is missing (a background job, a contract or schema file, an infrastructure manifest, a generated artifact).

   For every rule, `counts.<rule>` has to name **a concrete act against the running thing** — the block message the agent receives is exactly this text, and vague text is how a green typecheck becomes an attestation. If you cannot write it concretely, say so to the user rather than shipping a rule that demands something nobody can perform.

   Show the user the final rule list: for each one, its pattern, what counts, and what does not.
5. Git-ignore the state dir (attestations are local operational artifacts):
   ```bash
   grep -qxF '.claude/smoke-verify/' .gitignore 2>/dev/null || echo '.claude/smoke-verify/' >> .gitignore
   ```
   The config file itself (`.claude/smoke-verify.cfg`) IS committable — it is team policy, like lint config. Leave committing to the user.
6. Confirm: the gate engages at the end of any turn with matched-but-unattested changes, releases **per rule** on a `mark.sh verified|skip <rule>` attestation for exactly that rule's delta, and fails open after `cap` blocks per rule. Hooks load on restart or `/reload-plugins` if the plugin was just installed.

## status

Run and show:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/smoke-verify/mark.sh" status
```

## remove

From the repo root: `rm -f .claude/smoke-verify.cfg && rm -rf .claude/smoke-verify` and confirm. (The `.gitignore` line is harmless to keep; mention it.)

## Mechanics and limits

There is no `smoke-verify` skill: the verification standard — what counts, and the DOES-NOT-COUNT list
that is the whole point of the gate — is inlined in the hook's block message, so an agent being told
to stop receives it rather than having to choose to load it. What follows is the operator-facing
detail, which belongs here because this is the command someone runs when asking "why is this blocking".

- **Rules.** `patterns.<rule>` / `counts.<rule>` / `excludes.<rule>` in the config. A bare `patterns=`
  from a pre-rules install still works, as the rule named `default`, and keeps its old state paths so
  the upgrade does not throw an existing attestation away.
- **One rule, one attestation.** A delta that matches two rules blocks until both are attested, and
  `mark.sh` refuses an un-named attestation in that case rather than applying one evidence line to
  both. "I ran the tests" is not proof that the migration was applied, and the refusal is the point.
- **State.** `.claude/smoke-verify/state[.<rule>]` (the attestations) and
  `.claude/smoke-verify/blocks[.<rule>]` (the cap counters) — git-ignored, machine-local.
  `.claude/smoke-verify.cfg` is committable team policy.
- **Fail-open cases.** After `cap` blocks (default 3) on an unchanged delta, per rule; on a malformed
  blocks counter, for that rule only; outside a git repo; and on a detached HEAD, where `rev-parse --abbrev-ref` yields the
  literal `HEAD` and there is no stable scope to bind an attestation to. A corrupted attestation file
  merely fails to release, and the cap bounds that.
- **Scope limit.** The fingerprint covers **uncommitted** changes only, so a change committed mid-turn
  without attesting leaves the gate's scope entirely. The discipline is procedural: verify → attest →
  commit. The block message says this too.
- **Re-arming.** An attestation binds to one rule's exact delta (branch plus worktree-content
  fingerprint over that rule's matched paths). Editing a matched file re-arms that rule alone; staging or committing the same content does not.
- `bash "${CLAUDE_PLUGIN_ROOT}/scripts/smoke-verify/mark.sh" status` prints every rule, what it
  matches right now, its attestation, and whether it would block.
