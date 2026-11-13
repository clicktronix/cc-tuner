# Guard surface spike — which surface can stop an action for the agent

Spec: `docs/ARCHIVE/PLANS/2026-11-13-session-coordination.md` (Guard surface). Question: does the guard of #73
run as the `register.ts` module, or as `PreToolUse`/`PostToolUse` command hooks calling `peers.sh check`?

**Method.** Two disposable plugins, one per surface, in a scratch git repository, driven with
`claude -p --model haiku --plugin-dir … --setting-sources project,local --output-format stream-json
--verbose` (one scratch repo copy per run, `< /dev/null`). The module variant is `on('tool.call',
{ tool: 'Bash' })` plus `session.start`/`session.end`; the hook variant is `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `SessionStart`, `SessionEnd` command hooks. A third plugin logs the
`PermissionRequest` hook, which fires where an interactive session would draw the permission dialog.
Every probe logs variable names and pids only, never token values. Everything is MEASURED on the CI pin
**Claude Code 2.1.306** (`npm i @anthropic-ai/claude-code@2.1.306` in a scratch prefix) unless a line
says 2.1.323 (the machine's `~/.local/bin/claude`). The harness lives in the session scratchpad and is
not committed.

## 1. A deny reaches the model and no prompt is raised, in default and bypass mode

- Observed: 2.1.306, `--permission-mode default` and `--dangerously-skip-permissions`, prompt "run
  exactly `git switch -c t`", surface denies any `git switch` without an ack.
  - Module: the tool result is `is_error: true`, `<tool_use_error>SPIKE-DENY-MODULE: git switch stopped; owner is peer pid 4242; …</tool_use_error>`;
    `permission_denials: []`; same in bypass.
  - Hook (`hookSpecificOutput.permissionDecision: "deny"` + reason): `is_error: true`,
    `PreToolUse:Bash hook error: SPIKE-DENY-HOOK: git switch stopped; …`; same in bypass. The SDK
    result lists the call under `permission_denials` for the hook only.
  - The agent's final text quotes the reason in all four runs.
- Observed: control, same prompt, no deny, default mode: `This command requires approval`, and the
  `PermissionRequest` observer logged `tool=Bash cmd=git switch -c t`. In the four deny runs that
  observer logged nothing, so the deny is decided before the permission step on both surfaces.
- Not proved: `-p` cannot draw a dialog, so "the user sees no prompt" rests on the `PermissionRequest`
  observer. The `[eyes]` check in the spec still stands.
- Observed, weakly (the prompt said "exactly this command"): haiku read "pass with
  `CC_TUNER_ACK=key`" and handed the decision to the user instead of re-running with the ack. The stop
  reason has to say the choice is the agent's.

## 2. How the surface learns its Claude pid; whether it sees a call's result

- Observed: 2.1.306 and 2.1.323, `-p`, command hook. `$PPID` of the hook script and `$CLAUDE_PID` are
  the same number, and it is the `claude` process (ancestry by `ps -o pid=,ppid=,comm=`: the script's parent is the `claude` pid, whose parent is
  the launcher). The Bash tool's own `echo CLAUDE_PID=$CLAUDE_PID PPID=$PPID`
  prints the same pair on both versions. `ps -o lstart= -p <pid>` gives a start time to the second
  (`Sat Nov 14 00:07:21 2026`).
- Observed: 2.1.306 and 2.1.323, module. No `process`, no `require`; `$.env.get('CLAUDE_PID')` is unset
  in a top-level session, so the pid comes from a child:
  `$.process.run(['/bin/sh','-c','echo $PPID'])` returns the `claude` pid, equal to the hooks' `$PPID`.
  `$.process.run` also takes `stdin`, `env` and `cwd`; a `bash -c 'cat; echo $SPIKE_X; basename $PWD'`
  probe echoed all three.
- Observed: nested `claude -p` launched from a Bash tool call (2.1.306 inside 2.1.306). The nested
  session has its own pid and its own `session_id`; its hooks get `CLAUDE_PID` = the nested pid, and
  the ancestry of the hook or of a module child contains a second `claude` (the outer one) above the
  Bash tool's shell. A module in the nested session also sees `$.env.get('CLAUDE_PID')` = the outer
  pid (inherited), which a top-level module does not. The two flags in the environment do not mark a
  nested run: `CLAUDE_CODE_CHILD_SESSION=1`, `CLAUDE_CODE_SESSION_ATTENDED=0`, `CLAUDE_CODE_ENTRYPOINT=sdk-cli`
  for every `-p` session, nested or not. So "a nested `claude -p` counts as its parent" needs an
  ancestry walk to the outermost `claude` on either surface.
- Observed: subagent calls. A subagent's Bash call reaches the hook with `agent_id` and the module
  with `agentId`, on the same `claude` pid.
- Interactive: NOT observed from a started session (a fresh directory needs the trust dialog, which
  would write `~/.claude.json`). Evidence from this interactive session instead: the Bash tool's
  `CLAUDE_PID` equals `$PPID` equals the interactive `claude` pid (2.1.323 on this machine),
  `claude agents --json` lists that pid with `kind: "interactive"`, and `~/.claude/sessions/<pid>.json`
  carries `pid`, `procStart`, `sessionId`, `kind` (key names only; undocumented file). Hooks and
  module children are spawned by the same process in `-p` and interactive mode, so the pid rule is
  expected to hold; that is inference, not observation.
- Background: NOT started. `claude --bg` on 2.1.306 refuses an untrusted directory ("Workspace not
  trusted … accept the trust prompt"), which needs a TTY. Documented only: `claude agents --json`
  (2.1.306 and 2.1.323) rows of `kind: "background"` carry `cwd,id,kind,name,sessionId,startedAt,state`
  and no `pid`; interactive rows carry `pid` and `status`.
- Observed, result visibility, 2.1.306 (2.1.323 checked with `echo` and `false`, same):
  - Hook: `PostToolUse` carries `tool_response` with `stdout`, `stderr`, `interrupted`; a non-zero
    exit does not fire it. `PostToolUseFailure` fires instead, with `error: "Exit code 1"` and no
    stdout. Pre and post are separate processes joined by `tool_use_id`.
  - Module: after `const ran = await next(e)`, success has `ran.result.stdout`; failure has
    `ran.isError === true` and `ran.result` a string (`Exit code 1\nout\nls: …`). One closure holds
    the state from before and after the call.

## 3. Does a `CC_TUNER_ACK=` prefix still match `Bash(git switch:*)`

- Observed: 2.1.306, `--permission-mode default --allowedTools 'Bash(git switch:*)'`, no surface,
  two calls `CC_TUNER_ACK=x git switch -c t` and `git switch -c t2`: the first is
  `This command requires approval` (the `PermissionRequest` observer logged it, `permission_denials`
  lists it); the second runs (`Switched to a new branch 't2'`). **The prefix breaks the allow rule**,
  so a bare ack would raise a prompt in an interactive session.
- Observed: same prompt, a surface that strips the prefix before the call:
  - Module `next({ ...e, command: cmd.replace(/^CC_TUNER_ACK=\S+ /, '') })`: both commands run, branches
    `t` and `t2` exist, `permission_denials: []`, no `PermissionRequest`.
  - Hook `hookSpecificOutput: { hookEventName: "PreToolUse", updatedInput: { command: … } }` with no
    `permissionDecision`: the same result.
  - On both surfaces the permission rules are evaluated on the rewritten command, and the surface
    still saw the original command with the ack, so it can record the ack before stripping it.

## 4. SessionEnd, decision latency, module access to the record store and `ps`

- Observed: 2.1.306, `-p` run to the end: the `SessionEnd` command hook and the module's
  `session.end` both fire, `reason: "other"`. After `kill -TERM <claude pid>` during a running Bash
  call (`perl -e 'sleep 45'`, exit 143): both still fire (`reason: "other"`; hook 475 ms after the
  signal, module 499 ms). SIGKILL was not run; nothing can run then, so liveness by pid plus start
  time stays the source of truth and SessionEnd only an early hint.
- Observed: module reads a file outside the plugin and the cwd (`$.fs.read` of an absolute path:
  `{"note":"record store probe",…}`) and runs `ps -o lstart= -p <pid>` through `$.process.run`.
- Observed latency, 2.1.306, five Bash calls each, same decision work (`python3 -c pass`):

  | | per decision | after the decision until the tool starts |
  |---|---|---|
  | module, `$.process.run(['python3','-c','pass'])` | 28, 27, 26, 25, 28 ms | 21, 21, 20, 23 ms (first call 169 ms) |
  | hook, bash script + `python3 -c pass` + one `perl` timestamp | 42, 45, 43, 40, 41 ms | 22, 21, 21, 21 ms (first call 195 ms) |

  Standalone on this machine: `python3 -c pass` 25 ms, `bash -c 'exit 0'` 3 ms, module `fs.read`
  1 to 7 ms. The first call of a session is slow on both (cold start). The decision cost on both
  surfaces is the cost of what the guard spawns (`peers.sh`: bash plus python3), within about 3 ms of
  each other and far inside the 150 ms budget. The time between the model's tool call and the hook or
  module starting was not separable from outside, so it is not claimed.

## 5. The pin

- `plugins/cc-tuner/tests/flow/CLAUDE_CODE_VERSION` stays `2.1.306`: every observation above needed
  only 2.1.306. 2.1.323 was used for a second sample of the pid and result facts and agreed.

## Decision

**The `register.ts` module.** Both surfaces deny without a prompt in default and bypass mode, learn
the `claude` pid, see subagent calls, fire at session end, read files and run `ps`, strip the ack
prefix, and cost the same. The module wins on four facts:

1. One closure sees the call before and after, including a failed call (`isError`, the error text),
   so "HEAD read before and after this session's own call" and "recorded only after a successful
   call" need no state hand-off. Hooks split it over `PostToolUse`, `PostToolUseFailure` and a join
   on `tool_use_id` across processes.
2. `commands()` and the unwrap of `heavy.sh --`, `bash -c`, `env`, `xargs`, `cd x &&`, `$(...)` stay
   in TypeScript next to the existing guard; the hooks route would port that parser to bash or python.
3. The stop text reaches the agent as a plain `<tool_use_error>` reason; the hook form is prefixed
   `PreToolUse:Bash hook error:` and counted as a permission denial.
4. The secret-leak deny already lives in this module, so both guards sit in one ordered chain.

Cost accepted: the pid takes one `$.process.run(['/bin/sh','-c','echo $PPID'])` per module load, module
variables do not survive a reload (state stays in the record store, as designed), and the guard needs
`$.process.run(['bash', peers.sh, 'check'], { stdin, env, cwd })`.

## Consequences for slices 3–5

- **Slice 3.** The adapter is the `tool.call` hook in `register.ts` (Bash, Edit, Write, TaskStop, MCP
  tools); `peers.sh check` is called with `$.process.run` and its decision JSON on stdin. The Claude
  pid is the `$PPID` of that child, resolved once per module load; set `CC_TUNER_PEERS_CLAUDE_PID`
  from it. The hooks.json inventory assertion needs no `PreToolUse`/`PostToolUse` entry; `test_mod.sh`
  and `register.test.ts` carry the adapter tests.
- **Ack (slices 3–4 wording).** A bare `CC_TUNER_ACK=<key> <command>` raises a permission prompt when
  the user allows the command by a prefix rule. The adapter must record the ack and rewrite the
  command without the prefix (`next({ ...e, command })`) so the rule matches. Say this in the stop
  reason's way on ("the same command prefixed `CC_TUNER_ACK=<key>`") and in the README.
- **Nested `claude -p`.** The record's session is the outermost `claude` in the ancestry; neither
  environment flags nor `CLAUDE_PID` identify it. A subagent shares the parent's pid, so the
  `agentId` need not enter the record key.
- **Stop reason.** Haiku handed the decision to the user when it read the ack hint. The reason says
  that re-running with the ack is the agent's call, not a question for the user.
- **Unproved, carry to the `[eyes]` check.** Interactive and background pid reads, the absence of a
  rendered dialog, and an ack's effect under a user's real allow rules in an interactive session.
