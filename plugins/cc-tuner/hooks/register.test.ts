import type { AgentSpawnInput, AgentStatus, On, Settings } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import { UNKNOWN } from './peers'
import { steps } from './register'

const END = { sessionId: 's1', resume: { id: 's1' } }

// Stubs Bash (every command comes back with the given background task id, if any), records each
// TaskStop, and lets session.end through.
function stub(on: On, backgroundTaskId?: (command: string) => string | undefined) {
  const stopped: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => ({
    result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: backgroundTaskId?.(e.command) },
  }))
  on('tool.call', { tool: 'TaskStop' }, (_, e) => {
    stopped.push(String(e.task_id))
    return { result: { message: 'stopped', task_id: String(e.task_id), task_type: 'bash' } }
  })
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  return stopped
}

test('a /clear stops the background tasks Bash started', async ($, on) => {
  const stopped = stub(on, command => command)

  await $.tool.call({ tool: 'Bash', command: 'b1', run_in_background: true })
  await $.tool.call({ tool: 'Bash', command: 'b2', run_in_background: true })
  await $.session.end({ ...END, reason: 'clear' })
  expect(stopped.sort()).toEqual(['b1', 'b2'])

  // The ids were spent: a second /clear stops nothing again.
  await $.session.end({ ...END, reason: 'clear' })
  expect(stopped.length).toBe(2)
})

test('a task the agent stopped itself is not stopped again', async ($, on) => {
  const stopped = stub(on, command => command)

  await $.tool.call({ tool: 'Bash', command: 'b1', run_in_background: true })
  await $.tool.call({ tool: 'Bash', command: 'b2', run_in_background: true })
  await $.tool.call({ tool: 'TaskStop', task_id: 'b1' })
  await $.session.end({ ...END, reason: 'clear' })
  // b1 appears once (the agent's own stop); the /clear stops only b2.
  expect(stopped).toEqual(['b1', 'b2'])
})

test('exit leaves stopping to Claude Code', async ($, on) => {
  const stopped = stub(on, () => 'b3')

  await $.tool.call({ tool: 'Bash', command: 'b3', run_in_background: true })
  await $.session.end({ ...END, reason: 'prompt_input_exit' })
  expect(stopped).toEqual([])
})

// Stubs Bash and records every command that got past the guard.
function reached(on: On) {
  const ran: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => {
    ran.push(e.command)
    return { result: { stdout: '', stderr: '', interrupted: false } }
  })
  return ran
}

test('a variable dump is refused however the shell spells it', async ($, on) => {
  const ran = reached(on)
  const dumps = [
    'env', 'printenv', 'set', ' export ', 'export -p', 'declare -x', 'typeset',
    'cd app && env', 'env | grep TOKEN', 'env | cut -d= -f1',
    'env # inspect configured variables', 'printenv 2>/dev/null', 'env -i FOO=1', 'env -u HOME', 'env FOO=1',
    'FOO=1 env', 'command env', 'command -- env', 'exec -a sh env', '(env)', 'echo "$(printenv)"', 'x=`env`', 'true;\\\nenv',
    'cat <<EOF\n$(env)\nEOF', 'cat <<EOF\n`env`\nEOF', 'cat <<EOF\n$(\nenv\n)\nEOF', 'cat <<< "$(env)"', 'cat <<< `env`',
    `printf '%s\\n' "$(printf ')'; env)"`, 'echo "x$(echo "$(env)")"', 'echo `echo \\`env\\``',
    'command -p env', 'command -v env; env', 'command -v "$(env)"',
    "cat <<$(printf EOF)\n\n'$(env)'\n$(printf EOF)", 'cat <<$(printf EOF)\n$(env)\n$(printf EOF)',
    "cat <<$(printf EOF>/dev/null)\n\n'$(env)'\n$(printf EOF>/dev/null)",
  ]

  for (const command of dumps) {
    const { deny } = await $.tool.call({ tool: 'Bash', command })
    expect(deny).toContain("awk 'BEGIN { for (k in ENVIRON) print k }'")
  }
  expect(ran).toEqual([])
})

