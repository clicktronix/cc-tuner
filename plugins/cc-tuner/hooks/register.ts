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
const ASSIGNMENT = /^[A-Za-z_]\w*=/
const ENV_FILE = /(^|\/)\.env([.*?[][\w.*?[\]-]*)?$/
const TEMPLATE = /\.(example|sample|template|dist)$/

// Splits shell text into the words of each simple command it would run: quotes and escapes are
// resolved, comments and heredoc bodies dropped, redirections removed with their targets, and the
// bodies of $(...) and backquotes scanned as commands of their own.
function commands(text: string): string[][] {
  const found: string[][] = []
  const heredocs: { end: string; tabs: boolean; quoted: boolean }[] = []
  let words: string[] = []
  let word = ''
  let inWord = false
  let i = 0
  const endWord = () => { if (inWord) words.push(word); word = ''; inWord = false }
  const endCommand = () => { endWord(); if (words.length > 0) found.push(words); words = [] }
  const substitution = (open: number) => {
    let depth = 1
    let j = open
    while (j < text.length && depth > 0) {
      if (text[j] === '(') depth++
      else if (text[j] === ')') depth--
      j++
    }
    found.push(...commands(text.slice(open, j - 1)))
    return j
  }
  const backquote = (open: number) => {
    const close = text.indexOf('`', open)
    const j = close === -1 ? text.length : close
    found.push(...commands(text.slice(open, j)))
    return j + 1
  }
  const readTarget = () => {
    while (text[i] === ' ' || text[i] === '\t') i++
    let target = ''
    let quoted = false
    while (i < text.length && !/[\s;&|()<>]/.test(text[i]!)) {
      const c = text[i]!
      if (c === "'" || c === '"') {
        quoted = true
        const close = text.indexOf(c, i + 1)
        target += text.slice(i + 1, close === -1 ? text.length : close)
        i = close === -1 ? text.length : close + 1
      } else if (c === '\\') { quoted = true; target += text[i + 1] ?? ''; i += 2 } else { target += c; i++ }
    }
    return { target, quoted }
  }
  const skipHeredocs = () => {
    for (const doc of heredocs.splice(0)) {
      while (i < text.length) {
        const eol = text.indexOf('\n', i)
        const line = text.slice(i, eol === -1 ? text.length : eol)
        i = eol === -1 ? text.length : eol + 1
        if ((doc.tabs ? line.replace(/^\t+/, '') : line) === doc.end) break
        if (!doc.quoted) for (const [, body] of line.matchAll(/\$\(([^)]*)\)|`([^`]*)`/g)) found.push(...commands(body ?? ''))
      }
    }
  }

  while (i < text.length) {
    const c = text[i]!
    if (c === '\n') { endCommand(); i++; skipHeredocs() } else if (c === ' ' || c === '\t') { endWord(); i++ } else if (';&|()'.includes(c)) { endCommand(); i++ } else if (c === '#' && !inWord) {
      while (i < text.length && text[i] !== '\n') i++
    } else if (c === '<' || c === '>') {
      if (/^\d+$/.test(word)) { word = ''; inWord = false } else endWord()
      const op = /^(<<-|<<<|<<|<>|<&|>>|>&|>\||<|>)/.exec(text.slice(i))![0]
      i += op.length
      const { target, quoted } = readTarget()
      if (op === '<<' || op === '<<-') heredocs.push({ end: target, tabs: op === '<<-', quoted })
    } else if (c === "'") {
      const close = text.indexOf("'", i + 1)
      word += text.slice(i + 1, close === -1 ? text.length : close)
      inWord = true
      i = close === -1 ? text.length : close + 1
    } else if (c === '"') {
      inWord = true
      i++
      while (i < text.length && text[i] !== '"') {
        if (text[i] === '\\') { word += text[i + 1] ?? ''; i += 2 } else if (text.startsWith('$(', i)) { i = substitution(i + 2) } else if (text[i] === '`') { i = backquote(i + 1) } else { word += text[i]; i++ }
      }
      i++
    } else if (c === '\\') {
      if (text[i + 1] !== '\n') { word += text[i + 1] ?? ''; inWord = true }
      i += 2
    } else if (text.startsWith('$(', i)) {
      i = substitution(i + 2)
      inWord = true
    } else if (c === '`') {
      i = backquote(i + 1)
      inWord = true
    } else { word += c; inWord = true; i++ }
  }
  endCommand()
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
  for (const all of commands(command)) {
    let at = 0
    while (at < all.length && (PREFIXES.has(all[at]!) || ASSIGNMENT.test(all[at]!))) at++
    const [name, ...args] = all.slice(at)
    if (name === undefined) continue
    if (DUMPS.has(name) && dumps(name, args)) {
      return `cc-tuner: \`${all.slice(at).join(' ')}\` prints every variable's value, secrets included, into the transcript. ` +
        `Check one is set with \`${CHECK_SET}\`; list names only with \`${LIST_NAMES}\`.`
    }
    const file = READERS.has(name) ? args.find(arg => ENV_FILE.test(arg) && !(TEMPLATE.test(arg) && !/[*?[]/.test(arg))) : undefined
    if (file !== undefined) {
      return `cc-tuner: \`${name} ${file}\` prints secret values into the transcript. ` +
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
