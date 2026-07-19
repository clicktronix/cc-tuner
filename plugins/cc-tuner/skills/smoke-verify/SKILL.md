---
name: smoke-verify
description: Use when the smoke-verify Stop hook blocked the turn ("smoke-verify gate", "frontend changes are UNVERIFIED"), when deciding what counts as empirical verification evidence, or when the user asks to set up / disable smoke verification for a repo.
---

# smoke-verify

A Stop-hook gate for repos that opted in via `/cc-tuner:smoke-verify-setup`:
a turn that changed frontend files (per the repo's `.claude/smoke-verify.cfg`
patterns) cannot end until the change was **exercised for real** — because
fix commits that pass typecheck/lint but were never rendered or run are the
top source of "fixed" bugs that aren't.

## What counts as verification (and what does not)

Counts — any ONE of, exercised against the actual change:

- Open the affected page/flow via chrome-devtools MCP (navigate → interact →
  screenshot) and confirm the changed behavior visually.
- Run the exact failing case / affected test file and show it passing
  (a targeted `vitest run <file>` / `pytest -k`, not the whole suite's green).
- Render the actual artifact (PDF, email preview, storybook story) and look
  at it.

Does NOT count: typecheck, lint, a full-suite run that was already green
before the change, "the diff looks correct", or re-reading the code.

## Attesting

After verifying, attest with one line of concrete evidence — what you
exercised and what it showed:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/smoke-verify/mark.sh" verified 'opened /fit page via chrome-devtools, new a11y labels render; screenshot in run dir'
```

Only when the **user explicitly said to skip** verification this turn:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/smoke-verify/mark.sh" skip 'user said "пропусти проверку" for this hotfix'
```

Never attest `verified` on the strength of static checks — that defeats the
gate's purpose and the evidence line will say so in the audit trail. The
attestation binds to the exact delta (branch + content fingerprint): editing
a matched file afterwards re-arms the gate, so verify LAST, after the code
settles.

## Mechanics / limits

- State: `.claude/smoke-verify/state` (attestation), `.claude/smoke-verify/blocks`
  (cap counter) — git-ignored, local-only. Config: `.claude/smoke-verify.cfg`
  (committable team policy).
- The gate fails open after `cap` blocks (default 3) per unchanged delta,
  on malformed state, outside git repos, and on detached HEAD.
- `bash mark.sh status` shows config, current attestation, and whether the
  gate would block right now.