test('commands that only name variables, set them, or quote the word pass', async ($, on) => {
  const ran = reached(on)
  const allowed = [
    'env FOO=1 cmd', 'env -u HOME cmd', 'printenv HOME', 'printenv NAME | wc -c', 'set -euo pipefail', 'export FOO=1',
    "awk 'BEGIN { for (k in ENVIRON) print k }'", "printf '%s\\n' 'a; env; b'", 'echo "env"', 'git log --grep=env',
    "cat <<'EOF' > notes.md\nrun env first\nset\nEOF", 'cat <<-EOF\n\tenv\n\tEOF\necho done',
    'cat <<EOF\n\\$(env) and \\`env\\`\nEOF', `printf '%s\\n' "$(printf ')')"`, 'echo "\\$(env)"', 'cat <<< "env"',
    'command -v env', 'command -V printenv', 'command -pv env', 'cat <<$(env)\nhello\n$(env)',
    'cat <<"$(env)"\n$(env) stays text\n$(env)', 'cat <<$(cat</dev/null;env)\nhello\n$(cat</dev/null;env)',
  ]

  for (const command of allowed) {
    const { deny } = await $.tool.call({ tool: 'Bash', command })
    expect(deny).toBeUndefined()
  }
  expect(ran).toEqual(allowed)
})

test('printing a .env file is refused, its template is not', async ($, on) => {
  const ran = reached(on)

  for (const command of ['cat .env', 'head -n 5 apps/web/.env.local', "tail '.env.production'", 'cat .env*', 'cat .env 2>/dev/null # peek', 'cat < .env', '< .env cat', 'echo "$(< .env)"', 'cat "$(echo x)" .env']) {
    const { deny } = await $.tool.call({ tool: 'Bash', command })
    expect(deny).toContain("grep -c '^NAME=' ")
    expect(deny).not.toContain('cut -d=')
  }
  const allowed = ['cat .env.example', 'cat src/environment.ts', "echo 'cat .env'"]
  for (const command of allowed) await $.tool.call({ tool: 'Bash', command })
  expect(ran).toEqual(allowed)
})

test('a dump or a .env read whose output does not reach the transcript passes, and one behind a shell is read as the command it runs', async ($, on) => {
  const ran = reached(on)
  // Sent to a file, or piped into a command that prints none of it.
  const quiet = ['env > /dev/null', 'env > vars.txt', 'env >> vars.txt', 'printenv &> all.txt', 'env 1>/dev/null', 'env | wc -l', 'env | grep -c TOKEN',
    'env | grep -q ^CI=', 'printenv | grep -qc X', 'if env | grep -q CI; then echo ci; fi', 'env -0 | wc -c', 'export -p | grep --count KEY', '(env) | wc -l',
    'echo $(env | wc -l)', 'cat .env > /dev/null', 'cat .env >> .env.backup', 'cat .env | wc -l', 'cat < .env > copy', 'cat .env | grep -c ^KEY=',
    "bash -c 'env | wc -l'", "sh -c 'cat .env' > /dev/null", 'cat .env.schema', 'cat docs/.env.md', 'head -5 app/.env.local.md',
    'env FOO=1 node app.js', 'env FOO=1 cat .env.example', 'env -i PATH=/bin true', 'env -i', 'env --ignore-environment', 'env -']
  for (const command of quiet) expect((await $.tool.call({ tool: 'Bash', command })).deny, command).toBeUndefined()
  expect(ran).toEqual(quiet)
  // Still printed: only stderr is sent away, the reader of the pipe prints what it reads, a capture is printed later,
  // or a shell runs the same command.
  const loud = ['env 2>/dev/null', 'env 2> err.txt', 'env | grep TOKEN', 'env | grep -v X', 'env | sort | wc -l', 'env | tee vars.txt', 'env > /dev/null; env',
    'env | wc -l; printenv', 'x=$(printenv); echo ${#x}', 'echo "$(env)" | wc -l', 'cat .env 2>/dev/null', 'cat .env | tee copy', 'cat .env | cut -d= -f1',
    'bash -c "cat .env"', 'sh -c env', "bash -lc 'printenv'", 'zsh -c "head -3 .env.local"', '/bin/bash -c env', "bash -c 'bash -c env'", '/usr/bin/env',
    'cat .env.production', 'cat .env.example.local', 'env FOO=1 cat .env', 'env -u X env', 'env A=1 env B=2 printenv']
  for (const command of loud) expect((await $.tool.call({ tool: 'Bash', command })).deny, command).toContain('into the transcript')
  expect(ran, 'none of them ran').toEqual(quiet)
})

