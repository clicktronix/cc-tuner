import type { EngineInterface, Register } from 'claude-code'

// Claude Code stops a session's background tasks when the process exits, but
// a /clear ends the conversation and leaves them running under the next one.
// The agent that started them no longer knows they exist, so they are stopped
// here. Ids are module state: a reload loses them, and exit still stops those.
// An id leaves the set when the agent stops the task itself; a task that ends
// on its own is not observable from a hook, and stopping it later is harmless.
const started = new Set<string>()

// The subagent panel shows an agent's type and its live activity, never its model, and a plugin
// cannot redraw that panel. The status line carries the models of the subagents still running.
const models = new Map<string, string>()
const ACTIVE = new Set(['pending', 'running', 'waiting'])
const ENDED = new Set(['completed', 'failed', 'killed'])
const family = (model: string) => /fable|mythos|opus|sonnet|haiku/.exec(model)?.[0] ?? model

async function showModels($: EngineInterface) {
  const agents = await $.agent.list()
  const counts = new Map<string, number>()
  for (const agent of agents) {
    const model = models.get(agent.id)
    if (model === undefined) continue
    if (ENDED.has(agent.status)) models.delete(agent.id)
    else if (ACTIVE.has(agent.status)) counts.set(model, (counts.get(model) ?? 0) + 1)
  }
  $.ui.status(counts.size === 0 ? undefined : `subagents: ${[...counts].map(([m, n]) => `${n} ${m}`).join(' · ')}`)
}

// A printed secret is in the transcript for good, so this one effect is refused at the call rather
// than left to prose: a bare `env`, `printenv`, `set` or `export` dumps every variable with its value,
// and reading a `.env` file prints its values. Each refusal names the command that answers the same
// question without the values. Committed templates (`.env.example`) hold none and stay readable.
const DUMPS = /^(env|printenv|set|export)$/
const NAMES_ONLY = /^cut\s+(-d\s*['"]?=['"]?\s+-f\s*1|-f\s*1\s+-d\s*['"]?=['"]?)(\s|$)/
const READERS = /^(cat|head|tail|less|more|bat)$/
const ENV_FILE = /(^|\/)\.env(\.[\w.-]+)?$/
const TEMPLATE = /\.(example|sample|template|dist)$/

function secretLeak(command: string): string | undefined {
  for (const chain of command.split(/&&|\|\||;|\n/)) {
    const pipeline = chain.split('|').map(segment => segment.trim())
    for (const [i, segment] of pipeline.entries()) {
      if (DUMPS.test(segment) && !NAMES_ONLY.test(pipeline[i + 1] ?? '')) {
        return `cc-tuner: a bare \`${segment}\` prints every variable's value, secrets included, into the transcript. ` +
          'Check one is set with `printenv NAME | wc -c`; list names only with `env | cut -d= -f1`.'
      }
      const [reader, ...args] = segment.split(/\s+/)
      const file = args.map(arg => arg.replace(/^['"]|['"]$/g, '')).find(arg => ENV_FILE.test(arg) && !TEMPLATE.test(arg))
      if (reader !== undefined && READERS.test(reader) && file !== undefined) {
        return `cc-tuner: \`${reader} ${file}\` prints secret values into the transcript. ` +
          `List its keys with \`cut -d= -f1 ${file}\`; check one is set with \`grep -c '^NAME=' ${file}\`.`
      }
    }
  }
  return undefined
}

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const leak = secretLeak(e.command)
    if (leak !== undefined) return { deny: leak }
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

  on('agent.spawn', async ($, e, next) => {
    const spawned = await next(e)
    if (spawned.deny === undefined && spawned.agentId) {
      models.set(spawned.agentId, family(spawned.model))
      await showModels($)
    }
    return spawned
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (models.size > 0) await showModels($)
    return done
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
