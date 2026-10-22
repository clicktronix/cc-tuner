import type { On } from 'claude-code'
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