test('a foreground command records nothing', async ($, on) => {
  const stopped = stub(on)

  await $.tool.call({ tool: 'Bash', command: 'ls' })
  await $.session.end({ ...END, reason: 'clear' })
  expect(stopped).toEqual([])
})

test('a task whose stop failed is kept and retried on the next /clear', async ($, on) => {
  const attempts: string[] = []
  let failing = true
  on('tool.call', { tool: 'Bash' }, () => ({
    result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'b9' },
  }))
  on('tool.call', { tool: 'TaskStop' }, (_, e) => {
    attempts.push(String(e.task_id))
    if (failing) throw new Error('injected TaskStop failure')
    return { result: { message: 'stopped', task_id: String(e.task_id), task_type: 'bash' } }
  })
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))

  await $.tool.call({ tool: 'Bash', command: 'b9', run_in_background: true })
  await $.session.end({ ...END, reason: 'clear' })
  failing = false
  await $.session.end({ ...END, reason: 'clear' })
  await $.session.end({ ...END, reason: 'clear' })
  // Tried on the first /clear, retried on the second, and spent once it stopped.
  expect(attempts).toEqual(['b9', 'b9'])
})

test('a task started while a /clear awaits its stops is kept for the next /clear', async ($, on) => {
  const stopped: string[] = []
  let stopping = () => {}
  let release = () => {}
  const stopStarted = new Promise<void>(resolve => { stopping = resolve })
  const stopReleased = new Promise<void>(resolve => { release = resolve })
  on('tool.call', { tool: 'Bash' }, (_, e) => ({
    result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: e.command },
  }))
  on('tool.call', { tool: 'TaskStop' }, async (_, e) => {
    stopped.push(String(e.task_id))
    if (e.task_id === 'old') { stopping(); await stopReleased }
    return { result: { message: 'stopped', task_id: String(e.task_id), task_type: 'bash' } }
  })
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))

  await $.tool.call({ tool: 'Bash', command: 'old', run_in_background: true })
  const clear = $.session.end({ ...END, reason: 'clear' })
  await stopStarted
  // 'new' lands in the set after the /clear took its snapshot and before its stops resolve.
  await $.tool.call({ tool: 'Bash', command: 'new', run_in_background: true })
  release()
  await clear
  await $.session.end({ ...END, reason: 'clear' })
  expect(stopped).toEqual(['old', 'new'])
})

// One Agent call as the engine raises it: only the prompt and the model vary between tests.
const spawn = (prompt: string, model?: string): AgentSpawnInput => ({
  tool_use_id: prompt, prompt, description: prompt, subagentType: 'cc-tuner:slice-unit',
  provider: { plugin: 'cc-tuner', tier: 'user' }, model, parentModel: 'claude-opus-5-5',
  background: true, fork: false,
})

// Stubs the engine beneath agent spawns: each spawn answers the next id with its model, the agent
// list reports the given statuses as of the call (and answers once held settles), every status-line
// text is recorded, and settings are as given.
function agents(on: On, status: Map<string, AgentStatus>, settings: Settings = {}, held?: () => Promise<void> | undefined) {
  const lines: (string | undefined)[] = []
  let n = 0
  on('agent.spawn', (_, e) => ({ model: e.model ?? 'claude-sonnet-5-5', agentId: `a${++n}` }))
  on('agent.list', async () => {
    const value = [...status].map(([id, s]) => ({ id, description: id, type: 'cc-tuner:slice-unit', status: s }))
    await held?.()
    return { value }
  })
  on('ui.status', (_, e) => { lines.push(e.text); return { value: undefined } })
  on('settings.read', () => ({ value: settings }))
  return lines
}

test('the status line counts running subagents by model', async ($, on) => {
  const status = new Map<string, AgentStatus>()
  const lines = agents(on, status)

  status.set('a1', 'running')
  await $.agent.spawn(spawn('slice one', 'claude-sonnet-5-5'))
  status.set('a2', 'running')
  await $.agent.spawn(spawn('slice two', 'opus'))
  status.set('a1', 'completed')
  status.set('a3', 'running')
  await $.agent.spawn(spawn('slice three', 'claude-haiku-5-5'))
  expect(lines).toEqual(['subagents: 1 sonnet', 'subagents: 1 sonnet · 1 opus', 'subagents: 1 opus · 1 haiku'])
})

