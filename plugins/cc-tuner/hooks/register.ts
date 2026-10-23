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
// than left to prose: `env`, `printenv`, `set`, `export`, `declare` or `typeset` with nothing to run
// or name dumps every variable with its value, and reading a `.env` file prints its values. Each
// refusal names commands that answer the same question and print no value even when one spans
// lines (a PEM key does; `cut -d= -f1` would print its body). Templates (`.env.example`) hold none.
const CHECK_SET = "printenv NAME | wc -c"
const LIST_NAMES = "awk 'BEGIN { for (k in ENVIRON) print k }'"
const CHECK_KEY = "grep -c '^NAME=' FILE"
const DUMPS = new Set(['env', 'printenv', 'set', 'export', 'declare', 'typeset'])
const READERS = new Set(['cat', 'head', 'tail', 'less', 'more', 'bat'])
const PREFIXES = new Set(['!', '{', '}', 'if', 'then', 'elif', 'else', 'while', 'until', 'do', 'time', 'command', 'builtin', 'exec'])
const WRAPPERS = new Set(['command', 'builtin', 'exec'])
const ASSIGNMENT = /^[A-Za-z_]\w*=/
const ENV_FILE = /(^|\/)\.env([.*?[][\w.*?[\]-]*)?$/
const TEMPLATE = /\.(example|sample|template|dist)$/

// The simple commands shell text would run, each as its words with quotes and escapes resolved and
// the files it reads on stdin (`< file`). One reader handles every place the shell expands text —
// words, double quotes, unquoted heredoc bodies, redirection targets — so a $( … ) or backquote is
// scanned as commands of its own wherever it sits, and an escaped one stays literal. Comments,
// quoted heredoc bodies and other redirections drop out.
interface Simple { words: string[]; inputs: string[] }
const METACHARS = ' \t\n;&|()<>'

function commands(text: string): Simple[] {
  const found: Simple[] = []
  const heredocs: { end: string; tabs: boolean; quoted: boolean }[] = []
  let i = 0
  let quoted = false

  // A command list from i; nested, it stops after the `)` that closes its $(.
  function list(nested: boolean) {
    let current: Simple = { words: [], inputs: [] }
    let depth = 0
    const end = () => {
      if (current.words.length > 0 || current.inputs.length > 0) found.push(current)
      current = { words: [], inputs: [] }
    }
    while (i < text.length) {
      const c = text[i]!
      if (c === '\n') { end(); i++; bodies() } else if (c === ' ' || c === '\t') i++
      else if (c === '#') { while (i < text.length && text[i] !== '\n') i++ } else if (c === '(') { end(); depth++; i++ } else if (c === ')') {
        end()
        i++
        if (depth === 0 && nested) return
        depth = Math.max(0, depth - 1)
      } else if (';&|'.includes(c)) { end(); i++ } else if (c === '<' || c === '>') redirect(current)
      else {
        const w = word()
        if ((text[i] === '<' || text[i] === '>') && /^\d+$/.test(w)) redirect(current)
        else current.words.push(w)
      }
    }
    end()
  }

  // One word up to the next unquoted metacharacter.
  function word(): string {
    let out = ''
    quoted = false
    while (i < text.length && !METACHARS.includes(text[i]!)) {
      const c = text[i]!
      if (c === "'") {
        quoted = true
        const close = text.indexOf("'", i + 1)
        out += text.slice(i + 1, close === -1 ? text.length : close)
        i = close === -1 ? text.length : close + 1
      } else if (c === '"') {
        quoted = true
        i++
        out += expand('"', text.length)
      } else if (c === '\\') {
        quoted = true
        if (text[i + 1] !== '\n') out += text[i + 1] ?? ''
        i += 2
      } else if (!substitution()) { out += c; i++ }
    }
    return out
  }

  // Expandable text up to `close` (double quotes) or `limit` (a heredoc body).
  function expand(close: string | undefined, limit: number): string {
    const escapable = close === undefined ? '$`\\\n' : '$`"\\\n'
    let out = ''
    while (i < limit) {
      const c = text[i]!
      if (c === close) { i++; return out }
      if (c === '\\' && escapable.includes(text[i + 1] ?? '')) {
        if (text[i + 1] !== '\n') out += text[i + 1]
        i += 2
      } else if (!substitution()) { out += c; i++ }
    }
    return out
  }

  // At $( or a backquote: scans the body as commands and moves past it.
  function substitution(): boolean {
    if (text.startsWith('$(', i)) {
      i += 2
      list(true)
      return true
    }
    if (text[i] !== '`') return false
    let body = ''
    for (i++; i < text.length && text[i] !== '`'; i++) {
      if (text[i] === '\\' && '`$\\'.includes(text[i + 1] ?? '')) i++
      body += text[i]
    }
    i++
    found.push(...commands(body))
    return true
  }

  function redirect(current: Simple) {
    const op = /^(<<-|<<<|<<|<>|<&|>>|>&|>\||<|>)/.exec(text.slice(i))![0]
    i += op.length
    while (text[i] === ' ' || text[i] === '\t') i++
    const target = word()
    if (op === '<<' || op === '<<-') heredocs.push({ end: target, tabs: op === '<<-', quoted })
    else if (op === '<' || op === '<>') current.inputs.push(target)
  }

  // The heredoc bodies that start after a newline; unquoted ones expand like double quotes.
  function bodies() {
    for (const doc of heredocs.splice(0)) {
      let at = i
      let bodyEnd = text.length
      let next = text.length
      while (at < text.length) {
        const eol = text.indexOf('\n', at)
        const line = text.slice(at, eol === -1 ? text.length : eol)
        if ((doc.tabs ? line.replace(/^\t+/, '') : line) === doc.end) {
          bodyEnd = at
          next = eol === -1 ? text.length : eol + 1
          break
        }
        at = eol === -1 ? text.length : eol + 1
      }
      if (!doc.quoted) expand(undefined, bodyEnd)
      i = Math.max(i, next)
    }
  }

  list(false)
  return found
}

function dumps(name: string, args: string[]): boolean {
  if (name === 'set') return args.length === 0
  if (name !== 'env') return args.every(arg => arg.startsWith('-'))
  for (let k = 0; k < args.length; k++) {
    const arg = args[k]!
    if (arg === '-S' || arg.startsWith('--split-string')) return false
    if (arg === '-u' || arg === '-P' || arg === '-C') k++
    else if (!arg.startsWith('-') && !ASSIGNMENT.test(arg)) return false
  }
  return true
}

function secretLeak(command: string): string | undefined {
  for (const { words, inputs } of commands(command)) {
    let at = 0
    while (at < words.length && (PREFIXES.has(words[at]!) || ASSIGNMENT.test(words[at]!))) {
      if (WRAPPERS.has(words[at]!)) {
        at++
        while (at < words.length && words[at]!.startsWith('-')) at += words[at] === '-a' ? 2 : 1
      } else at++
    }
    const [name, ...args] = words.slice(at)
    if (name !== undefined && DUMPS.has(name) && dumps(name, args)) {
      return `cc-tuner: \`${words.slice(at).join(' ')}\` prints every variable's value, secrets included, into the transcript. ` +
        `Check one is set with \`${CHECK_SET}\`; list names only with \`${LIST_NAMES}\`.`
    }
    const read = name === undefined || READERS.has(name) ? [...args, ...inputs] : []
    const file = read.find(arg => ENV_FILE.test(arg) && !(TEMPLATE.test(arg) && !/[*?[]/.test(arg)))
    if (file !== undefined) {
      return `cc-tuner: \`${name ?? '<'} ${file}\` prints secret values into the transcript. ` +
        `Check a key is set with \`${CHECK_KEY.replace('FILE', file)}\`; key names come from its template (\`.env.example\`) or the user.`
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
