---
description: Opt the current repo into (or out of) the smoke-verify Stop-hook gate that blocks unverified frontend changes. Use for "включи smoke-verify", "set up smoke verification", or checking why the gate blocks.
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
4. Look at the repo's layout and **tune `patterns=` to it** (e.g. a Next.js repo with logic-bearing `.ts` route handlers under `app/` may want `|(^|/)app/.*\.tsx?$` appended; a backend-only repo should not install this at all). Show the user the final regex.
5. Git-ignore the state dir (attestations are local operational artifacts):
   ```bash
   grep -qxF '.claude/smoke-verify/' .gitignore 2>/dev/null || echo '.claude/smoke-verify/' >> .gitignore
   ```
   The config file itself (`.claude/smoke-verify.cfg`) IS committable — it is team policy, like lint config. Leave committing to the user.
6. Confirm: the gate engages at the end of any turn with unverified matched changes, releases on `mark.sh verified|skip` attestation for exactly that delta, and fails open after `cap` blocks. Hooks load on restart or `/reload-plugins` if the plugin was just installed.

## status

Run and show:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/smoke-verify/mark.sh" status
```

## remove

From the repo root: `rm -f .claude/smoke-verify.cfg && rm -rf .claude/smoke-verify` and confirm. (The `.gitignore` line is harmless to keep; mention it.)