test('the status line clears once no tracked subagent runs', async ($, on) => {
  const status = new Map<string, AgentStatus>([['a1', 'completed']])
  const lines = agents(on, status)

  await $.agent.spawn(spawn('slice one'))
  expect(lines).toEqual([undefined])
})

const INSTALLED: Settings = { statusLine: { type: 'command', command: 'bash ~/.claude/cc-tuner-statusline.sh' } }

// What the cc-tuner status line needs: the session's id, the config dir, and every write recorded.
function statusLineFile(on: On) {
  const writes: { path: string; text: string }[] = []
  mock.env(on, { CLAUDE_CONFIG_DIR: '/cfg', HOME: '/home' })
  on('session.id', () => ({ value: 's1' }))
  on('fs.read', () => ({ value: 'agents_dir=".../cc-tuner/subagents"' }))
  on('fs.write', (_, e) => { writes.push({ path: e.path, text: e.text }); return { value: undefined } })
  return writes
}

test('with the cc-tuner status line the models go to its file, not a second status entry', async ($, on) => {
  const status = new Map<string, AgentStatus>()
  const lines = agents(on, status, INSTALLED)
  const writes = statusLineFile(on)
  mock.clock(on)

  status.set('a1', 'running')
  await $.agent.spawn(spawn('slice one', 'claude-sonnet-5-5'))
  status.set('a2', 'running')
  await $.agent.spawn(spawn('slice two', 'opus'))

  expect(lines).toEqual([])
  expect(writes).toEqual([
    { path: '/cfg/cc-tuner/subagents/s1', text: '1 sonnet' },
    { path: '/cfg/cc-tuner/subagents/s1', text: '1 sonnet · 1 opus' },
  ])
})

test('the command setup writes for the active config dir is known by its quoted script path', async ($, on) => {
  const status = new Map<string, AgentStatus>([['a1', 'running']])
  const lines = agents(on, status, { statusLine: { type: 'command', command: "bash '/cfg/cc-tuner-statusline.sh'" } })
  const writes: string[] = []
  mock.env(on, { CLAUDE_CONFIG_DIR: '/cfg', HOME: '/home' })
  mock.clock(on)
  on('session.id', () => ({ value: 's1' }))
  on('fs.read', (_, e) => ({ value: e.path === '/cfg/cc-tuner-statusline.sh' ? 'cc-tuner/subagents' : '' }))
  on('fs.write', (_, e) => { writes.push(e.path); return { value: undefined } })

  await $.agent.spawn(spawn('slice one', 'claude-sonnet-5-5'))
  expect(lines).toEqual([])
  expect(writes).toEqual(['/cfg/cc-tuner/subagents/s1'])
})

test('the file follows a subagent that ends with no new event, then the rewrites stop', async ($, on) => {
  const status = new Map<string, AgentStatus>()
  agents(on, status, INSTALLED)
  const writes = statusLineFile(on)
  const clock = mock.clock(on)

  status.set('a1', 'running')
  await $.agent.spawn(spawn('slice one', 'claude-sonnet-5-5'))
  await clock.advance(5000)
  expect(writes.map(w => w.text)).toEqual(['1 sonnet', '1 sonnet'])

  status.set('a1', 'completed')
  await clock.advance(5000)
  expect(writes.map(w => w.text)).toEqual(['1 sonnet', '1 sonnet', ''])

  await clock.advance(20000)
  expect(writes.length).toBe(3)
})

test('an update in flight cannot publish its older snapshot over a newer spawn', async ($, on) => {
  const status = new Map<string, AgentStatus>()
  let held: Promise<void> | undefined
  agents(on, status, INSTALLED, () => held)
  const writes = statusLineFile(on)
  const clock = mock.clock(on)

  status.set('a1', 'running')
  await $.agent.spawn(spawn('slice one', 'claude-sonnet-5-5'))

  // The tick lists a1 as completed and stops there, then a second subagent starts.
  status.set('a1', 'completed')
  let release = () => {}
  held = new Promise(resolve => { release = resolve })
  void clock.advance(5000)
  await clock.settle()
  held = undefined
  status.set('a2', 'running')
  const second = $.agent.spawn(spawn('slice two', 'opus'))
  await clock.settle()
  release()
  await second
  await clock.settle()

  expect(writes.at(-1)?.text).toBe('1 opus')
  const before = writes.length
  await clock.advance(5000)
  expect(writes.length).toBeGreaterThan(before)
})

