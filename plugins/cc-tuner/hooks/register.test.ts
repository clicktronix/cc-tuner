import type { AgentSpawnInput, AgentStatus, On } from 'claude-code'
import { expect, test } from 'claude-code/testing'

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
// list reports the given statuses, and every status-line text is recorded.
function agents(on: On, status: Map<string, AgentStatus>) {
  const lines: (string | undefined)[] = []
  let n = 0
  on('agent.spawn', (_, e) => ({ model: e.model ?? 'claude-sonnet-5-5', agentId: `a${++n}` }))
  on('agent.list', () => ({
    value: [...status].map(([id, s]) => ({ id, description: id, type: 'cc-tuner:slice-unit', status: s })),
  }))
  on('ui.status', (_, e) => { lines.push(e.text); return { value: undefined } })
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
