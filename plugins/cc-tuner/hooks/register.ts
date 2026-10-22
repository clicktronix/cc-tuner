import type { Register } from 'claude-code'

// Claude Code stops a session's background tasks when the process exits, but
// a /clear ends the conversation and leaves them running under the next one.
// The agent that started them no longer knows they exist, so they are stopped
// here. Ids are module state: a reload loses them, and exit still stops those.
// An id leaves the set when the agent stops the task itself; a task that ends
// on its own is not observable from a hook, and stopping it later is harmless.
const started = new Set<string>()

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true && ran.result.backgroundTaskId) {
      started.add(ran.result.backgroundTaskId)
    }
    return ran
  })

  on('tool.call', { tool: 'TaskStop' }, async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true) started.delete(ran.result.task_id)
    return ran
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      const ids = [...started]
      const results = await Promise.allSettled(ids.map(task_id => $.tool.call({ tool: 'TaskStop', task_id })))
      // Only confirmed stops leave the set: an id whose stop failed stays for the next /clear (exit
      // still stops it; a task that already ended can answer with an error, harmless to retry), and
      // a task started while the stops were awaited was never in the snapshot and stays too.
      const unstopped: string[] = []
      ids.forEach((id, i) => {
        const r = results[i]
        if (r?.status === 'fulfilled' && r.value.deny === undefined && r.value.isError !== true) started.delete(id)
        else unstopped.push(id)
      })
      if (unstopped.length > 0) {
        $.ui.log(`cc-tuner: /clear could not confirm stopping ${unstopped.join(', ')}; retrying next /clear`, { to: 'debug' })
      }
    }
    return next(e)
  })
}