test('an old copy of the script gets the status entry, since it cannot read the file', async ($, on) => {
  const status = new Map<string, AgentStatus>([['a1', 'running']])
  const lines = agents(on, status, INSTALLED)
  mock.env(on, { CLAUDE_CONFIG_DIR: '/cfg', HOME: '/home' })
  mock.clock(on)
  on('fs.read', () => ({ value: '#!/usr/bin/env bash\n# a script from before this release' }))

  await $.agent.spawn(spawn('slice one', 'claude-sonnet-5-5'))
  expect(lines).toEqual(['subagents: 1 sonnet'])
})

test('a fork of the script elsewhere gets the status entry, whatever the installed copy can do', async ($, on) => {
  const status = new Map<string, AgentStatus>([['a1', 'running']])
  const lines = agents(on, status, { statusLine: { type: 'command', command: 'bash ~/bin/cc-tuner-statusline.sh' } })
  mock.env(on, { CLAUDE_CONFIG_DIR: '/cfg', HOME: '/home' })
  mock.clock(on)
  on('fs.read', () => ({ value: 'cc-tuner/subagents' }))

  await $.agent.spawn(spawn('slice one', 'claude-sonnet-5-5'))
  expect(lines).toEqual(['subagents: 1 sonnet'])
})

test('a file that cannot be written does not fail the spawn', async ($, on) => {
  const status = new Map<string, AgentStatus>([['a1', 'running']])
  agents(on, status, INSTALLED)
  mock.env(on, { CLAUDE_CONFIG_DIR: '/cfg', HOME: '/home' })
  on('session.id', () => ({ value: 's1' }))
  on('fs.read', () => ({ value: 'cc-tuner/subagents' }))
  mock.clock(on)
  on('fs.write', () => { throw new Error('read-only') })

  const spawned = await $.agent.spawn(spawn('slice one', 'claude-sonnet-5-5'))
  expect(spawned.agentId).toBe('a1')
})

interface Step { words: string[]; dir: string; op: string; writes: boolean; assumed?: boolean; outputs?: string[] }

// One step as the test reads it: "<dir> <op> <words>", `>` after a step that writes a file.
const show = (s: Step) => `${s.dir || '.'} ${s.op || '-'} ${s.words.join(' ')}${s.writes ? ' >' : ''}`

const COMMANDS = [
  ['npm test', ['. - npm test']],
  ['FOO=1 npm test', ['. - npm test']],
  ['bash "/p/scripts/heavy.sh" --weight 2 --label x -- npm test', ['. - npm test']],
  ['heavy.sh -- git -C ../x switch y', ['../x - git switch y']],
  ["bash -c 'cd x && git switch y'", ['x && git switch y']],
  ['env FOO=1 git status', ['. - git status']],
  ['env -i -u HOME git status', ['. - git status']],
  ['env -C d git status', ['d - git status']],
  ['echo a | xargs -n 1 git rm', ['. - echo a', '. | git rm']],
  ['git -C ../x status', ['../x - git status']],
  ['git -C a -C b --no-pager log', ['a/b - git log']],
  ['git -c core.pager=cat log', ['. - git log']],
  ['cd x && git reset --hard', ['x && git reset --hard']],
  ['cd a; cd b; git log', ['a/b ; git log']],
  ['cd a && cd b && git log', ['a/b && git log']],
  ['cd /abs && git log', ['/abs && git log']],
  ['cd x | git log', ['. | git log']],
  ['(cd a; git status); git log', ['a ; git status', '. ; git log']],
  ['(cd a && git status); git log', ['a && git status', '. ; git log']],
  ['{ cd a && git status; }; git log', ['a && git status', 'a ; git log']],
  ['echo "$(cd ../x && git status)"; git reset --hard', ['../x && git status', '. - echo ', '. ; git reset --hard']],
  ['echo `cd x; git status`', ['x ; git status', '. - echo ']],
  ['echo `cd x && git status`', ['x && git status', '. - echo ']],
  ['git switch -c x && git commit -m m', ['. - git switch -c x', '. && git commit -m m']],
  ['git add f && git commit -m m', ['. - git add f', '. && git commit -m m']],
  ['kill $(lsof -ti :3000)', ['. - lsof -ti :3000', '. - kill ']],
  ['lsof -ti :3000 | xargs kill -9', ['. - lsof -ti :3000', '. | kill -9']],
  ['git -C ../wt worktree remove .', ['../wt - git worktree remove .']],
  ['git -C ../wt reset --hard', ['../wt - git reset --hard']],
  ['cd x && rm -rf y', ['x && rm -rf y']],
  ["bash -c 'cd ../wt && git stash drop'", ['../wt && git stash drop']],
  ['heavy.sh -- git switch x', ['. - git switch x']],
  ["bash -c 'git reset --hard'", ['. - git reset --hard']],
  ['env FOO=1 git stash', ['. - git stash']],
  ["bash -c 'cd ../wt && rm -rf x'", ['../wt && rm -rf x']],
  ['heavy.sh -- git -C ../wt branch -D x', ['../wt - git branch -D x']],
  ['echo 1 | xargs -n 1 kill -9', ['. - echo 1', '. | kill -9']],
  ['git -C ../wt push origin --delete x', ['../wt - git push origin --delete x']],
  ['CC_TUNER_ACK=ab12cd34 heavy.sh -- git clean -fd', ['. - git clean -fd']],
  ['false || git switch c; true', ['. - false', '. || git switch c', '. ; true']],
  ['false && git switch c; git commit -m m', ['. - false', '. && git switch c', '. ; git commit -m m']],
  ["a && bash -c 'b; c'", ['. - a', '. && b', '. ; c']],
  ['cat x > f', ['. - cat x >']],
  ['cat x >> f', ['. - cat x >']],
  ['cat x &> f', ['. - cat x >']],
  ['cat x 2>&1 > /dev/null', ['. - cat x']],
  ['cat x 2>/dev/null', ['. - cat x']],
  ["bash -c 'cat x' > f", ['. - cat x >']],
  ['timeout 5 git reset --hard', ['. - git reset --hard']],
  ['timeout -s KILL 5 git -C ../x reset --hard', ['../x - git reset --hard']],
  ['nohup git stash drop', ['. - git stash drop']],
  ['nice -n 5 git reset --hard', ['. - git reset --hard']],
  ['nice git clean -fd', ['. - git clean -fd']],
  ['time -p git reset --hard', ['. - git reset --hard']],
  ['time git reset --hard', ['. - git reset --hard']],
] as const

test('the guard reads each command as steps that keep their directory and operator', () => {
  for (const [command, expected] of COMMANDS) expect(steps(command).map(show), command).toEqual(expected as unknown as string[])
})

test('a step keeps the git configuration given to its command as data: -c and --config-env pairs, GIT_CONFIG* assignments', () => {
  const config = (command: string) => steps(command).at(-1)?.config
  expect(config('git -c submodule.recurse=true reset --hard')).toEqual(['submodule.recurse=true'])
  expect(config('git -c a=b --no-pager -c c=d -C x reset --hard')).toEqual(['a=b', 'c=d'])
  expect(config('git --config-env=a=VAR reset --hard')).toEqual(['a=VAR'])
  expect(config('git --config-env a=VAR reset --hard')).toEqual(['a=VAR'])
  expect(config('GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=k GIT_CONFIG_VALUE_0=v git reset --hard')).toEqual(['GIT_CONFIG_COUNT=1', 'GIT_CONFIG_KEY_0=k', 'GIT_CONFIG_VALUE_0=v'])
  expect(config("env GIT_CONFIG_PARAMETERS='x' git reset --hard")).toEqual(['GIT_CONFIG_PARAMETERS=x'])
  expect(config('GIT_CONFIG_COUNT=1 timeout 5 git reset --hard')).toEqual(['GIT_CONFIG_COUNT=1'])
  expect(config("GIT_CONFIG_COUNT=1 bash -c 'git -c a=b reset --hard'")).toEqual(['GIT_CONFIG_COUNT=1', 'a=b'])
  expect(config('GIT_CONFIG_GLOBAL=/x git reset --hard')).toEqual(['GIT_CONFIG_GLOBAL=/x'])
  for (const command of ['git reset --hard', 'FOO=1 git reset --hard', 'env FOO=1 git reset --hard', 'git -C x reset --hard']) expect(config(command), command).toBeUndefined()
})

test('a step whose git is pointed at another repository runs in a directory nobody can tell', () => {
  for (const command of ['git --git-dir=/o/.git reset --hard', 'git --git-dir /o/.git reset --hard', 'git --work-tree=/o reset --hard', 'git --work-tree /o reset --hard',
    'GIT_DIR=/o/.git git reset --hard', 'GIT_WORK_TREE=/o git reset --hard', 'env GIT_DIR=/o/.git git reset --hard', "GIT_DIR=/o/.git bash -c 'git reset --hard'"]) {
    expect(steps(command).at(-1), command).toMatchObject({ words: ['git', 'reset', '--hard'], dir: UNKNOWN })
  }
  expect(steps('FOO=1 git reset --hard').at(-1)!.dir, 'another-assignment-keeps-the-directory').not.toBe(UNKNOWN)
  expect(steps('GIT_INDEX_FILE=/tmp/i git reset --hard').at(-1)!.dir, 'an-alternate-index-is-elsewhere-too').toBe(UNKNOWN)
  expect(steps("GIT_DIR=/b/.git GIT_WORK_TREE=/b bash -c 'cd /a && git reset --hard'").at(-1)!.dir, 'a-nested-cd-keeps-the-placement').toBe(UNKNOWN)
  expect(steps('git --git-dir /b/.git --work-tree=/b reset --hard').at(-1)!.place, 'the-placement-stays-as-data').toEqual(['--git-dir=/b/.git', '--work-tree=/b'])
  expect(steps("GIT_DIR=/b/.git bash -c 'git --work-tree=/b reset --hard'").at(-1)!.place, 'an-outer-placement-is-inherited').toEqual(['GIT_DIR=/b/.git', '--work-tree=/b'])
})

test('a step names the substitution it runs in, so a chain does not cross a $( ) or a backquote', () => {
  const scopes = (command: string) => steps(command).map(s => s.scope)
  const [a, b, c] = scopes('git switch x && echo "$(git status)" && git commit -m m')
  expect([a === c, b !== a], 'scope-a-substitution-is-a-scope-of-its-own').toEqual([true, true])
  const [d, e, f] = scopes('git switch x && echo `git status` && git commit -m m')
  expect([d === f, e !== d], 'scope-a-backquote-is-a-scope-of-its-own').toEqual([true, true])
  const [g, h] = scopes('echo "$(git switch x && git commit -m m)"')
  expect(g, 'scope-steps-of-one-substitution-share-it').toBe(h)
  const [i, j] = scopes('echo "$(git status)" "$(git log)"')
  expect(i, 'scope-two-substitutions-are-two-scopes').not.toBe(j)
  const [k, l] = scopes("git switch x && bash -c 'git commit -m m'")
  expect(k, 'scope-bash-c-keeps-the-chain').toBe(l)
})

test('a cd the guard cannot resolve leaves the later steps in a directory it does not know', () => {
  for (const command of ['cd "$X" && git reset --hard', 'cd ~/x && git reset --hard', 'cd - && git reset --hard', 'cd && git reset --hard',
    'cd x && cd "$Y/z" && git reset --hard', 'cd "$(pwd)" && git reset --hard', 'cd "$X"; cd y; git reset --hard']) {
    expect(steps(command).at(-1)?.dir, command).toBe(UNKNOWN)
  }
  expect(steps('(cd "$X"; git log); git reset --hard').map(s => s.dir), 'a subshell keeps its own cd').toEqual([UNKNOWN, ''])
})

test('a cd the steps after it do not wait on still moves them: the directory is assumed, for the guard to check that it exists', () => {
  const last = (command: string) => { const s = steps(command).at(-1)!; return [s.dir, s.assumed === true] }
  for (const [command, dir] of [['cd x; git reset --hard', 'x'], ['cd /nonexistent; git reset --hard', '/nonexistent'], ['cd x || git reset --hard', 'x'],
    ['cd x\ngit reset --hard', 'x'], ['cd x && git status; git reset --hard', 'x'], ['cd x && git status || git reset --hard', 'x'],
    ['cd x && git status\ngit reset --hard', 'x'], ['cd a && cd b; git reset --hard', 'a/b'], ['cd a; cd /abs; git reset --hard', '/abs'],
    ['cd x; echo ok && git reset --hard', 'x'], ['cd x && git status | cat; git reset --hard', 'x'], ['cd a; cd b && git reset --hard', 'a/b'],
    ['set -e\ncd pkg/app\ngit add f.ts\ngit commit -m fix', 'pkg/app'], ["cd x; bash -c 'git reset --hard'", 'x']] as const) {
    expect(last(command), command).toEqual([dir, true])
  }
  for (const command of ['cd x && git reset --hard', 'cd a; cd /abs && git reset --hard', 'git reset --hard', 'cd x | git reset --hard']) {
    expect(steps(command).at(-1)!.assumed, `nothing-is-assumed: ${command}`).toBeUndefined()
  }
})

test('a cd to the home directory or under the directory the shell is in is read; any other expansion is not', () => {
  const dir = (command: string, home = '/home/u') => steps(command, home).at(-1)!.dir
  for (const [command, want] of [['cd ~ && git add .', '/home/u'], ['cd ~/proj && git commit -m x', '/home/u/proj'], ['cd "$HOME/proj" && git add .', '/home/u/proj'],
    ['cd ${HOME}/proj && git add .', '/home/u/proj'], ['cd && git add .', '/home/u'], ['cd "$PWD/pkg/app" && git add f.ts', './pkg/app'],
    ['cd "$PWD"/pkg && git add f.ts', './pkg'], ['cd sub && cd $PWD/x && git add .', 'sub/./x'], ['cd ~/a; git add .', '/home/u/a']] as const) {
    expect(dir(command), command).toBe(want)
  }
  for (const command of ['cd ~other/x && git add .', 'cd "$REPO" && git add .', 'cd $(git rev-parse --show-toplevel) && git add .', 'cd $(pwd)/sub && git add .',
    'cd "`pwd`/sub" && git add .', 'cd $HOMEDIR/x && git add .', 'cd - && git add .', 'cd "$X"; cd y; git add .']) {
    expect(dir(command), command).toBe(UNKNOWN)
  }
  expect(dir('cd ~/proj && git add .', ''), 'no-home-no-directory').toBe(UNKNOWN)
})

test('a step names the files its redirections write, from where the command starts', () => {
  const outputs = (command: string) => steps(command, '/home/u').map(s => s.outputs)
  expect(outputs('echo x > a.txt')).toEqual([['a.txt']])
  expect(outputs('cd sub && echo x >> b.txt && cat c > /abs/d 2> err.log')).toEqual([['sub/b.txt'], ['/abs/d', 'sub/err.log']])
  expect(outputs('echo x > ~/n.txt; echo y &> all.log')).toEqual([['/home/u/n.txt'], ['all.log']])
  expect(outputs("bash -c 'echo x > in.txt' > out.txt")).toEqual([['in.txt', 'out.txt']])
  for (const command of ['echo x > /dev/null', 'echo x 2>&1', 'cat < in.txt', 'echo x > "$F"', 'echo x > $(mktemp)', 'cd "$D" && echo x > rel.txt', 'git log']) {
    expect(outputs(command).at(-1), `no-file-named: ${command}`).toBeUndefined()
  }
})

test('a cd whose steps are joined to it with && keeps its directory, and one in its own subshell or pipeline moves nothing', () => {
  const dirs = (command: string) => steps(command).map(s => s.dir)
  expect(dirs('cd x && git reset --hard')).toEqual(['x'])
  expect(dirs('cd x && cd y && git status && git reset --hard')).toEqual(['x/y', 'x/y'])
  expect(dirs('cd a; cd /abs && git reset --hard'), 'an absolute cd that the chain depends on is certain').toEqual(['/abs'])
  expect(dirs('cd x && (git status; git reset --hard)'), 'a group after a cd runs only if it succeeded').toEqual(['x', 'x'])
  expect(dirs('(cd x; git status); git reset --hard'), 'a subshell keeps its own cd').toEqual(['x', ''])
  expect(dirs('(cd x && git status); git reset --hard')).toEqual(['x', ''])
  expect(dirs('echo "$(cd x; git status)"; git reset --hard')).toEqual(['x', '', ''])
  expect(steps('(cd x; git status); git reset --hard').map(s => s.assumed), 'what-a-subshell-assumed-ends-with-it').toEqual([true, undefined])
  expect(dirs('cd x | git reset --hard'), 'a pipeline stage moves nothing').toEqual([''])
  expect(dirs('cd x & git reset --hard')).toEqual([''])
  expect(dirs('git switch y && git reset --hard'), 'no cd, no change').toEqual(['', ''])
})
